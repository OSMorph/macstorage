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
    private(set) var snapshot: Snapshot? {
        didSet {
            refreshPlan()
            if oldValue?.date != snapshot?.date { forgetMeasuredFolders() }
        }
    }
    private(set) var history = History()
    /// What cleanups since the snapshot changed: cleaned and partly cleaned items, and
    /// picked entries already in the Trash. Derived from History, so it survives relaunches.
    private(set) var cleanupState = CleanupState() { didSet { refreshPlan() } }
    var cleaned: [String: UUID] { cleanupState.cleaned }
    var removedPicks: [String: Set<String>] { cleanupState.removedPicks }
    /// True until the saved scan and history have been read at launch.
    private(set) var loading = true

    var section: AppSection = .overview
    var selectedOwnerID: String?
    var selectedItemID: String?
    /// The By folder level shown ("~", "~/Library/Caches"). Change it with `openFolder`.
    private(set) var folderPath = "~"
    var selectedFolder: String?
    /// Levels below what the scan measured, measured when opened, by path.
    private(set) var measuredFolders: [String: FolderLevel] = [:]
    private var folderStop = StopSignal()
    var search = ""
    /// A run History should open (from "View its receipt" or the results).
    var openRunID: UUID?

    /// Automatic items ticked in Cleanup, and the entries picked for Review items.
    var selected: Set<String> = [] { didSet { refreshPlan() } }
    var picks: [String: Set<String>] = [:] { didSet { refreshPlan() } }
    /// The plan for what's ticked and picked, kept current as those change so views don't
    /// rebuild it on every render. The preview builds a fresh one (with its own time).
    private(set) var currentPlan: CleanupPlan?

    private(set) var scanning: ScanProgress?
    var sheet: SheetPhase?
    /// Set when saving the scan failed; shown above the content with a retry.
    private(set) var scanSaveError: String?
    /// Runs whose record couldn't be saved, with the error. Kept in memory, offered for retry.
    private(set) var unsavedRuns: [UUID: String] = [:]
    /// Set while a cleanup is stopping (after "Stop after this step" or Quit).
    private(set) var stopping = false
    /// Set when the user quit during a cleanup: the app quits once the run is recorded.
    private(set) var quitting = false
    /// Set when the in-progress record couldn't be saved during the run.
    private(set) var journalFailed = false
    private(set) var fullDiskAccess = FullDiskAccess.isGranted

    private var scanTask: Task<Void, Never>?
    /// Identifies the scan in progress, so late progress from a stopped scan is ignored.
    private var scanID = UUID()
    private var scanStop = StopSignal()
    private var stopSignal = StopSignal()
    private var tools: ToolLocator?
    private let store = HistoryStore()
    /// Called once the cleanup or Trash deletion in progress has finished, with whether
    /// its record was saved.
    private var onRunFinished: ((Bool) -> Void)?
    /// True while items are being deleted from the Trash.
    private(set) var deletingFromTrash = false

    /// Work that must finish (and be recorded) before the app quits.
    var isBusy: Bool { isRunning || deletingFromTrash }

    /// Quit during a cleanup or Trash deletion: a cleanup stops after the current step.
    /// `done` gets whether the record was saved; the app stays open if it wasn't.
    func quitWhenDone(_ done: @escaping (Bool) -> Void) {
        quitting = true
        onRunFinished = done
        if isRunning { stopRun() }
    }

    private func finishedBusyWork(saved: Bool) {
        let done = onRunFinished
        onRunFinished = nil
        quitting = false
        done?(saved)
    }

    /// Saves every record that couldn't be saved before; true when none is left unsaved.
    func retryUnsaved() async -> Bool {
        for run in history.runs where unsavedRuns[run.id] != nil { await persist(run) }
        return unsavedRuns.isEmpty
    }

    init(demo: Bool) {
        self.demo = demo
        if demo {
            load(Demo.snapshot(), history: Demo.history())
            loading = false
        } else {
            let store = store
            Task {
                let (saved, history) = await offload { store.recoverJournaledRuns(); return (store.loadSnapshot(), store.loadHistory()) }
                if let saved { load(saved, history: history) } else { self.history = history }
                loading = false
            }
        }
    }

    /// Items a cleanup since this scan acted on, fully or partly. They leave the totals and
    /// Cleanup until a new scan: what's left of a partly cleaned item isn't known.
    var actedOn: Set<String> { Set(cleaned.keys).union(cleanupState.partlyCleaned.keys) }

    var accounting: Accounting? { snapshot.map { Accounting($0, cleaned: Set(cleaned.keys), partlyCleaned: Set(cleanupState.partlyCleaned.keys)) } }
    var isRunning: Bool { if case .running? = sheet { true } else { false } }

    private func load(_ snapshot: Snapshot, history: History) {
        self.snapshot = snapshot
        self.history = history
        cleanupState = CleanupState(runs: history.runs, after: snapshot.date)
        dropRemovedPicks()
        // Safe items start ticked, except what a cleanup since this scan cleaned or skipped.
        selected = Set(snapshot.owners.flatMap(\.items).filter { $0.tier == .safe && $0.isAutomaticCleanup }.map(\.id))
            .subtracting(actedOn).subtracting(cleanupState.skipped)
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

    func refreshAccess() {
        let granted = FullDiskAccess.isGranted
        guard granted != fullDiskAccess else { return }
        fullDiskAccess = granted
        // Levels measured with the other access list different folders as protected.
        folderStop.stop()
        measuredFolders = [:]
        if snapshot?.folders[folderPath] == nil { openFolder(folderPath) }
    }

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
            // Runs whose record couldn't be saved stay as they are in memory (complete),
            // replacing any older copy on disk; they're still offered for retry.
            var merged = saved
            merged.runs.removeAll { unsavedRuns[$0.id] != nil }
            merged.runs += history.runs.filter { unsavedRuns[$0.id] != nil }
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

    /// Cleanup only runs from a recent, complete scan: targets from an old one may be stale,
    /// and a stopped scan hasn't checked everything. Returns why cleanup is unavailable.
    static let maxScanAge: TimeInterval = 24 * 3600
    var cleanupBlocked: String? {
        guard !demo, let snapshot else { return demo ? nil : "Scan first." }
        if scanning != nil { return "Wait for the scan to finish." }
        if snapshot.isPartial { return "This scan was stopped before it finished. Scan again before cleaning up." }
        if Date().timeIntervalSince(snapshot.date) > Self.maxScanAge { return "The last scan is more than a day old. Scan again before cleaning up, so the lists are current." }
        return nil
    }

    // MARK: Cleanup

    private func makePlan() -> CleanupPlan? {
        guard let snapshot else { return nil }
        let picked = picks.mapValues { ids in ids.map { Target($0) } }
        return CleanupPlan(snapshot: snapshot, selected: selected, picks: picked, cleaned: actedOn)
    }

    private func refreshPlan() { currentPlan = makePlan() }

    /// The sidebar badge: ticked automatic items plus Review items with picks. Cheap enough
    /// to compute on every render, unlike building the plan.
    var cleanupCount: Int {
        selected.subtracting(actedOn).count + picks.values.filter { !$0.isEmpty }.count
    }

    func openPreview() {
        guard cleanupBlocked == nil, let plan = makePlan(), !plan.steps.isEmpty else { return }
        sheet = .preview(plan)
    }

    func run(_ plan: CleanupPlan) {
        stopSignal = StopSignal()
        stopping = false
        journalFailed = false
        sheet = .running(plan, current: 0, outcomes: Array(repeating: nil, count: plan.steps.count))
        let stop = stopSignal, store = store, demo = demo
        Task {
            let report: @Sendable (Int, StepOutcome?) -> Void = { i, o in Task { @MainActor in self.progress(i, o) } }
            // Saved before each step, so quitting or a crash mid-run still leaves a record.
            // If it can't be saved, the run stops before changing anything else.
            let journal: @Sendable (RunRecord) -> Bool = { record in
                guard !demo else { return true }
                do {
                    try store.journal(record)
                    return true
                } catch {
                    Task { @MainActor in self.journalFailed = true }
                    return false
                }
            }
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
        for r in run.steps { cleanupState.record(r, run: run.id) }
        // Cleaned steps leave Cleanup; a step whose list changed stays out until a new scan.
        selected.subtract(actedOn)
        selected.subtract(cleanupState.skipped)
        dropRemovedPicks()
        history.runs.insert(run, at: 0)
        await persist(run)
        stopping = false
        sheet = .results(run)
        finishedBusyWork(saved: unsavedRuns.isEmpty)
    }

    func persist(_ run: RunRecord) async {
        guard !demo else { return }
        let store = store
        let error: String? = await offload { do { try store.save(run); return nil } catch { return error.localizedDescription } }
        unsavedRuns[run.id] = error.map { "This cleanup's record couldn't be saved (\($0)). The cleanup itself is done." }
    }

    func deleteFromTrash(_ run: RunRecord, includePicked: Bool) async {
        deletingFromTrash = true
        defer { deletingFromTrash = false; finishedBusyWork(saved: unsavedRuns.isEmpty) }
        let chosen = run.stillInTrash.filter { includePicked || !$0.picked }
        // The record on disk is the full one, unless this session has changes it couldn't save.
        let demo = demo, store = store, useMemory = demo || unsavedRuns[run.id] != nil
        // Deleting tens of gigabytes takes a while: keep it off the main actor. The deletion
        // is added to the full record, not the compact copy History loaded.
        let (deleted, refused, full) = await offload {
            let (deleted, refused) = demo ? (chosen, []) : CleanupExecutor.deleteFromTrash(chosen)
            return (deleted, refused, useMemory ? run : store.fullRun(run.id) ?? run)
        }
        var updated = full
        updated.trashDeletions.append(.init(date: .now, deleted: deleted, refused: refused))
        if let i = history.runs.firstIndex(where: { $0.id == run.id }) { history.runs[i] = updated }
        await persist(updated)
        if case .results? = sheet { sheet = .results(updated) }
    }

    /// The run's receipt file, or the reason it couldn't be written. While the run's record
    /// is unsaved, the receipt is written from the record in memory, the latest one.
    func receipt(_ run: RunRecord) async -> Result<URL, Error> {
        let store = store, latest = unsavedRuns[run.id] != nil ? history.runs.first { $0.id == run.id } ?? run : nil
        return await offload { Result<URL, Error> { try latest.map(store.writeReceipt) ?? store.receipt(run) } }
    }

    /// The run as recorded in full (History keeps a compact copy); the one in memory while
    /// it's unsaved.
    func fullRun(_ run: RunRecord) async -> RunRecord {
        if demo { return run }
        if unsavedRuns[run.id] != nil { return history.runs.first { $0.id == run.id } ?? run }
        let store = store
        return await offload { store.fullRun(run.id) ?? run }
    }

    /// Lists a skipped folder-clearing item again and ticks it, so it can run without a
    /// full scan. Returns false if the folder couldn't be listed completely.
    func refresh(_ itemID: String) async -> Bool {
        guard let snapshot, let o = snapshot.owners.firstIndex(where: { $0.items.contains { $0.id == itemID } }),
              let i = snapshot.owners[o].items.firstIndex(where: { $0.id == itemID }),
              let fresh = await LanguageCachesProvider.refreshed(snapshot.owners[o].items[i],
                                                                 ScanContext(tools: Shell(tools: await locator()), fullDiskAccess: fullDiskAccess)) else { return false }
        self.snapshot?.owners[o].items[i] = fresh
        cleanupState.skipped.remove(itemID)
        selected.insert(itemID)
        return true
    }

    // MARK: Navigation

    func show(owner id: String, item: String? = nil) {
        section = .owners
        selectedOwnerID = id
        selectedItemID = item ?? snapshot?.owner(id)?.items.first { $0.tier != .leaveAlone && $0.tier != .notRemovable }?.id
    }

    // MARK: By folder

    /// The entries at `path`: the scan's for the home folder and Library, otherwise those
    /// measured since it was opened.
    func folderLevel(_ path: String) -> FolderLevel? {
        snapshot?.folders[path].map { FolderLevel(entries: $0) } ?? measuredFolders[path]
    }

    /// True when the entry can be opened: a folder with a size (one macOS protects
    /// without Full Disk Access has none). Sample data only has the levels it ships with.
    func canOpen(_ entry: FolderEntry) -> Bool {
        demo ? snapshot?.folders[folderPath + "/" + entry.name] != nil : entry.isFolder != false && entry.bytes != nil
    }

    /// Shows the level at `path`, measuring it if the scan didn't. Leaving a level that's
    /// still being measured stops that measurement and drops what it found so far.
    func openFolder(_ path: String) {
        folderPath = path
        selectedFolder = nil
        if let level = measuredFolders.first(where: { $0.value.isMeasuring && $0.key != path }) {
            folderStop.stop()
            measuredFolders[level.key] = nil
        }
        guard !demo, let snapshot, snapshot.folders[path] == nil, measuredFolders[path] == nil || measuredFolders[path]?.unreadable == true else { return }
        let stop = StopSignal(), owners = snapshot.owners
        folderStop = stop
        let full = NSHomeDirectory() + path.dropFirst()
        let excluded = fullDiskAccess ? [] : Set(ScanContext.protectedFolders.map { NSHomeDirectory() + "/" + $0 })
        let options = WalkOptions(excluding: excluded, limit: .seconds(30), stop: stop)
        measuredFolders[path] = FolderLevel(listing: true)
        Task {
            guard let names = await offload({ FolderAttribution.names(in: full) }) else {
                if !stop.isStopped { measuredFolders[path] = FolderLevel(unreadable: true) }
                return
            }
            guard !stop.isStopped else { return }
            measuredFolders[path] = FolderLevel(pending: names.sorted())
            for name in names.sorted() {
                let entry = await offload { FolderAttribution.entry(name, in: full, owners: owners, options) }
                // A stopped walk is incomplete: its level was dropped, don't bring it back.
                guard !stop.isStopped else { return }
                measuredFolders[path]?.pending.removeAll { $0 == name }
                if let entry { measuredFolders[path]?.entries.append(entry) }
            }
        }
    }

    /// Levels measured for an earlier scan don't match a new one.
    private func forgetMeasuredFolders() {
        folderStop.stop()
        measuredFolders = [:]
        if snapshot?.folders[folderPath] == nil { folderPath = "~"; selectedFolder = nil }
    }

    /// For the automated screenshot tour: show the welcome screen without data.
    func setSnapshot(_ s: Snapshot?) { snapshot = s }
}

/// One By folder level measured when it was opened.
struct FolderLevel {
    var entries: [FolderEntry] = []
    /// Entries listed but not measured yet.
    var pending: [String] = []
    /// True while the folder itself is being listed.
    var listing = false
    /// True when macOS didn't let the app list the folder.
    var unreadable = false

    var isMeasuring: Bool { listing || !pending.isEmpty }
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
