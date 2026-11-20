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
    /// Measuring it is possible but hasn't been done (it's slow, or the user hasn't asked).
    case notMeasured
    /// It can't be known in advance (it depends on what the user decides).
    case unknown

    public var bytes: Int64? {
        if case .bytes(let b) = self { b } else { nil }
    }
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

    public init(_ id: String, bytes: Int64? = nil) {
        self.id = id
        self.bytes = bytes
    }
}

/// Something an owner holds, with its sizes, recommendation and action.
public struct Item: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// On disk, counting blocks shared with other files (APFS clones, hard links) once.
    public var onDisk: Measure
    /// Bytes this item shares with other files, not included in `onDisk`.
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
    /// The folder the item lives in, for Reveal in Finder and folder attribution.
    public var path: String?

    public init(id: String, name: String, onDisk: Measure, sharedBytes: Int64? = nil,
                reclaimable: Measure, reclaimableIsUpperBound: Bool = false, tier: Tier,
                explanation: String, basis: String? = nil, action: Action = .none,
                targets: [Target] = [], targetUnit: String = "item", path: String? = nil) {
        self.id = id
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
        self.path = path
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
    public var items: [Item]

    public init(id: String, name: String, kind: OwnerKind, location: String, note: String? = nil,
                isOwnVolume: Bool = false, items: [Item]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.location = location
        self.note = note
        self.isOwnVolume = isOwnVolume
        self.items = items
    }

    public var onDisk: Int64 { items.compactMap(\.onDisk.bytes).reduce(0, +) }
}
