import Foundation
import StorageCore

/// What every provider gets: a way to run tools and where things are.
public struct ScanContext: Sendable {
    public let tools: any ToolRunning
    public let home: String
    public let fullDiskAccess: Bool

    public init(tools: any ToolRunning, home: String = NSHomeDirectory(), fullDiskAccess: Bool) {
        self.tools = tools
        self.home = home
        self.fullDiskAccess = fullDiskAccess
    }

    /// Folders macOS guards without Full Disk Access. Walks never enter them then, so the
    /// scan can't trigger consent prompts or read what coverage says it skipped.
    public static let protectedFolders = ["Desktop", "Documents", "Downloads", "Pictures", "Library/Mail", "Library/Messages",
                                          "Library/Containers", "Library/Group Containers", "Library/Safari",
                                          "Library/Mobile Documents", "Library/Application Support/MobileSync"]

    public var protectedPaths: Set<String> { fullDiskAccess ? [] : Set(Self.protectedFolders.map { home + "/" + $0 }) }

    public func walk(limit: Duration = .seconds(120), skipGitCheckouts: Bool = false) -> WalkOptions {
        WalkOptions(excluding: protectedPaths, skipGitCheckouts: skipGitCheckouts, limit: limit)
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

/// Progress reported while a scan runs.
public struct ScanProgress: Sendable {
    public var finished: [String]
    public var running: [String]
    public var total: Int

    public init(finished: [String], running: [String], total: Int) {
        self.finished = finished
        self.running = running
        self.total = total
    }
}

/// Runs every provider concurrently and assembles one snapshot.
public struct Scanner: Sendable {
    public let providers: [any Provider]

    public init(providers: [any Provider] = Scanner.standardProviders) {
        self.providers = providers
    }

    public static let standardProviders: [any Provider] = [
        SystemProvider(), DockerProvider(), NixProvider(), LanguageCachesProvider(), HomebrewProvider(),
        XcodeProvider(), LibraryProvider(), PersonalFilesProvider(), GitProvider(),
    ]

    public func scan(_ context: ScanContext, progress: @Sendable (ScanProgress) -> Void = { _ in }) async -> Snapshot {
        let started = Date()
        var owners: [Owner] = []
        var coverage: [CoverageEntry] = []
        var finished: [String] = []
        await withTaskGroup(of: (String, ProviderResult, TimeInterval).self) { group in
            for p in providers {
                group.addTask {
                    let t0 = Date()
                    let result = await p.scan(context)
                    return (p.area, result, Date().timeIntervalSince(t0))
                }
            }
            progress(ScanProgress(finished: [], running: providers.map(\.area), total: providers.count))
            for await (area, result, seconds) in group {
                owners += result.owners
                coverage += result.coverage.map { var c = $0; c.seconds = c.seconds ?? seconds; return c }
                finished.append(area)
                progress(ScanProgress(finished: finished, running: providers.map(\.area).filter { !finished.contains($0) }, total: providers.count))
            }
        }
        if !context.fullDiskAccess {
            coverage.append(CoverageEntry(area: "Full Disk Access", status: .noAccess,
                                          detail: "Off. Downloads, Documents, Desktop, Mail, Messages and other apps' data were skipped; their space is part of \"Not attributed yet\". Turn it on in System Settings → Privacy & Security → Full Disk Access."))
        }
        let found = owners
        let folders = Task.isCancelled ? [:] : await offload { FolderAttribution.folders(context, owners: found) }
        return Snapshot(date: started, scanDuration: Date().timeIntervalSince(started), disk: SystemProvider.diskUsage(),
                        owners: owners.filter { $0.onDisk > 0 || $0.items.contains { $0.onDisk == .notMeasured } }.sorted { $0.onDisk > $1.onDisk },
                        coverage: coverage.sorted { $0.area < $1.area },
                        folders: folders)
    }
}

/// The By folder view: sizes of the home folder and Library, with which owners hold space in each.
enum FolderAttribution {
    static func folders(_ ctx: ScanContext, owners: [Owner]) -> [String: [FolderEntry]] {
        var result: [String: [FolderEntry]] = [:]
        for (key, path) in [("~", ctx.home), ("~/Library", ctx.home + "/Library")] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            result[key] = names.compactMap { name -> FolderEntry? in
                let full = path + "/" + name
                if ctx.protectedPaths.contains(full) { return FolderEntry(name: name, bytes: nil, kind: .personalFiles) }
                let size = FileSizes.measure(full, ctx.walk(limit: .seconds(30)))
                guard size.allocated > 0 else { return nil }
                let shares = owners.compactMap { o -> OwnerShare? in
                    let bytes = o.items.filter { Self.isInside($0.path, full) }.compactMap(\.onDisk.bytes).reduce(0, +)
                    return bytes > 0 ? OwnerShare(ownerID: o.id, bytes: bytes) : nil
                }.sorted { $0.bytes > $1.bytes }
                let kind = shares.first.flatMap { s in owners.first { $0.id == s.ownerID }?.kind } ?? .personalFiles
                return FolderEntry(name: name, bytes: size.allocated, kind: kind, isPartial: !size.isComplete,
                                   owners: shares, hasChildren: key == "~" && name == "Library")
            }.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        }
        return result
    }

    /// True when `path` is `folder` or inside it, matching whole path components.
    static func isInside(_ path: String?, _ folder: String) -> Bool {
        guard let path else { return false }
        return path == folder || path.hasPrefix(folder + "/")
    }
}
