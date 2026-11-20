import Foundation

/// One step of a cleanup: an item, the targets the user approved, and how it's bound.
public struct CleanupStep: Codable, Equatable, Identifiable, Sendable {
    public var item: Item
    public var ownerName: String
    /// Exactly what this step removes. For picked Review items, only the picked entries.
    public var approvedTargets: [Target]
    public var expectedBytes: Int64
    public var destination: Destination

    public var id: String { item.id }
}

/// What the user is asked to approve. Built only from what the rules allow.
public struct CleanupPlan: Codable, Equatable, Sendable {
    public var steps: [CleanupStep]
    public var previewTime: Date

    /// - Parameters:
    ///   - selected: IDs of automatic items the user ticked.
    ///   - picks: Review items with the entries the user picked, by item ID.
    public init(snapshot: Snapshot, selected: Set<String>, picks: [String: [Target]], cleaned: Set<String> = [], previewTime: Date = .now) {
        var steps: [CleanupStep] = []
        for owner in snapshot.owners {
            for item in owner.items where !cleaned.contains(item.id) {
                if item.isAutomaticCleanup, selected.contains(item.id), let d = item.action.destination {
                    steps.append(CleanupStep(item: item, ownerName: owner.name, approvedTargets: item.targets,
                                             expectedBytes: item.reclaimable.bytes ?? 0, destination: d))
                } else if item.action == .pickToTrash, let picked = picks[item.id], !picked.isEmpty {
                    // Only the item's own entries, with the sizes the scan measured.
                    let ids = Set(picked.map(\.id))
                    let allowed = item.targets.filter { ids.contains($0.id) }
                    guard !allowed.isEmpty else { continue }
                    steps.append(CleanupStep(item: item, ownerName: owner.name, approvedTargets: allowed,
                                             expectedBytes: allowed.compactMap(\.bytes).reduce(0, +), destination: .trash))
                }
            }
        }
        self.steps = steps.sorted { $0.item.tier < $1.item.tier }
        self.previewTime = previewTime
    }

    public func expected(_ d: Destination) -> Int64 {
        steps.filter { $0.destination == d }.map(\.expectedBytes).reduce(0, +)
    }

    /// Steps holding files the user picked themselves. They need an extra confirmation.
    public var pickedSteps: [CleanupStep] { steps.filter { $0.item.tier == .review } }
}

/// What actually happened to one step.
public enum StepOutcome: Codable, Equatable, Sendable {
    case done(freedBytes: Int64)
    /// The re-check found the targets changed; nothing was removed.
    case skipped(reason: String)
    /// The run was stopped before this step started.
    case notRun
    case failed(error: String)

    public var didRun: Bool { if case .done = self { true } else { false } }
}

/// The single record of a cleanup run. Results, the receipt and History all read it.
public struct RunRecord: Codable, Equatable, Identifiable, Sendable {
    public struct StepResult: Codable, Equatable, Sendable {
        public var step: CleanupStep
        public var outcome: StepOutcome
        /// The commands actually executed, or the paths actually moved.
        public var executed: [String]
        /// Where moved items landed in the Trash, so only they can be deleted from it later.
        public var trashLocations: [String]

        public init(step: CleanupStep, outcome: StepOutcome, executed: [String] = [], trashLocations: [String] = []) {
            self.step = step
            self.outcome = outcome
            self.executed = executed
            self.trashLocations = trashLocations
        }
    }

    /// Deleting some of this run's items from the Trash, which happens after the run.
    public struct TrashDeletion: Codable, Equatable, Sendable {
        public var date: Date
        public var paths: [String]
        public var bytes: Int64
        public var includedPickedFiles: Bool

        public init(date: Date, paths: [String], bytes: Int64, includedPickedFiles: Bool) {
            self.date = date
            self.paths = paths
            self.bytes = bytes
            self.includedPickedFiles = includedPickedFiles
        }
    }

    public var id: UUID
    public var started: Date
    public var finished: Date
    public var steps: [StepResult]
    public var trashDeletions: [TrashDeletion]

    public init(id: UUID = UUID(), started: Date, finished: Date, steps: [StepResult], trashDeletions: [TrashDeletion] = []) {
        self.id = id
        self.started = started
        self.finished = finished
        self.steps = steps
        self.trashDeletions = trashDeletions
    }

    public var doneCount: Int { steps.filter(\.outcome.didRun).count }

    public func freed(_ d: Destination) -> Int64 {
        steps.filter { $0.step.destination == d }.compactMap {
            if case .done(let b) = $0.outcome { b } else { nil }
        }.reduce(0, +)
    }

    public var deletedFromTrash: Int64 { trashDeletions.map(\.bytes).reduce(0, +) }
    /// Freed on the Mac by commands, plus whatever was later deleted from the Trash.
    public var freedOnMac: Int64 { freed(.mac) + deletedFromTrash }
    public var stillInTrash: Int64 { max(0, freed(.trash) - deletedFromTrash) }

    /// Entries this run moved to the Trash, the user's picked files first.
    public var movedToTrash: [(path: String, bytes: Int64?, picked: Bool)] {
        steps.filter { $0.step.destination == .trash && $0.outcome.didRun }
            .sorted { ($0.step.item.tier == .review ? 0 : 1) < ($1.step.item.tier == .review ? 0 : 1) }
            .flatMap { r in r.step.approvedTargets.map { ($0.id, $0.bytes, r.step.item.tier == .review) } }
    }
}

public enum Receipt {
    /// The plain-text receipt, the same in History and in the saved file.
    /// Each step leads with its outcome, then what was planned or executed.
    public static func text(_ run: RunRecord) -> String {
        var lines = ["macstorage cleanup receipt",
                     "Started \(run.started.formatted(date: .abbreviated, time: .shortened)), \(run.doneCount) of \(run.steps.count) steps done", ""]
        for r in run.steps {
            let s = r.step
            switch r.outcome {
            case .done(let b): lines.append("DONE · \(s.ownerName) · \(s.item.name) · \(ByteFormat.string(b)) \(s.destination == .trash ? "moved to the Trash" : s.destination == .containerDisk ? "freed inside Docker's disk" : "freed")")
            case .skipped(let why): lines.append("SKIPPED · \(s.ownerName) · \(s.item.name) · \(why) Nothing was removed.")
            case .notRun: lines.append("NOT RUN · \(s.ownerName) · \(s.item.name) · Cleanup was stopped before this step.")
            case .failed(let e): lines.append("FAILED · \(s.ownerName) · \(s.item.name) · \(e)")
            }
            lines.append(r.outcome.didRun ? "  Executed:" : "  Planned, not executed:")
            lines += (r.outcome.didRun ? r.executed : s.approvedTargets.map(\.id)).map { "    \($0)" }
            lines.append("")
        }
        for d in run.trashDeletions {
            lines.append("Later, \(d.date.formatted(date: .omitted, time: .shortened)): deleted \(plural(d.paths.count, "item")) (\(ByteFormat.string(d.bytes))) from the Trash permanently\(d.includedPickedFiles ? ", including your picked files" : ""):")
            lines += d.paths.map { "    \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}
