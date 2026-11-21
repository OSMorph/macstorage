import Foundation
import StorageCore

/// Keeps the latest snapshot, the history and every cleanup run as files in
/// ~/Library/Application Support/macstorage. Nothing leaves the Mac.
///
/// - `history.json`: scan summaries and a compact copy of each run, small enough to load
///   at launch.
/// - `Runs/<id>.json`: each run in full, the authoritative record.
/// - `Receipts/*.txt`: each run's receipt, written from the full record.
///
/// Methods do file I/O synchronously; call them off the main actor.
public struct HistoryStore: Sendable {
    public let folder: URL
    /// Read-modify-write of history.json happens from the run journal and the app at once.
    private static let lock = NSLock()

    public init(folder: URL = URL.applicationSupportDirectory.appending(path: "macstorage", directoryHint: .isDirectory)) {
        self.folder = folder
    }

    private var snapshotURL: URL { folder.appending(path: "latest-scan.json") }
    private var historyURL: URL { folder.appending(path: "history.json") }
    private func runURL(_ id: UUID) -> URL { folder.appending(path: "Runs/\(id.uuidString).json") }

    public func loadSnapshot() -> Snapshot? { load(snapshotURL) }

    public enum StoreError: Error, LocalizedError {
        case unreadableHistoryNotPreserved

        public var errorDescription: String? {
            "history.json can't be read and couldn't be set aside, so the app won't overwrite it"
        }
    }

    /// The history, or an empty one if there is none yet (or it can't be read).
    public func loadHistory() -> History {
        Self.lock.withLock { (try? unlockedHistory()) ?? History() }
    }

    /// A file that exists but can't be read is moved aside under a unique name, never
    /// overwritten, so a format change or damage loses nothing. If it can't be set aside,
    /// this throws, and saving stops rather than replacing it.
    private func unlockedHistory() throws -> History {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return History() }
        if let history: History = load(historyURL) { return history }
        let aside = folder.appending(path: "history-unreadable-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json")
        do {
            try FileManager.default.moveItem(at: historyURL, to: aside)
        } catch {
            throw StoreError.unreadableHistoryNotPreserved
        }
        return History()
    }

    public func save(_ snapshot: Snapshot) throws {
        try write(snapshot, to: snapshotURL)
        try Self.lock.withLock {
            var history = try unlockedHistory()
            history.scans.append(ScanSummary(snapshot))
            try write(history, to: historyURL)
        }
    }

    /// Adds or replaces a cleanup run (a run is updated when its steps finish and when
    /// items are later deleted from the Trash): the full record, then the compact copy in
    /// the history, then the receipt (unless `receipt` is false, as for the journal).
    ///
    /// A compact copy never replaces the full record: only its later Trash deletions are
    /// carried over to it.
    @discardableResult
    public func save(_ run: RunRecord, receipt: Bool = true) throws -> URL? {
        var run = run
        if run.isCompact {
            guard var full = fullRun(run.id) else {
                try saveCompact(run)
                return nil
            }
            full.trashDeletions = run.trashDeletions
            run = full
        }
        var record = run
        for i in record.steps.indices { record.steps[i].step.item.targets = [] }   // the approved list is what matters
        try write(record, to: runURL(run.id))
        try saveCompact(run)
        return receipt ? try writeReceipt(run) : nil
    }

    private func saveCompact(_ run: RunRecord) throws {
        try Self.lock.withLock {
            var history = try unlockedHistory()
            history.runs.removeAll { $0.id == run.id }
            history.runs.append(run.isCompact ? run : Self.compacted(run))
            history.runs.sort { $0.started > $1.started }
            try write(history, to: historyURL)
        }
    }

    /// The run in full, or nil if only the compact copy survives.
    public func fullRun(_ id: UUID) -> RunRecord? { load(runURL(id)) }

    /// The run's receipt file, written from the full record if it doesn't exist yet. An
    /// existing receipt is never replaced by one written from a compact copy.
    public func receipt(_ run: RunRecord) throws -> URL {
        let url = receiptURL(run)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return try writeReceipt(fullRun(run.id) ?? run)
    }

    /// Keeps at most `limit` approved targets and commands per step, and none of the
    /// item's own list (the full record and the receipt have them all). Trash entries are
    /// kept in full: deleting them from the Trash later needs them.
    static func compacted(_ run: RunRecord, limit: Int = 200) -> RunRecord {
        var run = run
        run.isCompact = true
        for i in run.steps.indices {
            run.steps[i].step.item.targets = []
            if run.steps[i].step.approvedTargets.count > limit {
                run.steps[i].step.approvedTargets = Array(run.steps[i].step.approvedTargets.prefix(limit))
            }
            let executed = run.steps[i].executed
            if executed.count > 3 || executed.contains(where: { $0.count > 2_000 }) {
                run.steps[i].executed = executed.prefix(3).map { $0.count > 2_000 ? String($0.prefix(2_000)) + " …" : $0 }
                    + (executed.count > 3 ? ["… and \(plural(executed.count - 3, "more command")) (see the receipt)"] : [])
            }
        }
        return run
    }

    private func receiptURL(_ run: RunRecord) -> URL {
        folder.appending(path: "Receipts", directoryHint: .isDirectory)
            .appending(path: "Cleanup \(run.started.formatted(.iso8601).replacingOccurrences(of: ":", with: ".")) \(run.id.uuidString.prefix(8)).txt")
    }

    private func writeReceipt(_ run: RunRecord) throws -> URL {
        let url = receiptURL(run)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Receipt.text(run).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func load<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder().encode(value).write(to: url, options: .atomic)
    }
}
