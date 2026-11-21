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

    /// "≤ " when the expected figure is an upper bound, "≥ " when it's a lower bound.
    public var boundPrefix: String {
        guard expectedBytes > 0 else { return "" }
        if item.reclaimableIsUpperBound { return "≤ " }
        if case .atLeast = item.reclaimable, item.action != .pickToTrash { return "≥ " }
        return ""
    }

    /// The expected figure with its bound: "≤ 7.5 GB".
    public var expectedText: String { boundPrefix + ByteFormat.string(expectedBytes) }

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

    /// A destination's expected total with its bound: "≤" if any part is an upper bound,
    /// otherwise "≥" if any part is a lower bound.
    public func expectedText(_ d: Destination) -> String {
        let prefixes = Set(steps.filter { $0.destination == d }.map(\.boundPrefix))
        let prefix = prefixes.contains("≤ ") ? "≤ " : prefixes.contains("≥ ") ? "≥ " : ""
        return (expected(d) > 0 ? prefix : "") + ByteFormat.string(expected(d))
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

    /// True when the step removed something (all or part of what was approved).
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

    public var isDone: Bool { if case .done = self { true } else { false } }
    public var isPartial: Bool { if case .partial = self { true } else { false } }

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
    /// True when `bytes` couldn't be measured completely (the scan's figure stands in).
    public var isEstimate: Bool {
        get { estimate ?? false }
        set { estimate = newValue ? true : nil }
    }
    private var estimate: Bool?

    public init(original: String, landed: String, identity: FileIdentity?, bytes: Int64, picked: Bool, isEstimate: Bool = false) {
        self.original = original
        self.landed = landed
        self.identity = identity
        self.bytes = bytes
        self.picked = picked
        self.isEstimate = isEstimate
    }
}

extension Array where Element == TrashEntry {
    /// Their total, with "≈ " when any size is an estimate.
    public var bytesText: String {
        (contains(where: \.isEstimate) ? "≈ " : "") + ByteFormat.string(map(\.bytes).reduce(0, +))
    }
}

/// The single record of a cleanup run. Results, the receipt and History all read it.
public struct RunRecord: Codable, Equatable, Identifiable, Sendable {
    public struct StepResult: Codable, Equatable, Sendable {
        public var step: CleanupStep
        public var outcome: StepOutcome
        /// Every command the app started, in order, including one that failed (its
        /// failure is noted after it). Empty for Trash moves.
        public var executed: [String]
        /// What actually went to the Trash.
        public var trashed: [TrashEntry]
        /// Approved targets the app deliberately didn't touch, and why (changed since the
        /// scan, already gone, its checkout is in use again…). Not a failure: the run goes on.
        public var leftAlone: [String]

        public init(step: CleanupStep, outcome: StepOutcome, executed: [String] = [], trashed: [TrashEntry] = [], leftAlone: [String] = []) {
            self.step = step
            self.outcome = outcome
            self.executed = executed
            self.trashed = trashed
            self.leftAlone = leftAlone
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            step = try c.decode(CleanupStep.self, forKey: .step)
            outcome = try c.decode(StepOutcome.self, forKey: .outcome)
            executed = try c.decode([String].self, forKey: .executed)
            trashed = try c.decode([TrashEntry].self, forKey: .trashed)
            leftAlone = try c.decodeIfPresent([String].self, forKey: .leftAlone) ?? []
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
        public var isEstimate: Bool { deleted.contains(where: \.isEstimate) }
        public var includedPickedFiles: Bool { deleted.contains(where: \.picked) }
    }

    public var id: UUID
    public var started: Date
    public var finished: Date
    public var steps: [StepResult]
    public var trashDeletions: [TrashDeletion]
    /// True for the compact copy History keeps (target lists and commands shortened).
    /// The full record is stored separately.
    public var isCompact: Bool {
        get { compact ?? false }
        set { compact = newValue ? true : nil }
    }
    private var compact: Bool?

    public init(id: UUID = UUID(), started: Date, finished: Date, steps: [StepResult], trashDeletions: [TrashDeletion] = []) {
        self.id = id
        self.started = started
        self.finished = finished
        self.steps = steps
        self.trashDeletions = trashDeletions
    }

    /// Steps that removed everything approved.
    public var doneCount: Int { steps.filter { $0.outcome.isDone && $0.leftAlone.isEmpty }.count }
    /// Steps that removed part of what was approved: stopped by a problem, or with targets left alone.
    public var partialCount: Int { steps.filter { $0.outcome.isPartial || ($0.outcome.isDone && !$0.leftAlone.isEmpty) }.count }

    /// "3 of 5 steps done, 1 partly done"
    public var progressText: String {
        "\(doneCount) of \(plural(steps.count, "step")) done" + (partialCount > 0 ? ", \(partialCount) partly done" : "")
    }

    /// Re-measured bytes freed per destination.
    public func freed(_ d: Destination) -> Int64 {
        steps.filter { $0.step.destination == d }.compactMap(\.outcome.measured).reduce(0, +)
    }

    /// Predicted bytes for steps that ran but couldn't be re-measured.
    public func unmeasured(_ d: Destination) -> Int64 {
        steps.filter { $0.step.destination == d && $0.outcome.didRun && $0.outcome.measured == nil }.map(\.step.expectedBytes).reduce(0, +)
    }

    /// Steps in a destination that ran but couldn't be re-measured.
    public func unmeasuredCount(_ d: Destination) -> Int {
        steps.filter { $0.step.destination == d && $0.outcome.didRun && $0.outcome.measured == nil }.count
    }

    /// What the preview predicted for the steps that ran, with its bound ("≤ 21.5 GB").
    public func predictedText(_ d: Destination) -> String {
        let ran = steps.filter { $0.step.destination == d && $0.outcome.didRun }.map(\.step)
        let prefixes = Set(ran.map(\.boundPrefix))
        return (prefixes.contains("≤ ") ? "≤ " : prefixes.contains("≥ ") ? "≥ " : "") + ByteFormat.string(predicted(d))
    }

    /// What the preview predicted for the steps that ran, per destination.
    public func predicted(_ d: Destination) -> Int64 {
        steps.filter { $0.step.destination == d && $0.outcome.didRun }.map(\.step.expectedBytes).reduce(0, +)
    }

    /// Everything this run put in the Trash, the user's own files first.
    public var trashed: [TrashEntry] {
        steps.flatMap(\.trashed).sorted { $0.picked && !$1.picked }
    }

    public var deletedFromTrash: Int64 { trashDeletions.map(\.bytes).reduce(0, +) }
    /// True when part of what was deleted from the Trash couldn't be measured.
    public var deletedFromTrashIsEstimate: Bool { trashDeletions.contains(where: \.isEstimate) }
    /// Freed on the Mac by commands, plus whatever was later deleted from the Trash.
    public var freedOnMac: Int64 { freed(.mac) + deletedFromTrash }
    /// This run's entries that are still in the Trash.
    public var stillInTrash: [TrashEntry] {
        let gone = Set(trashDeletions.flatMap(\.deleted).map(\.landed))
        return trashed.filter { !gone.contains($0.landed) }
    }
}

extension ItemKind {
    /// How "measured" is measured, when it's wider than the step's own targets.
    public var measurementNote: String? {
        switch self {
        case .nixDeadPaths: "as the change in the whole /nix volume"
        case .dockerBuildCache: "as the change in the engine's whole build cache"
        case .dockerUnusedImages: "as the change in all the engine's images"
        default: nil
        }
    }
}

public enum Receipt {
    /// The plain-text receipt, the same in History and in the saved file. Each step leads
    /// with its outcome, then what ran, what moved, what was left alone, and the approved list.
    public static func text(_ run: RunRecord) -> String {
        var lines = ["macstorage cleanup receipt",
                     "Started \(run.started.formatted(date: .abbreviated, time: .shortened)), \(run.progressText)", ""]
        for r in run.steps {
            let s = r.step, title = "\(s.ownerName) · \(s.item.name)"
            let freed = { (m: Int64?) in m.map { "\(ByteFormat.string($0)) \(s.destination == .trash ? "moved to the Trash" : s.destination == .containerDisk ? "freed inside Docker's disk" : "freed"), measured" + (s.item.kind.measurementNote.map { " " + $0 } ?? "") }
                ?? "predicted \(s.expectedText), not re-measured" }
            switch r.outcome {
            case .done(let m): lines.append("DONE · \(title) · \(freed(m))" + (m == nil ? "" : " (predicted \(s.expectedText))"))
            case .partial(let m, let problems): lines.append("PARTLY DONE · \(title) · \(freed(m))"); lines += problems.map { "  Problem: \($0)" }
            case .skipped(let why): lines.append("SKIPPED · \(title) · \(why) Nothing was removed.")
            case .notRun(let why): lines.append("NOT RUN · \(title) · \(why)")
            case .failed(let e): lines.append("FAILED · \(title) · \(e)")
            }
            if !r.executed.isEmpty {
                lines.append("  Commands run:")
                lines += r.executed.map { "    \($0)" }
            }
            if !r.trashed.isEmpty {
                lines.append("  Moved to the Trash:")
                lines += r.trashed.map { "    \($0.original)" }
            }
            if !r.leftAlone.isEmpty {
                lines.append("  Left alone:")
                lines += r.leftAlone.map { "    \($0)" }
            }
            // The approved list, always: a folder-clearing command doesn't name what it removed.
            if !s.approvedTargets.isEmpty {
                let ran = !(r.executed.isEmpty && r.trashed.isEmpty && r.leftAlone.isEmpty)
                lines.append(ran ? "  Approved (\(plural(s.approvedTargets.count, s.item.targetUnit))):" : "  Planned, not executed:")
                lines += s.approvedTargets.map { "    \($0.id)" }
            }
            lines.append("")
        }
        for d in run.trashDeletions {
            lines.append("Later, \(d.date.formatted(date: .omitted, time: .shortened)): deleted \(plural(d.deleted.count, "item")) (\(d.deleted.bytesText)) from the Trash permanently\(d.includedPickedFiles ? ", including your picked files" : ""):")
            lines += d.deleted.map { "    \($0.original)" }
            if !d.refused.isEmpty {
                lines.append("  Refused (moved, replaced or restored since):")
                lines += d.refused.map { "    \($0)" }
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// What runs after a snapshot changed about its items, so the UI can mark them without a
/// new scan. Derived from History, so it survives relaunches.
public struct CleanupState: Equatable, Sendable {
    /// Items whose step finished completely, with the run that did it.
    public var cleaned: [String: UUID] = [:]
    /// Items whose step removed only part of what was approved, or left some alone. Like
    /// cleaned items, they leave the totals and Cleanup until a new scan.
    public var partlyCleaned: [String: UUID] = [:]
    /// Entries of pickable items that are already in the Trash.
    public var removedPicks: [String: Set<String>] = [:]
    /// Items whose step was skipped because their list changed: not ticked again until a new scan.
    public var skipped: Set<String> = []

    public init() {}

    public init(runs: [RunRecord], after date: Date) {
        for run in runs.sorted(by: { $0.started < $1.started }) where run.started > date {
            for r in run.steps { record(r, run: run.id) }
        }
    }

    public mutating func record(_ r: RunRecord.StepResult, run: UUID) {
        let id = r.step.item.id
        // A changed list stays unticked until a new scan. Trash steps skip for reasons that
        // pass (a running app), so they stay ticked.
        if case .skipped = r.outcome {
            if r.step.destination != .trash { skipped.insert(id) }
            return
        }
        guard r.outcome.didRun else { return }
        if r.step.item.action == .pickToTrash {
            removedPicks[id, default: []].formUnion(r.trashed.map(\.original))
        } else if r.outcome.isDone && r.leftAlone.isEmpty {
            cleaned[id] = run
            partlyCleaned[id] = nil
        } else {
            // Partly done, or done with some left alone: what's left is unknown until a new
            // scan, so the item leaves the totals and Cleanup, marked partly cleaned.
            partlyCleaned[id] = run
        }
    }
}
