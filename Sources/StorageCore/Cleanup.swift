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

    public init(item: Item, ownerName: String, approvedTargets: [Target], expectedBytes: Int64, destination: Destination) {
        self.item = item
        self.ownerName = ownerName
        self.approvedTargets = approvedTargets
        self.expectedBytes = expectedBytes
        self.destination = destination
    }
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
        // By tier, keeping scan order within a tier.
        self.steps = steps.enumerated().sorted { ($0.element.item.tier, $0.offset) < ($1.element.item.tier, $1.offset) }.map(\.element)
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
    /// Everything approved was removed. `measured` is what the app re-measured afterwards,
    /// or nil when the space can't be re-measured (it then shows the prediction as such).
    case done(measured: Int64?)
    /// Some targets were removed and some weren't; `problems` says which and why.
    case partial(measured: Int64?, problems: [String])
    /// The re-check found the scope changed (or a guard refused); nothing was removed.
    case skipped(reason: String)
    /// The step never started: the run was stopped, or an earlier step failed.
    case notRun(reason: String)
    case failed(error: String)

    /// True when the step removed something.
    public var didRun: Bool {
        switch self {
        case .done, .partial: true
        default: false
        }
    }

    public var measured: Int64? {
        switch self {
        case .done(let m), .partial(let m, _): m
        default: nil
        }
    }

    /// The run stops after a step that failed or only partly succeeded.
    public var stopsRun: Bool {
        switch self {
        case .failed, .partial: true
        default: false
        }
    }
}

/// One entry moved to the Trash: where it was, where it landed, and what it was.
public struct TrashEntry: Codable, Equatable, Sendable {
    public var original: String
    public var landed: String
    /// The landed object's identity, so only this exact object can be deleted later.
    public var identity: FileIdentity?
    public var bytes: Int64
    /// True for files the user picked themselves (Review items).
    public var picked: Bool

    public init(original: String, landed: String, identity: FileIdentity?, bytes: Int64, picked: Bool) {
        self.original = original
        self.landed = landed
        self.identity = identity
        self.bytes = bytes
        self.picked = picked
    }
}

/// The single record of a cleanup run. Results, the receipt and History all read it.
public struct RunRecord: Codable, Equatable, Identifiable, Sendable {
    public struct StepResult: Codable, Equatable, Sendable {
        public var step: CleanupStep
        public var outcome: StepOutcome
        /// The commands actually executed, in order (empty for Trash moves).
        public var executed: [String]
        /// What actually went to the Trash.
        public var trashed: [TrashEntry]

        public init(step: CleanupStep, outcome: StepOutcome, executed: [String] = [], trashed: [TrashEntry] = []) {
            self.step = step
            self.outcome = outcome
            self.executed = executed
            self.trashed = trashed
        }
    }

    /// Permanently deleting some of this run's Trash entries, after the run.
    public struct TrashDeletion: Codable, Equatable, Sendable {
        public var date: Date
        public var deleted: [TrashEntry]
        /// Entries the app refused to delete (moved, replaced or restored since).
        public var refused: [String]

        public init(date: Date, deleted: [TrashEntry], refused: [String]) {
            self.date = date
            self.deleted = deleted
            self.refused = refused
        }

        public var bytes: Int64 { deleted.map(\.bytes).reduce(0, +) }
        public var includedPickedFiles: Bool { deleted.contains(where: \.picked) }
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

    /// Re-measured bytes freed per destination.
    public func freed(_ d: Destination) -> Int64 {
        steps.filter { $0.step.destination == d }.compactMap(\.outcome.measured).reduce(0, +)
    }

    /// Predicted bytes for steps that ran but couldn't be re-measured.
    public func unmeasured(_ d: Destination) -> Int64 {
        steps.filter { $0.step.destination == d && $0.outcome.didRun && $0.outcome.measured == nil }.map(\.step.expectedBytes).reduce(0, +)
    }

    /// Everything this run put in the Trash, the user's own files first.
    public var trashed: [TrashEntry] {
        steps.flatMap(\.trashed).sorted { $0.picked && !$1.picked }
    }

    public var deletedFromTrash: Int64 { trashDeletions.map(\.bytes).reduce(0, +) }
    /// Freed on the Mac by commands, plus whatever was later deleted from the Trash.
    public var freedOnMac: Int64 { freed(.mac) + deletedFromTrash }
    /// This run's entries that are still in the Trash.
    public var stillInTrash: [TrashEntry] {
        let gone = Set(trashDeletions.flatMap(\.deleted).map(\.landed))
        return trashed.filter { !gone.contains($0.landed) }
    }
}

public enum Receipt {
    /// The plain-text receipt, the same in History and in the saved file. Each step leads
    /// with its outcome, then what was executed or, if nothing ran, what was planned.
    public static func text(_ run: RunRecord) -> String {
        var lines = ["macstorage cleanup receipt",
                     "Started \(run.started.formatted(date: .abbreviated, time: .shortened)), \(run.doneCount) of \(plural(run.steps.count, "step")) done", ""]
        for r in run.steps {
            let s = r.step, title = "\(s.ownerName) · \(s.item.name)"
            let freed = { (m: Int64?) in m.map { "\(ByteFormat.string($0)) \(s.destination == .trash ? "moved to the Trash" : s.destination == .containerDisk ? "freed inside Docker's disk" : "freed"), measured" }
                ?? "predicted \(ByteFormat.string(s.expectedBytes)), not re-measured" }
            switch r.outcome {
            case .done(let m): lines.append("DONE · \(title) · \(freed(m))")
            case .partial(let m, let problems): lines.append("PARTLY DONE · \(title) · \(freed(m))"); lines += problems.map { "  Problem: \($0)" }
            case .skipped(let why): lines.append("SKIPPED · \(title) · \(why) Nothing was removed.")
            case .notRun(let why): lines.append("NOT RUN · \(title) · \(why)")
            case .failed(let e): lines.append("FAILED · \(title) · \(e)")
            }
            if !r.executed.isEmpty {
                lines.append("  Executed:")
                lines += r.executed.map { "    \($0)" }
            }
            if !r.trashed.isEmpty {
                lines.append("  Moved to the Trash:")
                lines += r.trashed.map { "    \($0.original)" }
            }
            if r.executed.isEmpty && r.trashed.isEmpty {
                lines.append("  Planned, not executed:")
                lines += s.approvedTargets.map { "    \($0.id)" }
            }
            lines.append("")
        }
        for d in run.trashDeletions {
            lines.append("Later, \(d.date.formatted(date: .omitted, time: .shortened)): deleted \(plural(d.deleted.count, "item")) (\(ByteFormat.string(d.bytes))) from the Trash permanently\(d.includedPickedFiles ? ", including your picked files" : ""):")
            lines += d.deleted.map { "    \($0.original)" }
            if !d.refused.isEmpty {
                lines.append("  Refused (moved, replaced or restored since):")
                lines += d.refused.map { "    \($0)" }
            }
        }
        return lines.joined(separator: "\n")
    }
}
