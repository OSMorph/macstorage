import Foundation
import StorageCore

/// Keeps the latest snapshot and the history (scan summaries and cleanup runs) as JSON in
/// ~/Library/Application Support/macstorage. Nothing leaves the Mac.
public struct HistoryStore: Sendable {
    public let folder: URL

    public init(folder: URL = URL.applicationSupportDirectory.appending(path: "macstorage", directoryHint: .isDirectory)) {
        self.folder = folder
    }

    private var snapshotURL: URL { folder.appending(path: "latest-scan.json") }
    private var historyURL: URL { folder.appending(path: "history.json") }

    public func loadSnapshot() -> Snapshot? { load(snapshotURL) }
    public func loadHistory() -> History { load(historyURL) ?? History() }

    public func save(_ snapshot: Snapshot) throws {
        try write(snapshot, to: snapshotURL)
        var history = loadHistory()
        history.scans.append(ScanSummary(snapshot))
        try write(history, to: historyURL)
    }

    /// Adds or replaces a cleanup run (a run is updated when items are later deleted from the
    /// Trash). The full receipt, with every target, is written as a text file; the history
    /// keeps a compact copy so it stays small however large the target lists were.
    @discardableResult
    public func save(_ run: RunRecord) throws -> URL {
        let receipt = try saveReceipt(run)
        var history = loadHistory()
        history.runs.removeAll { $0.id == run.id }
        history.runs.insert(Self.compacted(run), at: 0)
        try write(history, to: historyURL)
        return receipt
    }

    /// Keeps at most `limit` approved targets per step (the receipt file has them all).
    /// Trash entries are kept in full: they're needed to delete them from the Trash later.
    static func compacted(_ run: RunRecord, limit: Int = 200) -> RunRecord {
        var run = run
        for i in run.steps.indices where run.steps[i].step.approvedTargets.count > limit {
            run.steps[i].step.approvedTargets = Array(run.steps[i].step.approvedTargets.prefix(limit))
        }
        return run
    }

    /// Writes a run's receipt as text and returns where.
    public func saveReceipt(_ run: RunRecord) throws -> URL {
        let url = folder.appending(path: "Receipts", directoryHint: .isDirectory)
            .appending(path: "Cleanup \(run.started.formatted(.iso8601).replacingOccurrences(of: ":", with: ".")).txt")
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
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encoder().encode(value).write(to: url, options: .atomic)
    }
}
