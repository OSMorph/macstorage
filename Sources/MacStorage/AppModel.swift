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
    /// What cleanups since the snapshot changed: cleaned and partly cleaned items, and
    /// picked entries already in the Trash. Derived from History, so it survives relaunches.
    private(set) var cleanupState = CleanupState()
    var cleaned: [String: UUID] { cleanupState.cleaned }
    var removedPicks: [String: Set<String>] { cleanupState.removedPicks }
    /// True until the saved scan and history have been read at launch.
    private(set) var loading = true

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
    /// Set when saving the scan failed; shown above the content with a retry.
    private(set) var scanSaveError: String?
    /// Runs whose record couldn't be saved, with the error. Kept in memory, offered for retry.
    private(set) var unsavedRuns: [UUID: String] = [:]
    /// Set while a cleanup is stopping (after "Stop after this step" or Quit).
    private(set) var stopping = false
    private(set) var fullDiskAccess = FullDiskAccess.isGranted

    private var scanTask: Task<Void, Never>?
    /// Identifies the scan in progress, so late progress from a stopped scan is ignored.
    private var scanID = UUID()
    private var scanStop = StopSignal()
    private var stopSignal = StopSignal()
    private var tools: ToolLocator?
    private let store = HistoryStore()
    /// Called once the run in progress has finished and been saved (to let the app quit).
    var onRunFinished: (() -> Void)?

    init(demo: Bool) {
        self.demo = demo
        if demo {
            load(Demo.snapshot(), history: Demo.history())
            loading = false
        } else {
            let store = store
            Task {
                let (saved, history) = await offload { (store.loadSnapshot(), store.loadHistory()) }
                if let saved { load(saved, history: history) } else { self.history = history }
                loading = false
            }
        }
    }

    var accounting: Accounting? { snapshot.map { Accounting($0, cleaned: Set(cleaned.keys)) } }
    var isRunning: Bool { if case .running? = sheet { true } else { false } }

    private func load(_ snapshot: Snapshot, history: History) {
        self.snapshot = snapshot
        self.history = history
        cleanupState = CleanupState(runs: history.runs, after: snapshot.date)
        dropRemovedPicks()
        selected = Set(snapshot.owners.flatMap(\.items).filter { $0.tier == .safe && $0.isAutomaticCleanup && cleaned[$0.id] == nil }.map(\.id))
    }

    /// Picked entries already in the Trash can't be picked again.
    private func dropRemovedPicks() {
        for (id, removed) in cleanupState.removedPicks { picks[id]?.subtract(removed) }
        picks = picks.filter { !$0.value.isEmpty }
    }

    private func locator() async -> ToolLocator {
        if let tools { return tools }
        let found = await ToolLocator.discover()
        tools = found
        return found
    }

    func refreshAccess() { fullDiskAccess = FullDiskAccess.isGranted }

    // MARK: Scanning

    /// Scans in the background. The first scan shows results as each area finishes;
    /// later scans keep showing the previous one until the new one is done.
    func scan() {
        guard scanning == nil, sheet == nil, !demo else { return }
        refreshAccess()
        let fda = fullDiskAccess, id = UUID(), stop = StopSignal(), firstScan = snapshot == nil || snapshot?.isPartial == true
        scanID = id
        scanStop = stop
        scanning = ScanProgress(finished: [], running: [], total: Scanner.standardProviders.count + 1)
        scanTask = Task {
            let context = ScanContext(tools: Shell(tools: await locator()), fullDiskAccess: fda, stop: stop)
            let result = await Scanner().scan(context) { p in
                Task { @MainActor in
                    guard self.scanID == id else { return }
                    self.scanning = p
                    if firstScan, !p.owners.isEmpty { self.snapshot = p.partialSnapshot() }
                }
            }
            guard scanID == id else { return }
            scanning = nil
            if result.isPartial { return keepPartial(result) }
            await save(result)
        }
    }

    /// Stops the scan. What finished is kept and marked partial (it isn't saved).
    func stopScan() {
        scanStop.stop()
        scanTask?.cancel()
        scanID = UUID()
        if let progress = scanning, !progress.owners.isEmpty, snapshot == nil || snapshot?.isPartial == true {
            keepPartial(progress.partialSnapshot())
        }
        scanning = nil
    }

    private func keepPartial(_ partial: Snapshot) {
        guard snapshot == nil || snapshot?.isPartial == true else { return }
        load(partial, history: history)
    }

    private func save(_ result: Snapshot) async {
        let store = store
        let outcome: Result<History, Error> = await offload {
            Result<History, Error> { try store.save(result); return store.loadHistory() }
        }
        switch outcome {
        case .success(let saved):
            scanSaveError = nil
            // Keep runs whose record couldn't be saved; they're still offered for retry.
            var merged = saved
            merged.runs += history.runs.filter { unsavedRuns[$0.id] != nil && !saved.runs.map(\.id).contains($0.id) }
            merged.runs.sort { $0.started > $1.started }
            load(result, history: merged)
        case .failure(let error):
            scanSaveError = "This scan couldn't be saved (\(error.localizedDescription)). It's shown, but History won't include it."
            load(result, history: history)
            pendingScan = result
        }
    }

    /// The scan whose save failed, for "Try again".
    private var pendingScan: Snapshot?

    func retrySaveScan() {
        guard let scan = pendingScan else { return }
        pendingScan = nil
        Task { await save(scan) }
    }

    /// Cleanup only runs from a recent, complete scan: targets from an old one may be stale.
    static let maxScanAge: TimeInterval = 24 * 3600
    var scanIsTooOld: Bool { !demo && (snapshot.map { Date().timeIntervalSince($0.date) > Self.maxScanAge } ?? true) }

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
        guard !scanIsTooOld, scanning == nil, let plan = plan(), !plan.steps.isEmpty else { return }
        sheet = .preview(plan)
    }

    func run(_ plan: CleanupPlan) {
        stopSignal = StopSignal()
        stopping = false
        sheet = .running(plan, current: 0, outcomes: Array(repeating: nil, count: plan.steps.count))
        let stop = stopSignal, store = store, demo = demo
        Task {
            let report: @Sendable (Int, StepOutcome?) -> Void = { i, o in Task { @MainActor in self.progress(i, o) } }
            // Saved before each step, so quitting or a crash mid-run still leaves a record.
            let journal: @Sendable (RunRecord) -> Void = { record in if !demo { try? store.save(record) } }
            let record: RunRecord
            if demo {
                record = await DemoExecutor.run(plan, stop: stop, progress: report)
            } else {
                record = await CleanupExecutor(tools: Shell(tools: await locator())).run(plan, stop: stop, progress: report, journal: journal)
            }
            await finish(record)
        }
    }

    private func progress(_ index: Int, _ outcome: StepOutcome?) {
        guard case .running(let plan, _, var outcomes)? = sheet else { return }
        if let outcome { outcomes[index] = outcome }
        sheet = .running(plan, current: index, outcomes: outcomes)
    }

    func stopRun() {
        stopping = true
        stopSignal.stop()
    }

    /// Records the run before showing results, so no way of closing the sheet loses it.
    private func finish(_ run: RunRecord) async {
        for r in run.steps {
            if r.outcome.didRun { cleanupState.record(r, run: run.id) }
            // A step whose list changed stays out of the next cleanup until a new scan.
            if case .skipped = r.outcome { selected.remove(r.step.item.id) }
        }
        selected.subtract(cleaned.keys)
        dropRemovedPicks()
        history.runs.insert(run, at: 0)
        await persist(run)
        stopping = false
        sheet = .results(run)
        onRunFinished?()
    }

    func persist(_ run: RunRecord) async {
        guard !demo else { return }
        let store = store
        let error: String? = await offload { do { try store.save(run); return nil } catch { return error.localizedDescription } }
        unsavedRuns[run.id] = error.map { "This cleanup's record couldn't be saved (\($0)). The cleanup itself is done." }
    }

    func deleteFromTrash(_ run: RunRecord, includePicked: Bool) async {
        let chosen = run.stillInTrash.filter { includePicked || !$0.picked }
        let demo = demo, store = store
        // Deleting tens of gigabytes takes a while: keep it off the main actor. The deletion
        // is added to the full record, not the compact copy History loaded.
        let (deleted, refused, full) = await offload {
            let (deleted, refused) = demo ? (chosen, []) : CleanupExecutor.deleteFromTrash(chosen)
            return (deleted, refused, demo ? run : store.fullRun(run.id) ?? run)
        }
        var updated = full
        updated.trashDeletions.append(.init(date: .now, deleted: deleted, refused: refused))
        if let i = history.runs.firstIndex(where: { $0.id == run.id }) { history.runs[i] = updated }
        await persist(updated)
        if case .results? = sheet { sheet = .results(updated) }
    }

    /// The run's receipt file, or the reason it couldn't be written.
    func receipt(_ run: RunRecord) async -> Result<URL, Error> {
        let store = store
        return await offload { Result<URL, Error> { try store.receipt(run) } }
    }

    /// The run as recorded in full (History keeps a compact copy).
    func fullRun(_ run: RunRecord) async -> RunRecord {
        guard !demo else { return run }
        let store = store
        return await offload { store.fullRun(run.id) ?? run }
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
                result = .init(step: step, outcome: .skipped(reason: "An image tag now points at a different image than the one you reviewed, or an image is gone."))
            } else if step.destination == .trash {
                // A log written since the scan is left alone, as the real executor does.
                let changed = step.item.kind == .appLogs ? step.approvedTargets.prefix(1).map(\.id) : []
                let moved = step.approvedTargets.filter { !changed.contains($0.id) }.map {
                    TrashEntry(original: $0.id, landed: "~/.Trash/" + ($0.id as NSString).lastPathComponent, identity: nil, bytes: $0.bytes ?? 0, picked: step.item.tier == .review)
                }
                result = .init(step: step, outcome: .done(measured: moved.map(\.bytes).reduce(0, +)), trashed: moved,
                               leftAlone: changed.map { "\($0): replaced or changed since the scan." })
            } else {
                let listsTargets = if case .runOnTargets = step.item.action { true } else { false }
                let command = CleanupExecutor.command(of: step.item).map { listsTargets ? $0.display(targets: step.approvedTargets.count, unit: step.item.targetUnit) : $0.display() } ?? step.item.name
                // Re-measuring usually finds a little less than predicted.
                result = .init(step: step, outcome: .done(measured: step.expectedBytes * 97 / 100), executed: [command])
            }
            results.append(result)
            progress(i, result.outcome)
        }
        return RunRecord(started: .now, finished: .now, steps: results)
    }
}
