import Foundation
import StorageCore

/// What every provider gets: a way to run tools and where things are.
public struct ScanContext: Sendable {
    public let tools: any ToolRunning
    public let home: String
    public let fullDiskAccess: Bool
    /// Set when the user stops the scan; walks check it, since they run outside Swift tasks.
    public let stop: StopSignal

    public init(tools: any ToolRunning, home: String = NSHomeDirectory(), fullDiskAccess: Bool, stop: StopSignal = StopSignal()) {
        self.tools = tools
        self.home = home
        self.fullDiskAccess = fullDiskAccess
        self.stop = stop
    }

    /// Folders macOS guards without Full Disk Access. Walks never enter them then, so the
    /// scan can't trigger consent prompts or read what coverage says it skipped.
    public static let protectedFolders = ["Desktop", "Documents", "Downloads", "Pictures", "Library/Mail", "Library/Messages",
                                          "Library/Containers", "Library/Group Containers", "Library/Safari",
                                          "Library/Mobile Documents", "Library/Application Support/MobileSync"]

    public var protectedPaths: Set<String> { fullDiskAccess ? [] : Set(Self.protectedFolders.map { home + "/" + $0 }) }

    /// True when `path` is inside a folder the scan must not read without Full Disk Access.
    public func isProtected(_ path: String) -> Bool { protectedPaths.contains { FolderAttribution.isInside(path, $0) } }

    public func walk(limit: Duration = .seconds(120), skipGitCheckouts: Bool = false) -> WalkOptions {
        WalkOptions(excluding: protectedPaths, skipGitCheckouts: skipGitCheckouts, limit: limit, stop: stop)
    }

    /// Coverage for a tool that gave no usable answer: missing, or installed but failing.
    func unavailable(_ tool: String, area: String, what: String) -> CoverageEntry {
        tools.isInstalled(tool)
            ? CoverageEntry(area: area, status: .failed, detail: "\(what) is installed, but \(tool) failed or timed out while listing, so nothing was measured.")
            : CoverageEntry(area: area, status: .skipped, detail: "\(what) isn't installed.")
    }

    public func expand(_ path: String) -> String { path.hasPrefix("~") ? home + path.dropFirst() : path }
    /// The path as shown to the user, with the home folder as `~`.
    public func display(_ path: String) -> String { path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path }

    /// Runs a tool and returns its output only when it exited cleanly with complete output.
    func output(_ tool: String, _ args: [String], timeout: Duration = .seconds(60)) async -> String? {
        guard let out = try? await tools.run(tool, args, timeout: timeout), out.succeeded else { return nil }
        return out.stdout
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: expand(path)) }
}

/// What one provider found.
public struct ProviderResult: Sendable {
    public var owners: [Owner] = []
    public var coverage: [CoverageEntry] = []
}

/// Measures one area (Docker, Nix, language caches…) and turns it into owners.
public protocol Provider: Sendable {
    /// Shown in Scan coverage and the progress text.
    var area: String { get }
    func scan(_ context: ScanContext) async -> ProviderResult
}

/// Progress reported while a scan runs, with what the finished areas found so far.
public struct ScanProgress: Sendable {
    public var finished: [String]
    public var running: [String]
    public var total: Int
    public var started: Date
    public var owners: [Owner]
    public var coverage: [CoverageEntry]

    public init(finished: [String], running: [String], total: Int, started: Date = .now, owners: [Owner] = [], coverage: [CoverageEntry] = []) {
        self.finished = finished
        self.running = running
        self.total = total
        self.started = started
        self.owners = owners
        self.coverage = coverage
    }

    /// What's known so far, as a snapshot marked partial: the unfinished areas are listed
    /// as stopped in its coverage.
    public func partialSnapshot() -> Snapshot {
        Scanner.assemble(started: started, owners: owners,
                         coverage: coverage + running.map { CoverageEntry(area: $0, status: .stopped, detail: "Not finished: the scan was stopped or is still running.") },
                         folders: [:])
    }
}

/// Runs every provider concurrently and assembles one snapshot.
public struct Scanner: Sendable {
    public let providers: [any Provider]

    public init(providers: [any Provider] = Scanner.standardProviders) {
        self.providers = providers
    }

    public static let standardProviders: [any Provider] = [
        SystemProvider(), DockerProvider(), PodmanProvider(), NixProvider(), LanguageCachesProvider(), HomebrewProvider(),
        XcodeProvider(), LibraryProvider(), PersonalFilesProvider(), GitProvider(),
    ]

    /// Runs every provider. `progress` gets what each finished area found, so the first
    /// scan can show results as they arrive; a stopped scan keeps them.
    public func scan(_ context: ScanContext, progress: @Sendable (ScanProgress) -> Void = { _ in }) async -> Snapshot {
        let started = Date()
        var owners: [Owner] = []
        var coverage: [CoverageEntry] = []
        if !context.fullDiskAccess {
            coverage.append(CoverageEntry(area: "Full Disk Access", status: .noAccess,
                                          detail: "Off. Downloads, Documents, Desktop, Mail, Messages and other apps' data were skipped; their space is part of \"Not attributed yet\". Turn it on in System Settings → Privacy & Security → Full Disk Access."))
        }
        var finished: [String] = []
        let areas = providers.map(\.area) + ["Folder sizes"]
        func report() {
            progress(ScanProgress(finished: finished, running: areas.filter { !finished.contains($0) }, total: areas.count,
                                  started: started, owners: owners, coverage: coverage))
        }
        await withTaskGroup(of: (String, ProviderResult, TimeInterval).self) { group in
            for p in providers {
                group.addTask {
                    let t0 = Date()
                    let result = await p.scan(context)
                    return (p.area, result, Date().timeIntervalSince(t0))
                }
            }
            report()
            for await (area, result, seconds) in group {
                owners += result.owners
                coverage += result.coverage.map { var c = $0; c.seconds = c.seconds ?? seconds; return c }
                finished.append(area)
                report()
            }
        }
        let found = owners
        let folders = context.stop.isStopped ? [:] : await offload { FolderAttribution.folders(context, owners: found) }
        if !context.stop.isStopped { finished.append("Folder sizes") }
        let unfinished = areas.filter { !finished.contains($0) }
            .map { CoverageEntry(area: $0, status: .stopped, detail: "Not finished: the scan was stopped.") }
        return Self.assemble(started: started, owners: owners, coverage: coverage + unfinished, folders: folders)
    }

    /// A snapshot from what the providers found.
    static func assemble(started: Date, owners: [Owner], coverage: [CoverageEntry], folders: [String: [FolderEntry]]) -> Snapshot {
        let disk = SystemProvider.diskUsage()
        // Said here, from the measurement the snapshot keeps.
        let data = disk.dataVolumeUsed != nil ? [] : [CoverageEntry(area: "Data volume", status: .failed,
            detail: "macOS didn't report the Data volume's size, so \"Not attributed yet\" includes other volumes.")]
        return Snapshot(date: started, scanDuration: Date().timeIntervalSince(started), disk: disk,
                        // Keep owners with a size, or one that's unknown or a lower bound (even of zero).
                        owners: owners.filter { $0.onDisk > 0 || $0.items.contains { !$0.onDisk.isExact } }.sorted { $0.onDisk > $1.onDisk },
                        coverage: (coverage + data).sorted { $0.area < $1.area }, folders: folders)
    }
}

/// The By folder view: sizes of the entries in a folder, with which owners hold space in
/// each. The scan measures the home folder and Library; the app measures deeper levels
/// when they're opened.
public enum FolderAttribution {
    static func folders(_ ctx: ScanContext, owners: [Owner]) -> [String: [FolderEntry]] {
        let options = ctx.walk(limit: .seconds(30))
        var result: [String: [FolderEntry]] = [:]
        for (key, path) in [("~", ctx.home), ("~/Library", ctx.home + "/Library")] {
            // The same checks as a level opened later: a real folder on the home's volume.
            guard refusal(path, home: ctx.home, protected: []) == nil else { continue }
            result[key] = (names(in: path) ?? []).compactMap { entry($0, in: path, owners: owners, options) }
                .sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        }
        return result
    }

    /// Why a folder can't be opened in By folder.
    public enum Refusal: Sendable {
        case notAFolder, throughLink, otherVolume, needsFullDiskAccess, unreadable
    }

    /// Why `path` (inside `home`) mustn't be read, or nil when it can be: it must be a real
    /// folder reached without following links, on the home folder's volume, and not inside
    /// a folder in `protected`. Checked right before listing; the walks below it never
    /// follow links or leave the volume themselves. On-demand levels repeat it before and
    /// after each entry: a folder replaced by a link mid-level stops there, and an entry
    /// measured while it was replaced, and still replaced afterwards, is discarded. (A link
    /// swapped in and back during one walk isn't caught: file sizes only, read as the same
    /// user who made the link.)
    public static func refusal(_ path: String, home: String, protected: Set<String>) -> Refusal? {
        var st = stat(), homeStat = stat()
        guard lstat(path, &st) == 0 else { return errno == EACCES ? .unreadable : .notAFolder }
        guard st.st_mode & S_IFMT == S_IFDIR else { return .notAFolder }
        guard path == home || path.hasPrefix(home + "/"), let real = FileSizes.realPath(path), let realHome = FileSizes.realPath(home),
              real == realHome + path.dropFirst(home.count) else { return .throughLink }
        guard stat(home, &homeStat) == 0, st.st_dev == homeStat.st_dev else { return .otherVolume }
        return protected.contains { isInside(path, $0) } ? .needsFullDiskAccess : nil
    }

    /// The names directly inside `path`, or nil when it can't be listed.
    public static func names(in path: String) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: path)
    }

    /// One entry of `path`: its size and the owners holding space in it, or nil when it
    /// takes no space. An entry in `options.excluding` (a folder macOS protects without Full
    /// Disk Access) is listed without a size and never opened.
    public static func entry(_ name: String, in path: String, owners: [Owner], _ options: WalkOptions) -> FolderEntry? {
        let full = path + "/" + name
        if options.excluding.contains(full) { return FolderEntry(name: name, bytes: nil, kind: .personalFiles, isFolder: true) }
        var st = stat(), parent = stat()
        guard lstat(full, &st) == 0, lstat(path, &parent) == 0 else { return FolderEntry(name: name, bytes: 0, kind: .personalFiles, isPartial: true) }
        // A volume mounted here isn't part of this disk: left out, never walked.
        guard st.st_dev == parent.st_dev else { return nil }
        let size = FileSizes.measure(full, options)
        // Nothing that takes no space; one that couldn't be read is kept, as a lower bound.
        guard size.allocated > 0 || !size.isComplete else { return nil }
        // The item whose folder most closely holds this entry claims all of it; otherwise
        // the items inside it claim their sizes.
        let holders = owners.flatMap { o in o.items.compactMap { item in
            item.path.flatMap { $0 != full && isInside(full, $0) ? (owner: o.id, path: $0) : nil }
        } }
        let holder = holders.max { $0.path.count < $1.path.count }
        let shares = holder.map { [OwnerShare(ownerID: $0.owner, bytes: size.allocated)] } ?? owners.compactMap { o -> OwnerShare? in
            let bytes = o.items.filter { isInside($0.path, full) }.compactMap(\.onDisk.bytes).reduce(0, +)
            return bytes > 0 ? OwnerShare(ownerID: o.id, bytes: bytes) : nil
        }.sorted { $0.bytes > $1.bytes }
        let kind = shares.first.flatMap { s in owners.first { $0.id == s.ownerID }?.kind } ?? .personalFiles
        return FolderEntry(name: name, bytes: size.allocated, kind: kind, isPartial: !size.isComplete,
                           owners: shares, isFolder: FileSizes.isDirectory(full))
    }

    /// True when `path` is `folder` or inside it, matching whole path components.
    public static func isInside(_ path: String?, _ folder: String) -> Bool {
        guard let path else { return false }
        return path == folder || path.hasPrefix(folder + "/")
    }
}
