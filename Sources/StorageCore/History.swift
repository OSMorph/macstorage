import Foundation

/// The past scans and cleanups, oldest scan first.
public struct History: Codable, Equatable, Sendable {
    public var scans: [ScanSummary]
    public var runs: [RunRecord]

    public init(scans: [ScanSummary] = [], runs: [RunRecord] = []) {
        self.scans = scans.sorted { $0.date < $1.date }
        self.runs = runs
    }

    /// Growth history exists once there are two scans.
    public var hasComparison: Bool { scans.count >= 2 }

    /// Per-owner change between two scans, largest change first. An explanation is only
    /// attached when the event it describes happened inside the interval.
    public func changes(from: Int, to: Int) -> [OwnerChange] {
        guard from != to, scans.indices.contains(from), scans.indices.contains(to) else { return [] }
        let (a, b) = (min(from, to), max(from, to))
        let ids = Set(scans[a].owners.keys).union(scans[b].owners.keys)
        // An owner unmeasured at either end has no comparable change.
        return ids.compactMap { id in
            guard let end = scans[b].size(id), let start = scans[a].size(id) else { return nil }
            let notes = scans[(a + 1)...b].flatMap { s in s.events.filter { $0.ownerID == id }.map(\.text) }
            return OwnerChange(ownerID: id, name: scans[b].names[id] ?? scans[a].names[id] ?? id, delta: end - start,
                               series: scans.map { $0.size(id) }, notes: notes)
        }
        .filter { $0.delta != 0 }
        .sorted { abs($0.delta) > abs($1.delta) }
    }

    /// Days until the disk is full, from the trend over the most recent scans.
    /// Needs at least four weeks of scans; returns nil otherwise or if usage isn't growing.
    public func forecast(window: Int = 5, minimumSpan: TimeInterval = 28 * 86_400) -> Forecast? {
        let recent = Array(scans.suffix(window))
        guard let first = recent.first, let last = recent.last,
              last.date.timeIntervalSince(first.date) >= minimumSpan else { return nil }
        let days = last.date.timeIntervalSince(first.date) / 86_400
        let perDay = Double(last.used - first.used) / days
        guard perDay > 0 else { return nil }
        return Forecast(daysUntilFull: Double(last.free) / perDay, bytesPerDay: perDay, basedOn: first.date...last.date)
    }
}

/// What History keeps of each scan: totals per owner, not every item.
public struct ScanSummary: Codable, Equatable, Sendable {
    public var date: Date
    public var used: Int64
    public var free: Int64
    /// On-disk bytes by owner ID.
    public var owners: [String: Int64]
    public var names: [String: String]
    /// Things noticed in this scan that explain a change ("2 disk images added").
    public var events: [ScanEvent]
    /// Owners whose size on the Mac couldn't be measured in this scan (a VM disk not found):
    /// a gap in their history, not a zero.
    public var unmeasured: Set<String>? = nil

    /// The owner's size in this scan, or nil when it wasn't measured. An owner that didn't
    /// exist is 0.
    public func size(_ ownerID: String) -> Int64? {
        unmeasured?.contains(ownerID) == true ? nil : owners[ownerID] ?? 0
    }

    public init(date: Date, used: Int64, free: Int64, owners: [String: Int64], names: [String: String], events: [ScanEvent] = []) {
        self.date = date
        self.used = used
        self.free = free
        self.owners = owners
        self.names = names
        self.events = events
    }

    public init(_ snapshot: Snapshot, events: [ScanEvent] = []) {
        self.init(date: snapshot.date, used: snapshot.disk.used, free: snapshot.disk.free,
                  owners: Dictionary(snapshot.owners.filter { $0.hostSizeUnknown != true }.map { ($0.id, $0.hostOnDisk) }, uniquingKeysWith: +),
                  names: Dictionary(snapshot.owners.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }), events: events)
        let unknown = Set(snapshot.owners.filter { $0.hostSizeUnknown == true }.map(\.id))
        unmeasured = unknown.isEmpty ? nil : unknown
    }
}

public struct ScanEvent: Codable, Equatable, Sendable {
    public var ownerID: String
    public var text: String

    public init(ownerID: String, text: String) {
        self.ownerID = ownerID
        self.text = text
    }
}

public struct OwnerChange: Equatable, Identifiable, Sendable {
    public var id: String { ownerID }
    public var ownerID: String
    public var name: String
    public var delta: Int64
    /// The owner's size in each scan; nil where it couldn't be measured.
    public var series: [Int64?]
    public var notes: [String]
}

public struct Forecast: Equatable, Sendable {
    public var daysUntilFull: Double
    public var bytesPerDay: Double
    /// The scans the trend is computed from, so the UI can say so.
    public var basedOn: ClosedRange<Date>
}

/// "1 item", "2 items", "30,496 store paths".
public func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
    "\(n.formatted()) \(n == 1 ? one : many ?? one + "s")"
}

/// Decimal sizes as Finder shows them ("16.7 GB", "240 MB", "0 bytes").
public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let b = Double(abs(bytes))
        let sign = bytes < 0 ? "−" : ""
        switch b {
        case 0: return "0 bytes"
        case ..<1_000: return "\(sign)\(Int(b)) bytes"
        case ..<1_000_000: return "\(sign)\(Int((b / 1_000).rounded())) KB"
        case ..<1_000_000_000: return "\(sign)\(Int((b / 1_000_000).rounded())) MB"
        case ..<100_000_000_000: return sign + String(format: "%.1f GB", b / 1_000_000_000)
        case ..<1_000_000_000_000: return "\(sign)\(Int((b / 1_000_000_000).rounded())) GB"
        default: return sign + String(format: "%.1f TB", b / 1_000_000_000_000)
        }
    }
}

/// A measured value in a series, with the segment it belongs to: a nil value (not
/// measured) ends a segment, so charts don't draw a line across it.
public struct SeriesPoint: Equatable, Sendable {
    public var index: Int
    public var value: Int64
    public var segment: Int
    /// The only measured value in its segment: drawn as a point.
    public var isAlone: Bool
}

public func segmented(_ values: [Int64?]) -> [SeriesPoint] {
    var points: [SeriesPoint] = [], segment = 0
    for (i, v) in values.enumerated() {
        guard let v else { segment += 1; continue }
        points.append(SeriesPoint(index: i, value: v, segment: segment, isAlone: false))
    }
    let sizes = Dictionary(grouping: points, by: \.segment).mapValues(\.count)
    return points.map { var p = $0; p.isAlone = sizes[p.segment] == 1; return p }
}
