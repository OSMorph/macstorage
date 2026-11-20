import AppKit
import Observation
import StorageCore
import StorageMac

enum AppSection: String, CaseIterable, Identifiable {
    case overview, owners, folders, history, cleanup, coverage
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .owners: "By owner"
        case .folders: "By folder"
        case .history: "History"
        case .cleanup: "Cleanup"
        case .coverage: "Scan coverage"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "circle.lefthalf.filled"
        case .owners: "square.grid.2x2"
        case .folders: "folder"
        case .history: "chart.line.uptrend.xyaxis"
        case .cleanup: "trash"
        case .coverage: "scope"
        }
    }
}

/// The phases of the cleanup sheet.
enum SheetPhase: Equatable {
    case preview(CleanupPlan)
    case running(CleanupPlan, current: Int, outcomes: [StepOutcome?])
    case results(RunRecord)
}

/// Everything the window shows. Every view reads totals from `accounting`, so they agree.
@MainActor @Observable
final class AppModel {
    let demo: Bool
    var snapshot: Snapshot?
    var history = History()
    /// Items cleaned since the snapshot: excluded from totals and Cleanup, marked in By owner.
    var cleaned: [String: UUID] = [:]

    var section: AppSection = .overview
    var selectedOwnerID: String?
    var selectedItemID: String?
    var folderPath = "~"
    var selectedFolder: String?
    var search = ""
    /// A run History should open and focus (from an item's "View its receipt").
    var openRunID: UUID?

    /// Automatic items ticked in Cleanup, and the entries picked for Review items.
    var selected: Set<String> = []
    var picks: [String: Set<String>] = [:]

    var scanning: ScanProgress?
    var sheet: SheetPhase?
    var fullDiskAccess = FullDiskAccess.isGranted

    private var scanTask: Task<Void, Never>?
    private var stopSignal = StopSignal()
    private let store = HistoryStore()

    init(demo: Bool) {
        self.demo = demo
        if demo {
            load(Demo.snapshot(), history: Demo.history())
        } else if let saved = store.loadSnapshot() {
            load(saved, history: store.loadHistory())
        }
    }

    var accounting: Accounting? { snapshot.map { Accounting($0, cleaned: Set(cleaned.keys)) } }

    private func load(_ snapshot: Snapshot, history: History) {
        self.snapshot = snapshot
        self.history = history
        cleaned = [:]
        selected = Set(snapshot.owners.flatMap(\.items).filter { $0.tier == .safe && $0.isAutomaticCleanup }.map(\.id))
    }

    // MARK: Scanning

    func scan() {
        guard scanning == nil else { return }
        fullDiskAccess = FullDiskAccess.isGranted
        if demo { return }
        scanning = ScanProgress(finished: [], running: [], total: Scanner.standardProviders.count)
        let fda = fullDiskAccess
        scanTask = Task {
            let result = await Scanner().scan(fullDiskAccess: fda) { p in Task { @MainActor in self.scanning = p } }
            guard !Task.isCancelled else { return }
            try? store.save(result)
            load(result, history: store.loadHistory())
            scanning = nil
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanning = nil
    }

    // MARK: Cleanup

    func plan() -> CleanupPlan? {
        guard let snapshot else { return nil }
        let picked = picks.mapValues { ids in ids.map { Target($0) } }
        return CleanupPlan(snapshot: snapshot, selected: selected, picks: picked, cleaned: Set(cleaned.keys))
    }

    func openPreview() {
        guard let plan = plan(), !plan.steps.isEmpty else { return }
        sheet = .preview(plan)
    }

    func run(_ plan: CleanupPlan) {
        stopSignal = StopSignal()
        sheet = .running(plan, current: 0, outcomes: Array(repeating: nil, count: plan.steps.count))
        let stop = stopSignal
        Task {
            let record: RunRecord
            if demo {
                record = await DemoExecutor.run(plan, stop: stop) { i, o in Task { @MainActor in self.progress(i, o) } }
            } else {
                let executor = CleanupExecutor(shell: Shell(tools: await ToolLocator.discover()))
                record = await executor.run(plan, stop: stop) { i, o in Task { @MainActor in self.progress(i, o) } }
            }
            finish(record)
        }
    }

    private func progress(_ index: Int, _ outcome: StepOutcome?) {
        guard case .running(let plan, _, var outcomes)? = sheet else { return }
        if let outcome { outcomes[index] = outcome }
        sheet = .running(plan, current: index, outcomes: outcomes)
    }

    func stopRun() { stopSignal.stop() }

    /// Records the run before showing results, so no way of closing the sheet loses it.
    private func finish(_ record: RunRecord) {
        for r in record.steps where r.outcome.didRun {
            if r.step.item.action == .pickToTrash {
                picks[r.step.item.id] = nil
                removedPicks[r.step.item.id, default: []].formUnion(r.step.approvedTargets.map(\.id))
            } else {
                cleaned[r.step.item.id] = record.id
                selected.remove(r.step.item.id)
            }
        }
        history.runs.insert(record, at: 0)
        if !demo { try? store.save(record) }
        sheet = .results(record)
    }

    /// Entries already moved to the Trash: no longer offered in pickers.
    var removedPicks: [String: Set<String>] = [:]

    func deleteFromTrash(_ run: RunRecord, includePicked: Bool) {
        let chosen = run.steps.filter { $0.outcome.didRun && $0.step.destination == .trash && (includePicked || $0.step.item.tier != .review) }
        let locations = chosen.flatMap(\.trashLocations)
        let deleted = Set(demo ? locations : CleanupExecutor.deleteFromTrash(locations))
        let gone = chosen.filter { !Set($0.trashLocations).isDisjoint(with: deleted) }
        var updated = run
        updated.trashDeletions.append(.init(date: .now, paths: gone.flatMap(\.executed), bytes: gone.compactMap {
            if case .done(let b) = $0.outcome { b } else { nil }
        }.reduce(0, +), includedPickedFiles: gone.contains { $0.step.item.tier == .review }))
        if let i = history.runs.firstIndex(where: { $0.id == run.id }) { history.runs[i] = updated }
        if !demo { try? store.save(updated) }
        sheet = .results(updated)
    }

    func saveReceipt(_ run: RunRecord) -> URL? { demo ? nil : try? store.saveReceipt(run) }

    // MARK: Navigation

    func show(owner id: String, item: String? = nil) {
        section = .owners
        selectedOwnerID = id
        selectedItemID = item ?? snapshot?.owner(id)?.items.first { $0.tier != .leaveAlone && $0.tier != .notRemovable }?.id
    }

    var cleanupCount: Int { plan()?.steps.count ?? 0 }
}

enum FullDiskAccess {
    /// Readable only with Full Disk Access.
    static var isGranted: Bool {
        FileManager.default.isReadableFile(atPath: NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db")
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}

/// Simulates a run in demo mode: nothing is touched. The first time Docker images are
/// included, the re-check finds a changed list and skips them, to show that path.
enum DemoExecutor {
    static func run(_ plan: CleanupPlan, stop: StopSignal, progress: @Sendable @escaping (Int, StepOutcome?) -> Void) async -> RunRecord {
        var results: [RunRecord.StepResult] = []
        for (i, step) in plan.steps.enumerated() {
            if stop.isStopped { results.append(.init(step: step, outcome: .notRun)); continue }
            progress(i, nil)
            try? await Task.sleep(for: .milliseconds(350))
            let outcome: StepOutcome = step.id == "dockerUnusedImages"
                ? .skipped(reason: "A container started after the preview uses one of these images, so the list no longer matches what you approved.")
                : .done(freedBytes: step.expectedBytes)
            let executed = step.destination == .trash ? step.approvedTargets.map(\.id) : [demoCommand(step)]
            results.append(.init(step: step, outcome: outcome, executed: outcome.didRun ? executed : [],
                                 trashLocations: step.destination == .trash ? step.approvedTargets.map { "~/.Trash/" + ($0.id as NSString).lastPathComponent } : []))
            progress(i, outcome)
        }
        return RunRecord(started: .now, finished: .now, steps: results)
    }

    static func demoCommand(_ step: CleanupStep) -> String {
        switch step.item.action {
        case .runOnTargets(let c, _), .runAfterRecheck(let c, _), .clearFolder(let c, _, _): c.display(targets: step.approvedTargets.count, unit: step.item.targetUnit)
        default: step.item.name
        }
    }
}
