import Foundation

/// Reclaimable space split by where it comes back. The three parts are never added
/// into one "freed" number in the UI, because they mean different things.
public struct Reclaimable: Equatable, Sendable {
    public var byDestination: [Destination: Int64] = [:]
    /// Destinations whose figure is partly an upper bound (unused Docker images share layers).
    public var upperBound: Set<Destination> = []
    /// Destinations whose figure is partly a lower bound (a walk that stopped early).
    public var lowerBound: Set<Destination> = []

    /// True when part of the total is an upper bound.
    public var includesUpperBound: Bool { !upperBound.isEmpty }

    /// "≤ " or "≥ " for a destination whose figure isn't exact, "" otherwise.
    public func boundPrefix(_ d: Destination) -> String {
        guard self[d] > 0 else { return "" }
        return upperBound.contains(d) ? "≤ " : lowerBound.contains(d) ? "≥ " : ""
    }

    public init() {}

    public subscript(_ d: Destination) -> Int64 { byDestination[d, default: 0] }

    /// What comes back on the Mac's own disk (right away or via the Trash). Bars and map
    /// hatching use this: space freed inside a VM disk doesn't shrink the disk file.
    public var onHost: Int64 { Destination.allCases.filter(\.isOnHost).map { self[$0] }.reduce(0, +) }

    mutating func add(_ item: Item) {
        guard let bytes = item.reclaimable.bytes, let d = item.action.destination else { return }
        byDestination[d, default: 0] += bytes
        if item.reclaimableIsUpperBound { upperBound.insert(d) }
        if case .atLeast = item.reclaimable { lowerBound.insert(d) }
    }
}

/// Totals the Overview and the owner tables show, computed one way for every view.
public struct Accounting: Sendable {
    public let snapshot: Snapshot
    /// Items already cleaned since the snapshot was taken: they no longer count as reclaimable.
    public let cleaned: Set<String>

    public init(_ snapshot: Snapshot, cleaned: Set<String> = []) {
        self.snapshot = snapshot
        self.cleaned = cleaned
    }

    /// What the app could clean in a tier, split by destination.
    public func reclaimable(tier: Tier) -> Reclaimable {
        var r = Reclaimable()
        for item in automaticItems where item.tier == tier { r.add(item) }
        return r
    }

    /// Safe items the user has to run themselves (they're not in the app's totals).
    public func userRunItems(tier: Tier) -> [Item] {
        allItems.filter { $0.tier == tier && !$0.action.isAutomatic && !cleaned.contains($0.id) }
    }

    /// Items with an unknown or unmeasured reclaimable size in a tier.
    public func unmeasuredCount(tier: Tier) -> Int {
        allItems.filter { $0.tier == tier && $0.reclaimable.bytes == nil }.count
    }

    /// Your own data, on disk (nothing estimated).
    public var reviewOnDisk: Int64 {
        allItems.filter { $0.tier == .review }.compactMap(\.onDisk.bytes).reduce(0, +)
    }

    /// Reclaimable bytes for one owner, excluding cleaned items.
    public func reclaimable(owner: Owner) -> Reclaimable {
        var r = Reclaimable()
        for item in owner.items where item.tier.isCleanable && !cleaned.contains(item.id) { r.add(item) }
        return r
    }

    /// How an owner's reclaimable column reads: sizes per destination (never added up),
    /// "Unknown", "0 bytes" or "Cleaned today".
    public func reclaimableLabel(owner: Owner) -> ReclaimableLabel {
        let r = reclaimable(owner: owner)
        if r.byDestination.values.contains(where: { $0 > 0 }) { return .bytes(r) }
        if owner.items.contains(where: { cleaned.contains($0.id) }) { return .cleaned }
        let undecided = owner.items.contains { $0.reclaimable == .unknown && $0.tier != .leaveAlone && $0.tier != .notRemovable }
        return undecided ? .unknown : .none
    }

    /// Bytes per kind for the disk bar.
    public var onDiskByKind: [OwnerKind: Int64] {
        snapshot.owners.reduce(into: [:]) { $0[$1.kind, default: 0] += $1.hostOnDisk }
    }

    /// The disk bar: owners by kind, then what no owner accounts for, then free space.
    /// Together they add up to the disk's capacity (unless owners overlap, which the
    /// accounting avoids).
    public var diskSegments: [DiskSegment] {
        let byKind = onDiskByKind
        var segments = OwnerKind.allCases.map { DiskSegment(id: $0.rawValue, label: $0.label, kind: $0, bytes: byKind[$0, default: 0]) }
        segments.append(DiskSegment(id: "unattributed", label: "Not attributed yet", bytes: snapshot.unattributed))
        // Space used outside the Data volume that no owner accounts for: local snapshots,
        // Recovery, other volumes.
        let accounted = segments.map(\.bytes).reduce(0, +)
        segments.append(DiskSegment(id: "other", label: "Snapshots and other volumes", bytes: max(0, snapshot.disk.used - accounted)))
        segments.append(DiskSegment(id: "free", label: "Free", bytes: snapshot.disk.free))
        return segments
    }

    private var allItems: [Item] { snapshot.owners.flatMap(\.items) }
    private var automaticItems: [Item] { allItems.filter { $0.isAutomaticCleanup && !cleaned.contains($0.id) } }
}

public struct DiskSegment: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    /// The owner kind it stands for, or nil for unattributed, other and free space.
    public var kind: OwnerKind?
    public var bytes: Int64

    public init(id: String, label: String, kind: OwnerKind? = nil, bytes: Int64) {
        self.id = id
        self.label = label
        self.kind = kind
        self.bytes = bytes
    }
}

public enum ReclaimableLabel: Equatable, Sendable {
    case bytes(Reclaimable)
    case unknown
    case cleaned
    case none
}
