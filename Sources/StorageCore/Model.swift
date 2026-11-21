import Foundation

/// How confident the app is that removing something is harmless. Ordered from safest.
public enum Tier: String, Codable, CaseIterable, Comparable, Sendable {
    /// Rebuilds itself automatically (caches, dead store paths).
    case safe
    /// Stale or rebuildable with some effort (old toolchains, unused images).
    case probablySafe
    /// Holds the user's own data. Only ever goes to the Trash, file by file.
    case review
    /// System-owned or in use.
    case leaveAlone
    /// Space that exists but no action can return (for example a VM disk's slack).
    case notRemovable

    public static func < (a: Tier, b: Tier) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    /// Tiers whose items the app may clean up on its own.
    public var isCleanable: Bool { self == .safe || self == .probablySafe }

    public var label: String {
        switch self {
        case .safe: "Safe"
        case .probablySafe: "Probably safe"
        case .review: "Review"
        case .leaveAlone: "Leave alone"
        case .notRemovable: "Not removable"
        }
    }
}

/// The broad kind of an owner, used for grouping and color.
public enum OwnerKind: String, Codable, CaseIterable, Sendable {
    case developerTools, apps, personalFiles, system

    public var label: String {
        switch self {
        case .developerTools: "Developer tools"
        case .apps: "Apps"
        case .personalFiles: "Personal files"
        case .system: "macOS and system"
        }
    }
}

/// Where reclaimed space shows up, so totals never mix different kinds of "freed".
public enum Destination: String, Codable, CaseIterable, Sendable {
    /// Freed on the Mac as soon as the step runs.
    case mac
    /// Moved to the Trash: freed only once the Trash is emptied.
    case trash
    /// Freed inside a container engine's VM disk, which shrinks on its own schedule.
    case containerDisk

    /// Space that comes back on the Mac's own disk (right away or once the Trash is
    /// emptied), unlike space freed inside a container engine's VM disk.
    public var isOnHost: Bool { self != .containerDisk }

    public var label: String {
        switch self {
        case .mac: "Freed on your Mac right away"
        case .trash: "Freed after you empty the Trash"
        case .containerDisk: "Freed inside Docker's disk"
        }
    }
}

/// A size that may not be known. Never collapse these into 0 or a dash in the UI.
public enum Measure: Codable, Equatable, Sendable {
    case bytes(Int64)
    /// A lower bound: the walk stopped early or some folders couldn't be read.
    case atLeast(Int64)
    /// Measuring it is possible but hasn't been done (it's slow, or the user hasn't asked).
    case notMeasured
    /// It can't be known in advance (it depends on what the user decides).
    case unknown

    /// The known bytes, including a lower bound. Use `isExact` before presenting it as exact.
    public var bytes: Int64? {
        switch self {
        case .bytes(let b), .atLeast(let b): b
        case .notMeasured, .unknown: nil
        }
    }

    public var isExact: Bool { if case .bytes = self { true } else { false } }
}

/// A command the app runs itself: an executable and its arguments, never a shell string.
public struct Command: Codable, Equatable, Sendable {
    public var tool: String
    public var arguments: [String]

    public init(_ tool: String, _ arguments: [String]) {
        self.tool = tool
        self.arguments = arguments
    }

    /// Stands in for the moment the user reviewed the preview (Docker's `until` filter).
    public static let previewTimeToken = "{previewTime}"

    /// The arguments to execute, with the preview time filled in.
    public func resolvedArguments(previewTime: Date) -> [String] {
        let stamp = previewTime.formatted(.iso8601)
        return arguments.map { $0.replacingOccurrences(of: Self.previewTimeToken, with: stamp) }
    }

    /// The command as shown to the user. A target list is summarized by its count;
    /// the full list is always shown next to it.
    public func display(targets: Int? = nil, unit: String = "item") -> String {
        var parts = [tool] + arguments.map { $0.replacingOccurrences(of: Self.previewTimeToken, with: "<time of this preview>") }
        if let targets { parts.append("<\(plural(targets, unit)): the list below>") }
        return parts.joined(separator: " ")
    }
}

/// What the app may do about an item. Anything the app runs is bound to a target list
/// the user can inspect; everything else is handed to the user.
public enum Action: Codable, Equatable, Sendable {
    /// Run a tool on exactly these targets (passed as arguments).
    case runOnTargets(Command, Destination)
    /// Run a tool that acts on a set it computes itself, after re-listing the set and
    /// skipping the step if it differs from what the user approved.
    case runAfterRecheck(Command, Destination)
    /// Run a tool that clears one folder, after checking the folder still resolves the same.
    case clearFolder(Command, root: String, Destination)
    /// Move these paths to the Trash.
    case moveToTrash
    /// The user picks individual entries, which then go to the Trash.
    case pickToTrash
    /// The user runs this command in Terminal. Used when the app can't bind the scope,
    /// when deletion is immediate and irreversible, or when it needs admin rights.
    case userRunsCommand(String, needsAdmin: Bool)
    /// Only the owning app can clean this safely.
    case userActsInApp(String)
    case none

    /// Where the space comes back when the app performs this action.
    public var destination: Destination? {
        switch self {
        case .runOnTargets(_, let d), .runAfterRecheck(_, let d), .clearFolder(_, _, let d): d
        case .moveToTrash, .pickToTrash: .trash
        default: nil
        }
    }

    /// True when the app itself can carry this out as part of a cleanup run.
    public var isAutomatic: Bool {
        switch self {
        case .runOnTargets, .runAfterRecheck, .clearFolder, .moveToTrash: true
        default: false
        }
    }
}

/// One entry an action removes: a path, store path, image ID, cache record…
public struct Target: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var bytes: Int64?
    /// For files and folders: what the scan saw, so the app can refuse to act if the
    /// path now points at something else or has changed since.
    public var identity: FileIdentity?
    /// For names that can be re-pointed (a Docker tag): what the name meant at scan time
    /// (the image ID). The app refuses to act if the name now means something else.
    public var fingerprint: String?

    public init(_ id: String, bytes: Int64? = nil, identity: FileIdentity? = nil, fingerprint: String? = nil) {
        self.id = id
        self.bytes = bytes
        self.identity = identity
        self.fingerprint = fingerprint
    }
}

/// What must still hold for an item's command to act on what the user reviewed.
public enum ScopeGuard: Codable, Equatable, Hashable, Sendable {
    /// The folder a clear-folder command empties must still be this directory.
    case folder(FileIdentity)
    /// The Docker context must still reach this engine.
    case dockerEngine(id: String)
}

/// Identifies one filesystem object: the same path holding a different or modified object
/// has a different identity.
public struct FileIdentity: Codable, Equatable, Hashable, Sendable {
    public var device: Int64
    public var inode: UInt64
    public var modified: Double

    public init(device: Int64, inode: UInt64, modified: Double) {
        self.device = device
        self.inode = inode
        self.modified = modified
    }

    /// The same filesystem object, whether or not its contents changed since.
    public func isSameObject(as other: FileIdentity) -> Bool { device == other.device && inode == other.inode }
}

/// Something an owner holds, with its sizes, recommendation and action.
public struct Item: Codable, Identifiable, Equatable, Sendable {
    /// Unique across the snapshot: the owner's ID, then the rule kind and key.
    public var id: String
    public var kind: ItemKind
    public var name: String
    /// Allocated on disk. Hard links count once within one measurement; blocks shared
    /// between APFS clones count in full (`sharedBytes` says how much is shared).
    public var onDisk: Measure
    /// Bytes of `onDisk` shared with other files (APFS clones), so not freed by removing this.
    public var sharedBytes: Int64?
    /// What the user would get back.
    public var reclaimable: Measure
    /// True when `reclaimable` is an upper bound rather than an exact figure.
    public var reclaimableIsUpperBound: Bool
    public var tier: Tier
    /// Why the tier was chosen, in plain language.
    public var explanation: String
    /// How the size or the safety guarantee was established, if worth saying.
    public var basis: String?
    public var action: Action
    /// Exactly what the action removes. Empty when the action has no list.
    public var targets: [Target]
    /// The word for one target in counts ("store path", "image").
    public var targetUnit: String
    /// False when the list is known to be incomplete (time limit, unreadable folders).
    public var targetsComplete: Bool
    /// The folder the item lives in, for Reveal in Finder and folder attribution.
    public var path: String?
    /// For app caches: the app that must not be running while its cache is trashed.
    public var appBundleID: String?
    /// Checked right before the item's command runs.
    public var scopeGuard: ScopeGuard?

    public init(id: String, kind: ItemKind, name: String, onDisk: Measure, sharedBytes: Int64? = nil,
                reclaimable: Measure, reclaimableIsUpperBound: Bool = false, tier: Tier,
                explanation: String, basis: String? = nil, action: Action = .none,
                targets: [Target] = [], targetUnit: String = "item", targetsComplete: Bool = true,
                path: String? = nil, appBundleID: String? = nil, scopeGuard: ScopeGuard? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.onDisk = onDisk
        self.sharedBytes = sharedBytes
        self.reclaimable = reclaimable
        self.reclaimableIsUpperBound = reclaimableIsUpperBound
        self.tier = tier
        self.explanation = explanation
        self.basis = basis
        self.action = action
        self.targets = targets
        self.targetUnit = targetUnit
        self.targetsComplete = targetsComplete
        self.path = path
        self.appBundleID = appBundleID
        self.scopeGuard = scopeGuard
    }

    /// The app may include this item in a cleanup run without the user picking files.
    public var isAutomaticCleanup: Bool { tier.isCleanable && action.isAutomatic }
}

/// Who holds the space: a tool, an app, a project group, a personal folder, macOS itself.
public struct Owner: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: OwnerKind
    /// Where it lives, for display.
    public var location: String
    /// Extra context shown under the owner (for example the VM disk's logical size).
    public var note: String?
    /// True when the owner's space is on another volume than the Data volume (Nix, macOS).
    public var isOwnVolume: Bool
    /// What the owner occupies on the Mac when that differs from the sum of its items:
    /// a container engine's VM disk, whose items are sized inside the VM. When the disk
    /// file can't be found, the sum of the items stands in, as a lower bound.
    public var hostBytes: Int64?
    /// True when the owner occupies a VM disk on the Mac that couldn't be measured, so
    /// the sum of its items stands in.
    public var hostSizeUnknown: Bool?
    public var items: [Item]

    /// Item IDs are namespaced with the owner's ID, so two engines or apps never share one.
    public init(id: String, name: String, kind: OwnerKind, location: String, note: String? = nil,
                isOwnVolume: Bool = false, hostBytes: Int64? = nil, hostSizeUnknown: Bool = false, items: [Item]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.location = location
        self.note = note
        self.isOwnVolume = isOwnVolume
        self.hostBytes = hostBytes
        self.hostSizeUnknown = hostSizeUnknown ? true : nil
        self.items = items.map { item in
            var item = item
            if !item.id.hasPrefix(id + "/") { item.id = id + "/" + item.id }
            return item
        }
    }

    public var onDisk: Int64 { hostBytes ?? items.compactMap(\.onDisk.bytes).reduce(0, +) }

    /// What the owner takes on the Mac's disk, for disk totals: zero when its VM disk
    /// couldn't be measured (the sizes inside a VM say nothing reliable about the disk file).
    public var hostOnDisk: Int64 { hostSizeUnknown == true ? 0 : onDisk }

    /// `onDisk` as shown: unknown when the VM disk couldn't be measured, a lower bound when
    /// an item's size is.
    public var onDiskMeasure: Measure {
        if hostSizeUnknown == true { return .unknown }
        guard hostBytes == nil else { return .bytes(onDisk) }
        let partial = items.contains { if case .atLeast = $0.onDisk { true } else { false } }
        return partial ? .atLeast(onDisk) : .bytes(onDisk)
    }
}
