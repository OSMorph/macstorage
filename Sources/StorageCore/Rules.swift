import Foundation

/// What a provider measured about one thing, before any recommendation is applied.
public struct Fact: Sendable {
    public var kind: ItemKind
    /// Distinguishes several facts of the same kind (an app's bundle ID, a cache root).
    public var key: String
    public var name: String?
    public var onDisk: Measure
    public var sharedBytes: Int64?
    /// Defaults to `onDisk` for cleanable kinds.
    public var reclaimable: Measure?
    public var targets: [Target]
    /// What the action acts on, as resolved during the scan: the folder a clear-folder
    /// command clears, or the Docker context a docker command talks to.
    public var root: String?
    /// The folder the item lives in (defaults to `root`).
    public var path: String?
    /// Numbers the explanation quotes ("23 of 44 images").
    public var counts: [String: Int]
    /// False when the target list is known to be incomplete.
    public var targetsComplete = true
    /// For app caches: the app's bundle ID.
    public var appBundleID: String?
    /// What must still hold when the item's command runs.
    public var scopeGuard: ScopeGuard?

    public init(_ kind: ItemKind, key: String = "", name: String? = nil, onDisk: Measure,
                sharedBytes: Int64? = nil, reclaimable: Measure? = nil, targets: [Target] = [],
                root: String? = nil, path: String? = nil, counts: [String: Int] = [:]) {
        self.kind = kind
        self.key = key
        self.name = name
        self.onDisk = onDisk
        self.sharedBytes = sharedBytes
        self.reclaimable = reclaimable
        self.targets = targets
        self.root = root
        self.path = path ?? root
        self.counts = counts
    }

    func count(_ name: String) -> String { (counts[name] ?? 0).formatted() }
}

/// Every kind of thing the app knows how to judge. The rule for each lives in `Rules`.
public enum ItemKind: String, Codable, CaseIterable, Sendable {
    case nixDeadPaths, nixOldGenerations, nixLive
    case dockerBuildCache, dockerUnusedImages, dockerStoppedContainers, dockerUnusedVolumes, dockerDiskSlack, dockerVMDisk
    case podmanUnusedImages, podmanStoppedContainers, podmanUnusedVolumes, podmanVMDisk
    case goModuleCache, goBuildCache
    case cargoRegistry, rustupToolchains, gradleCaches, mavenRepository
    case npmCache, pnpmStore, voltaToolchains
    case uvCache, pipCache, poetryCache, pyenvVersions
    case homebrewOldVersions
    case xcodeDerivedData, xcodeArchives, xcodeDeviceSupport, simulatorsUnavailable
    case gitBuildOutput, gitUnsavedWork, gitRecent
    case appCache, appData, appLogs, systemCache
    case downloads, documents
    case macOSVolume, commandLineTools
}

/// The recommendation table: fact in, item with tier, explanation and action out.
/// Kept as plain data so it can be read and tested in one place.
public enum Rules {
    public static func item(_ f: Fact) -> Item {
        let r = rule(for: f)
        let reclaimable = f.reclaimable ?? (r.tier.isCleanable ? f.onDisk : .bytes(0))
        var action = r.action
        // A folder-clearing command acts on everything in the folder; if the list shown is
        // incomplete, the user can't see the whole scope, so hand it over instead.
        switch action {
        case .clearFolder(let command, _, _) where !f.targetsComplete, .runAfterRecheck(let command, _) where !f.targetsComplete:
            action = .userRunsCommand(command.display(), needsAdmin: false)
        default: break
        }
        return Item(id: f.key.isEmpty ? f.kind.rawValue : "\(f.kind.rawValue):\(f.key)", kind: f.kind,
                    name: f.name ?? r.name, onDisk: f.onDisk, sharedBytes: f.sharedBytes,
                    reclaimable: r.tier == .review ? .unknown : reclaimable,
                    reclaimableIsUpperBound: [.pnpmStore, .dockerUnusedImages, .podmanUnusedImages].contains(f.kind), tier: r.tier,
                    explanation: r.why, basis: f.targetsComplete ? r.basis : (r.basis.map { $0 + " " } ?? "") + "The list is incomplete (the scan stopped early or some folders couldn't be read).",
                    action: action, targets: f.targets, targetUnit: r.unit, targetsComplete: f.targetsComplete,
                    path: f.path, appBundleID: f.appBundleID, scopeGuard: f.scopeGuard)
    }

    struct Rule {
        var name: String
        var tier: Tier
        var why: String
        var basis: String? = nil
        var action: Action = .none
        var unit = "item"
    }

    static let recheck = "Right before running, the app lists the targets again and skips the step if they differ from the list you approved."
    static let rootCheck = "The tool clears the whole folder. Right before running, the app checks that the tool still points at the same folder and that nothing appeared in it since you reviewed the list; otherwise it skips the step."

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func rule(for f: Fact) -> Rule {
        let root = f.root ?? ""
        let docker = { (args: [String]) in Command("docker", (f.root.map { ["--context", $0] } ?? []) + args) }
        let podman = { (args: [String]) in Command("podman", (f.root.map { ["--connection", $0] } ?? []) + args) }
        switch f.kind {
        case .nixDeadPaths:
            return Rule(name: "Dead store paths", tier: .safe,
                        why: "\(f.count("paths")) store paths that no profile or GC root refers to. Nix fetches or rebuilds them if they are ever needed again. The app deletes exactly the approved list, and Nix refuses any path that has become live since.",
                        basis: "Sum of NAR sizes, close to the real disk cost.",
                        action: .runOnTargets(Command("nix-store", ["--delete"]), .mac), unit: "store path")
        case .nixOldGenerations:
            return Rule(name: "Old system generations", tier: .probablySafe,
                        why: "\(f.count("generations")) system generations besides the current one. Removing a generation turns the paths only it used into dead paths for the next garbage collection, and you can't roll back to it any more.",
                        action: .userRunsCommand("sudo nix-env --profile /nix/var/nix/profiles/system --delete-generations +5", needsAdmin: true))
        case .nixLive:
            return Rule(name: "Current system and what it uses", tier: .leaveAlone,
                        why: "Everything the current system and the GC roots depend on.")
        case .dockerBuildCache:
            return Rule(name: "Build cache", tier: .safe,
                        why: "\(f.count("records")) cache records, none used by a running build. The next build of each project is slower while it refills.",
                        basis: "Docker removes unused records as a set, so the app binds it two ways: the until filter means nothing created after you reviewed the list can be removed, and right before running the app lists the unused records again and skips the step if they differ from the list you approved. Records in use are never pruned.",
                        action: .runAfterRecheck(docker(["buildx", "prune", "--builder", root, "--all", "-f", "--filter", "until=\(Command.previewTimeToken)"]), .containerDisk), unit: "cache record")
        case .dockerUnusedImages:
            return Rule(name: "Images no container uses", tier: .probablySafe,
                        why: "\(f.count("unused")) of \(f.count("total")) images have no container. They download or rebuild when needed. The app removes exactly the approved tags (or IDs for untagged images), Docker refuses any image a container has started using since.",
                        basis: "Right before running, the app checks that each tag still points at the image you reviewed and that the context still reaches the same engine, and skips the step if not. Images share layers, so the space freed is at most the figure shown.",
                        // --no-prune: untagged parent images go only if they were approved too.
                        action: .runOnTargets(docker(["image", "rm", "--no-prune"]), .containerDisk), unit: "image")
        case .dockerStoppedContainers:
            return Rule(name: "Stopped containers", tier: .review,
                        why: "\(f.count("stopped")) of \(f.count("total")) containers are stopped. A stopped container can still hold files written inside it, and Docker deletes containers immediately, so the app never removes them for you: check the list and run the command yourself.",
                        action: .userRunsCommand(([docker(["rm"]).display()] + f.targets.map(\.id)).joined(separator: " "), needsAdmin: false), unit: "container")
        case .dockerUnusedVolumes:
            return Rule(name: "Volumes no container uses", tier: .review,
                        why: "\(f.count("unused")) of \(f.count("total")) volumes aren't attached to a container. Volumes often hold databases, and Docker deletes them immediately, so the app never removes them for you: check the list and run the command yourself.",
                        action: .userRunsCommand(([docker(["volume", "rm"]).display()] + f.targets.map(\.id)).joined(separator: " "), needsAdmin: false), unit: "volume")
        case .dockerVMDisk:
            return Rule(name: "VM disk (engine not running)", tier: .leaveAlone,
                        why: "The engine isn't running, so the app can't see what's inside its disk, and it never starts an engine itself. Start it and scan again to see its images, build cache and volumes.")
        case .cargoRegistry:
            return Rule(name: "Cargo registry cache", tier: .safe, why: "Crate sources and archives Cargo downloaded. Cargo downloads them again on the next build that needs them.",
                        action: .moveToTrash, unit: "folder")
        case .rustupToolchains:
            return Rule(name: "Rust toolchains installed by rustup", tier: .probablySafe,
                        why: "Every toolchain rustup has installed. Old ones can go; rustup installs a toolchain again if a project pins it.",
                        action: .userActsInApp("Check them with “rustup toolchain list”, then remove old ones with “rustup toolchain uninstall”."))
        case .gradleCaches:
            return Rule(name: "Gradle caches", tier: .probablySafe,
                        why: "Downloaded dependencies and build caches. Gradle downloads or rebuilds them on the next build. Stop running Gradle daemons first (gradle --stop).",
                        action: .moveToTrash, unit: "folder")
        case .mavenRepository:
            return Rule(name: "Maven local repository", tier: .review,
                        why: "Downloaded dependencies, plus anything installed locally with mvn install, which can't be downloaded again. Only you know which of those you still need.",
                        action: .userActsInApp("Delete folders of artifacts you no longer build against in Finder"))
        case .dockerDiskSlack:
            return Rule(name: "VM system and unclaimed space", tier: .notRemovable,
                        why: "The VM disk holds more than its images, containers, volumes and caches add up to: the VM's own system and logs, and space the engine hasn't handed back to macOS yet. The unclaimed part comes back when the engine trims its disk; the rest is needed to run it.")
        case .podmanUnusedImages:
            return Rule(name: "Images no container uses", tier: .probablySafe,
                        why: "\(f.count("unused")) of \(f.count("total")) images have no container, running or stopped. They download or rebuild when needed. The app removes exactly the approved names (or IDs for untagged images); Podman refuses any image a container has started using since.",
                        basis: "Right before running, the app checks that each name still points at the image you reviewed and that the connection still reaches the same machine, and skips the step if not. Images share layers, so the space freed is at most the figure shown.",
                        action: .runOnTargets(podman(["image", "rm", "--no-prune"]), .containerDisk), unit: "image")
        case .podmanStoppedContainers:
            return Rule(name: "Stopped containers", tier: .review,
                        why: "\(f.count("stopped")) of \(f.count("total")) containers are stopped. A stopped container can still hold files written inside it, and Podman deletes containers immediately, so the app never removes them for you: check the list and run the command yourself.",
                        action: .userRunsCommand(([podman(["rm"]).display()] + f.targets.map(\.id)).joined(separator: " "), needsAdmin: false), unit: "container")
        case .podmanUnusedVolumes:
            return Rule(name: "Volumes no container uses", tier: .review,
                        why: "\(f.count("unused")) of \(f.count("total")) volumes aren't attached to a container. Volumes often hold databases, and Podman deletes them immediately, so the app never removes them for you: check the list and run the command yourself.",
                        action: .userRunsCommand(([podman(["volume", "rm"]).display()] + f.targets.map(\.id)).joined(separator: " "), needsAdmin: false), unit: "volume")
        case .podmanVMDisk:
            return Rule(name: "VM disk (machine not running)", tier: .leaveAlone,
                        why: "The Podman machine isn't running, so the app can't see what's inside its disk, and it never starts a machine itself. Start it and scan again to see its images and volumes.")
        case .goModuleCache:
            return Rule(name: "Module cache", tier: .safe, why: "Downloaded module sources. Go downloads them again on the next build.",
                        basis: rootCheck, action: .clearFolder(Command("go", ["clean", "-modcache"]), root: root, .mac), unit: "module version")
        case .goBuildCache:
            return Rule(name: "Build cache", tier: .safe, why: "Compiled packages. The next build is slower while it refills.",
                        basis: rootCheck, action: .clearFolder(Command("go", ["clean", "-cache"]), root: root, .mac), unit: "cache file")
        case .npmCache:
            return Rule(name: "npm cache", tier: .safe, why: "Downloaded package tarballs. npm downloads them again when needed.",
                        basis: rootCheck, action: .clearFolder(Command("npm", ["cache", "clean", "--force"]), root: root, .mac), unit: "cached package")
        case .pnpmStore:
            return Rule(name: "pnpm store", tier: .safe,
                        why: "pnpm hard-links packages into each project's node_modules, so most of the store is shared with projects. Pruning removes only packages no project uses. pnpm decides which ones when it runs, so the app can't show you the list in advance and leaves this one to you.",
                        action: .userRunsCommand("pnpm store prune", needsAdmin: false))
        case .voltaToolchains:
            return Rule(name: "Node versions installed by volta", tier: .probablySafe,
                        why: "Every Node, npm and yarn version volta has fetched. Old ones can go; volta fetches a version again if a project pins it.",
                        action: .userActsInApp("Check which versions you use with “volta list all”, then remove old ones with volta."))
        case .uvCache:
            return Rule(name: "uv cache", tier: .safe,
                        why: "uv clones packages from its cache into each virtual environment, so most of the folder is shared with your environments and stays on disk. Cleaning frees only the part nothing else uses.",
                        basis: rootCheck, action: .clearFolder(Command("uv", ["cache", "clean"]), root: root, .mac), unit: "cached package")
        case .pipCache:
            return Rule(name: "pip cache", tier: .safe, why: "Downloaded wheels.", basis: rootCheck,
                        action: .clearFolder(Command("pip3", ["cache", "purge"]), root: root, .mac), unit: "cached file")
        case .poetryCache:
            return Rule(name: "Poetry cache", tier: .safe, why: "Downloaded packages and metadata.", action: .moveToTrash, unit: "folder")
        case .pyenvVersions:
            return Rule(name: "Python versions installed by pyenv", tier: .probablySafe, why: "Old Python versions you may no longer use.",
                        action: .userActsInApp("Check which versions you use with “pyenv versions”, then remove old ones with “pyenv uninstall”."))
        case .homebrewOldVersions:
            return Rule(name: "Old versions and downloads", tier: .safe,
                        why: "What a dry run of brew cleanup would remove.", basis: recheck,
                        action: .runAfterRecheck(Command("brew", ["cleanup"]), .mac), unit: "item")
        case .xcodeDerivedData:
            return Rule(name: "DerivedData", tier: .safe, why: "Build products and indexes. Xcode rebuilds them on the next build.",
                        action: .moveToTrash, unit: "project folder")
        case .xcodeArchives:
            return Rule(name: "Archives", tier: .review, why: "App builds you archived, often needed to symbolicate crash reports. Pick the ones you no longer need.",
                        action: .pickToTrash, unit: "archive")
        case .xcodeDeviceSupport:
            return Rule(name: "Device support for older OS versions", tier: .probablySafe,
                        why: "Debug symbols Xcode copied from devices. Xcode copies them again the next time you connect a device on that OS version.",
                        action: .moveToTrash, unit: "OS version")
        case .simulatorsUnavailable:
            return Rule(name: "Unavailable simulators", tier: .safe, why: "Simulators for runtimes that are no longer installed. They can't be used any more.",
                        action: .runOnTargets(Command("xcrun", ["simctl", "delete"]), .mac), unit: "simulator")
        case .gitBuildOutput:
            return Rule(name: "Build output in inactive, clean checkouts", tier: .probablySafe,
                        why: "Build output in \(f.count("checkouts")) checkouts with no changes and no activity for 90 days. npm install or the next build recreates it. Right before moving each folder, the app checks its checkout is still clean and idle.",
                        action: .moveToTrash, unit: "folder")
        case .gitUnsavedWork:
            return Rule(name: "Checkouts with uncommitted or unpushed work", tier: .review,
                        why: "\(f.count("checkouts")) checkouts have changed files, commits that aren't pushed, or no upstream. Deleting them could lose work, so the app only lists them.",
                        action: .userActsInApp("Open each one and commit, push or delete it yourself"), unit: "checkout")
        case .gitRecent:
            return Rule(name: "Clean checkouts in recent use", tier: .leaveAlone, why: "Checkouts you have worked in during the last 90 days.")
        case .appCache:
            return Rule(name: "Cache", tier: .safe, why: "The app refills its cache as you use it. If a running app matches this folder (by bundle ID, name or vendor), the step is skipped so its cache isn't pulled from under it.",
                        action: .moveToTrash, unit: "folder")
        case .systemCache:
            return Rule(name: "Cache of a macOS service", tier: .leaveAlone,
                        why: "macOS services keep these caches and manage their size. They run in the background, so the app can't tell when one is in use, and leaves them alone.")
        case .appData:
            return Rule(name: "App data", tier: .review, why: "Settings, documents or downloaded content the app keeps. Only the app can clean this safely.",
                        action: .userActsInApp("Manage this from inside the app"))
        case .appLogs:
            return Rule(name: "Logs", tier: .safe, why: "Log files apps write. Useful only when troubleshooting.", action: .moveToTrash, unit: "log folder")
        case .downloads:
            return Rule(name: "Downloads folder", tier: .review,
                        why: "Files you downloaded. Nothing here rebuilds itself. Pick the files you don't need and they go to the Trash; nothing is removed in bulk.",
                        basis: "The pick list shows the 50 largest entries not modified for 90 days. Handle anything else in Finder.",
                        action: .pickToTrash, unit: "file")
        case .documents:
            return Rule(name: "Documents", tier: .review, why: "Your files.", action: .userActsInApp("Review them in Finder"))
        case .macOSVolume:
            return Rule(name: "macOS", tier: .leaveAlone, why: "Managed by macOS.")
        case .commandLineTools:
            return Rule(name: "Command Line Tools", tier: .leaveAlone, why: "Apple's compilers and git. Needed by Homebrew, Nix and most developer tools.")
        }
    }
}
