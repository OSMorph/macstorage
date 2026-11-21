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
    /// How sizes were measured; nil for a scan saved by version 0.1.0 (see `migrated()`).
    public var format: Int? = Snapshot.currentFormat

    /// Version 2 measures each APFS volume's own used space (0.1.0 read the container's).
    public static let currentFormat = 2
    /// A 0.1.0 scan after `migrated()`: its volume sizes are marked not measured.
    public static let migratedFormat = 1
    /// The coverage area for disk capacity and the macOS volumes.
    public static let volumesArea = "Volumes"
    /// Owners 0.1.0 sized from a whole APFS volume, so with the container's used space.
    public static let legacyVolumeOwners: Set<String> = ["macos", "nix"]

    public init(date: Date, scanDuration: TimeInterval, disk: DiskUsage, owners: [Owner],
                coverage: [CoverageEntry], folders: [String: [FolderEntry]] = [:]) {
        self.date = date
        self.scanDuration = scanDuration
        self.disk = disk
        self.owners = owners
        self.coverage = coverage
        self.folders = folders
    }

    /// Space on the Data volume that no owner accounts for, or nil when the Data volume
    /// wasn't measured.
    public var unattributed: Int64? {
        let attributed = owners.filter { !$0.isOwnVolume }.map(\.hostOnDisk).reduce(0, +)
        return disk.dataVolumeUsed.map { max(0, $0 - attributed) }
    }

    public func owner(_ id: String) -> Owner? { owners.first { $0.id == id } }

    /// True for a scan that was stopped or is still running: some areas weren't measured.
    public var isPartial: Bool { coverage.contains { $0.status == .stopped } }

    /// Areas the scan didn't finish.
    public var unfinishedAreas: [String] { coverage.filter { $0.status == .stopped }.map(\.area) }

    /// A scan saved by version 0.1.0, with what it measured wrongly marked not measured:
    /// the macOS and Nix volumes and the Data volume, all read as the APFS container's used
    /// space. Everything else it measured stands.
    public func migrated() -> Snapshot {
        guard format == nil else { return self }
        var s = self
        s.format = Self.migratedFormat
        s.disk.dataVolumeUsed = nil
        for o in s.owners.indices {
            for i in s.owners[o].items.indices where [.macOSVolume, .nixLive].contains(s.owners[o].items[i].kind) {
                s.owners[o].items[i].onDisk = .notMeasured
            }
        }
        let note = "Saved by version 0.1.0, which misread the macOS, Nix and Data volumes' sizes. Scan again to measure them."
        s.coverage.removeAll { $0.area == Self.volumesArea }
        s.coverage.append(CoverageEntry(area: Self.volumesArea, status: .notMeasured, detail: note))
        for c in s.coverage.indices where s.coverage[c].area == "Nix" && s.coverage[c].status == .measured {
            s.coverage[c].status = .failed
            s.coverage[c].detail = "Saved by version 0.1.0, which misread the /nix volume's size; the dead paths Nix sized itself stand. Scan again to measure the rest."
        }
        s.coverage.sort { $0.area < $1.area }
        return s
    }
}

public struct DiskUsage: Codable, Equatable, Sendable {
    public var total: Int64
    public var free: Int64
    /// Space macOS can free on its own when needed (caches it manages, purgeable snapshots).
    public var purgeable: Int64
    /// Used space on the Data volume (where the user's files and caches live), or nil when
    /// it couldn't be measured.
    public var dataVolumeUsed: Int64?

    public init(total: Int64, free: Int64, purgeable: Int64, dataVolumeUsed: Int64?) {
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
    /// True for a folder, false for a file; nil in scans saved before 0.1.2.
    public var isFolder: Bool?

    public var id: String { name }

    public init(name: String, bytes: Int64?, kind: OwnerKind, isPartial: Bool = false,
                owners: [OwnerShare] = [], isFolder: Bool? = nil) {
        self.name = name
        self.bytes = bytes
        self.kind = kind
        self.isPartial = isPartial
        self.owners = owners
        self.isFolder = isFolder
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
