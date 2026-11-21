import Foundation

/// What one scan found. Every view reads from a snapshot, so they always agree.
public struct Snapshot: Codable, Equatable, Sendable {
    public var date: Date
    public var scanDuration: TimeInterval
    public var disk: DiskUsage
    public var owners: [Owner]
    public var coverage: [CoverageEntry]
    /// Folder sizes for the By folder view, keyed by path ("~", "~/Library").
    public var folders: [String: [FolderEntry]]

    public init(date: Date, scanDuration: TimeInterval, disk: DiskUsage, owners: [Owner],
                coverage: [CoverageEntry], folders: [String: [FolderEntry]] = [:]) {
        self.date = date
        self.scanDuration = scanDuration
        self.disk = disk
        self.owners = owners
        self.coverage = coverage
        self.folders = folders
    }

    /// Space on the Data volume that no owner accounts for.
    public var unattributed: Int64 {
        let attributed = owners.filter { !$0.isOwnVolume }.map(\.hostOnDisk).reduce(0, +)
        return max(0, disk.dataVolumeUsed - attributed)
    }

    public func owner(_ id: String) -> Owner? { owners.first { $0.id == id } }

    /// True for a scan that was stopped or is still running: some areas weren't measured.
    public var isPartial: Bool { coverage.contains { $0.status == .stopped } }

    /// Areas the scan didn't finish.
    public var unfinishedAreas: [String] { coverage.filter { $0.status == .stopped }.map(\.area) }

    /// The snapshot with sizes that can't be true marked as not measured: an item on the
    /// Mac larger than the disk's used space (version 0.1.0 read each macOS volume's size
    /// as the whole APFS container's), and a Data volume larger than that space.
    /// Sizes inside a VM are left alone: they describe the VM's disk, not the Mac's.
    public func removingImpossibleSizes() -> Snapshot {
        var s = self
        let used = disk.used
        s.disk.dataVolumeUsed = min(disk.dataVolumeUsed, used)
        for o in s.owners.indices where s.owners[o].hostBytes == nil && s.owners[o].hostSizeUnknown != true {
            for i in s.owners[o].items.indices where (s.owners[o].items[i].onDisk.bytes ?? 0) > used {
                s.owners[o].items[i].onDisk = .notMeasured
                if (s.owners[o].items[i].reclaimable.bytes ?? 0) > used { s.owners[o].items[i].reclaimable = .notMeasured }
            }
        }
        return s
    }
}

public struct DiskUsage: Codable, Equatable, Sendable {
    public var total: Int64
    public var free: Int64
    /// Space macOS can free on its own when needed (caches it manages, purgeable snapshots).
    public var purgeable: Int64
    /// Used space on the Data volume (where the user's files and caches live).
    public var dataVolumeUsed: Int64

    public init(total: Int64, free: Int64, purgeable: Int64, dataVolumeUsed: Int64) {
        self.total = total
        self.free = free
        self.purgeable = purgeable
        self.dataVolumeUsed = dataVolumeUsed
    }

    public var used: Int64 { total - free }
}

/// One line of the Scan coverage view: what was measured, skipped or denied, and why.
public struct CoverageEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case measured, skipped, noAccess, notMeasured
        /// The scan was stopped (or is still running) before this area finished.
        case stopped
        /// The tool is installed but its listing failed, so nothing was measured.
        case failed
    }

    public var area: String
    public var status: Status
    public var detail: String
    public var seconds: TimeInterval?

    public var id: String { area }

    public init(area: String, status: Status, detail: String, seconds: TimeInterval? = nil) {
        self.area = area
        self.status = status
        self.detail = detail
        self.seconds = seconds
    }
}

public struct FolderEntry: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    /// nil when the folder couldn't be read (no Full Disk Access) or wasn't scanned.
    public var bytes: Int64?
    public var kind: OwnerKind
    /// True when some folders inside couldn't be read, so `bytes` is a lower bound.
    public var isPartial: Bool
    /// Owners holding space in this folder and how much, largest first.
    public var owners: [OwnerShare]
    public var hasChildren: Bool

    public var id: String { name }

    public init(name: String, bytes: Int64?, kind: OwnerKind, isPartial: Bool = false,
                owners: [OwnerShare] = [], hasChildren: Bool = false) {
        self.name = name
        self.bytes = bytes
        self.kind = kind
        self.isPartial = isPartial
        self.owners = owners
        self.hasChildren = hasChildren
    }
}

public struct OwnerShare: Codable, Equatable, Sendable {
    public var ownerID: String
    public var bytes: Int64

    public init(ownerID: String, bytes: Int64) {
        self.ownerID = ownerID
        self.bytes = bytes
    }
}
