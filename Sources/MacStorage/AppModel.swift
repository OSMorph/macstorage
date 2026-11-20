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
    private(set) var snapshot: Snapshot?
    private(set) var history = History()
    /// Items cleaned since the snapshot, with the run that cleaned them. Excluded from
    /// totals and Cleanup, marked in By owner. Survives relaunches (derived from History).
    private(set) var cleaned: [String: UUID] = [:]
    /// Entries of pickable items that have already gone to the Trash.
    private(set) var removedPicks: [String: Set<String>] = [:]

    var section: AppSection = .overview
    var selectedOwnerID: String?
    var selectedItemID: String?
    var folderPath = "~"
    var selectedFolder: String?
    var search = ""
    /// A run History should open (from "View its receipt" or the results).
    var openRunID: UUID?

    /// Automatic items ticked in Cleanup, and the entries picked for Review items.
    var selected: Set<String> = []
    var picks: [String: Set<String>] = [:]

    private(set) var scanning: ScanProgress?
    var sheet: SheetPhase?
    /// Set when saving a run record failed, so the results can say so and offer a retry.
    private(set) var saveError: String?
    private(set) var fullDiskAccess = FullDiskAccess.isGranted

    private var scanTask: Task<Void, Never>?
    private var stopSignal = StopSignal()
    private var tools: ToolLocator?
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
        // Runs after this snapshot already removed some of its items.
        cleaned = [:]
        removedPicks = [:]
        for run in history.runs where run.started > snapshot.date {
            for r in run.steps where r.outcome.didRun { record(r, run: run.id) }
        }
        selected = Set(snapshot.owners.flatMap(\.items).filter { $0.tier == .safe && $0.isAutomaticCleanup && cleaned[$0.id] == nil }.map(\.id))
    }

    private func record(_ r: RunRecord.StepResult, run: UUID) {
        if r.step.item.action == .pickToTrash {
            removedPicks[r.step.item.id, default: []].formUnion(r.trashed.map(\.original))
            picks[r.step.item.id] = nil
        } else {
            cleaned[r.step.item.id] = run
            selected.remove(r.step.item.id)
        }
    }

    private func locator() async -> ToolLocator {
        if let tools { return tools }
        let found = await ToolLocator.discover()
        tools = found
        return found
    }

    // MARK: Scanning

    func scan() {
        guard scanning == nil, !demo else { return }
        fullDiskAccess = FullDiskAccess.isGranted
        scanning = ScanProgress(finished: [], running: [], total: Scanner.standardProviders.count)
        let fda = fullDiskAccess
        scanTask = Task {
            let context = ScanContext(tools: Shell(tools: await locator()), fullDiskAccess: fda)
            let result = await Scanner().scan(context) { p in Task { @MainActor in self.scanning = p } }
            guard !Task.isCancelled else { return }
            do { try store.save(result) } catch { saveError = "The scan couldn't be saved: \(error.localizedDescription)" }
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

    /// The sidebar badge: ticked automatic items plus Review items with picks. Cheap enough
    /// to compute on every render, unlike building the plan.
    var cleanupCount: Int {
        selected.filter { cleaned[$0] == nil }.count + picks.values.filter { !$0.isEmpty }.count
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
            let report: @Sendable (Int, StepOutcome?) -> Void = { i, o in Task { @MainActor in self.progress(i, o) } }
            let record: RunRecord
            if demo {
                record = await DemoExecutor.run(plan, stop: stop, progress: report)
            } else {
                record = await CleanupExecutor(tools: Shell(tools: await locator())).run(plan, stop: stop, progress: report)
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
    private func finish(_ run: RunRecord) {
        for r in run.steps where r.outcome.didRun { record(r, run: run.id) }
        history.runs.insert(run, at: 0)
        persist(run)
        sheet = .results(run)
    }

    func persist(_ run: RunRecord) {
        guard !demo else { return }
        do {
            try store.save(run)
            saveError = nil
        } catch {
            saveError = "This cleanup's record couldn't be saved (\(error.localizedDescription)). The cleanup itself is done."
        }
    }

    func deleteFromTrash(_ run: RunRecord, includePicked: Bool) {
        let chosen = run.stillInTrash.filter { includePicked || !$0.picked }
        let (deleted, refused) = demo ? (chosen, []) : CleanupExecutor.deleteFromTrash(chosen)
        var updated = run
        updated.trashDeletions.append(.init(date: .now, deleted: deleted, refused: refused))
        if let i = history.runs.firstIndex(where: { $0.id == run.id }) { history.runs[i] = updated }
        persist(updated)
        sheet = .results(updated)
    }

    func receiptURL(_ run: RunRecord) -> URL? {
        guard !demo else { return nil }
        return try? store.saveReceipt(run)
    }

    // MARK: Navigation

    func show(owner id: String, item: String? = nil) {
        section = .owners
        selectedOwnerID = id
        selectedItemID = item ?? snapshot?.owner(id)?.items.first { $0.tier != .leaveAlone && $0.tier != .notRemovable }?.id
    }

    /// For the automated screenshot tour: show the welcome screen without data.
    func setSnapshot(_ s: Snapshot?) { snapshot = s }
}

enum FullDiskAccess {
    /// Readable only with Full Disk Access.
    static var isGranted: Bool {
        FileManager.default.isReadableFile(atPath: NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db")
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
    }
}

/// Simulates a run in demo mode: nothing is touched. Docker images are skipped as if the
/// re-check found a changed list, to show that path.
enum DemoExecutor {
    static func run(_ plan: CleanupPlan, stop: StopSignal, progress: @Sendable @escaping (Int, StepOutcome?) -> Void) async -> RunRecord {
        var results: [RunRecord.StepResult] = []
        for (i, step) in plan.steps.enumerated() {
            if stop.isStopped { results.append(.init(step: step, outcome: .notRun(reason: "Cleanup was stopped before this step."))); continue }
            progress(i, nil)
            try? await Task.sleep(for: .milliseconds(350))
            let result: RunRecord.StepResult
            if step.item.kind == .dockerUnusedImages {
                result = .init(step: step, outcome: .skipped(reason: "A container started after the preview uses one of these images, so the list no longer matches what you approved."))
            } else if step.destination == .trash {
                let moved = step.approvedTargets.map { TrashEntry(original: $0.id, landed: "~/.Trash/" + ($0.id as NSString).lastPathComponent,
                                                                  identity: nil, bytes: $0.bytes ?? 0, picked: step.item.tier == .review) }
                result = .init(step: step, outcome: .done(measured: moved.map(\.bytes).reduce(0, +)), trashed: moved)
            } else {
                let command = CleanupExecutor.command(of: step.item)?.display(targets: step.approvedTargets.count, unit: step.item.targetUnit) ?? step.item.name
                // Re-measuring usually finds a little less than predicted.
                result = .init(step: step, outcome: .done(measured: step.expectedBytes * 97 / 100), executed: [command])
            }
            results.append(result)
            progress(i, result.outcome)
        }
        return RunRecord(started: .now, finished: .now, steps: results)
    }
}
