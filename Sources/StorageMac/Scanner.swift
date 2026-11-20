import Foundation
import StorageCore

/// What every provider gets: a way to run tools and where things are.
public struct ScanContext: Sendable {
    public let shell: Shell
    public let home: String
    public let fullDiskAccess: Bool

    public func expand(_ path: String) -> String { path.replacingOccurrences(of: "~", with: home, options: .anchored) }
    /// The path as shown to the user, with the home folder as `~`.
    public func display(_ path: String) -> String { path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path }

    /// Runs a tool and returns its output when it succeeded.
    func output(_ tool: String, _ args: [String], timeout: Duration = .seconds(60)) async -> String? {
        guard let out = try? await shell.run(tool, args, timeout: timeout), out.succeeded else { return nil }
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

    public func scan(fullDiskAccess: Bool, progress: @Sendable (ScanProgress) -> Void = { _ in }) async -> Snapshot {
        let started = Date()
        let context = ScanContext(shell: Shell(tools: await ToolLocator.discover()), home: NSHomeDirectory(), fullDiskAccess: fullDiskAccess)
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
        if !fullDiskAccess {
            coverage.append(CoverageEntry(area: "Full Disk Access", status: .noAccess,
                                          detail: "Off. Downloads, Documents, Desktop, Mail, Messages and other apps' data were skipped; their space is part of \"Not attributed yet\". Turn it on in System Settings → Privacy & Security → Full Disk Access."))
        }
        let disk = SystemProvider.diskUsage()
        return Snapshot(date: started, scanDuration: Date().timeIntervalSince(started), disk: disk,
                        owners: owners.filter { $0.onDisk > 0 || $0.items.contains { $0.onDisk == .notMeasured } }.sorted { $0.onDisk > $1.onDisk },
                        coverage: coverage.sorted { $0.area < $1.area },
                        folders: FolderAttribution.folders(home: context.home, owners: owners, fullDiskAccess: fullDiskAccess))
    }
}

/// The By folder view: sizes of the home folder and Library, with which owners hold space in each.
enum FolderAttribution {
    static let protected: Set<String> = ["Desktop", "Documents", "Downloads", "Pictures", "Group Containers", "Containers", "Mail", "Messages"]

    static func folders(home: String, owners: [Owner], fullDiskAccess: Bool) -> [String: [FolderEntry]] {
        var result: [String: [FolderEntry]] = [:]
        for (key, path) in [("~", home), ("~/Library", home + "/Library")] {
            result[key] = FileSizes.children(of: path, limit: .seconds(30)).compactMap { name, size in
                guard size.allocated > 0 || protected.contains(name) else { return nil }
                if !fullDiskAccess, protected.contains(name) {
                    return FolderEntry(name: name, bytes: nil, kind: .personalFiles)
                }
                let full = path + "/" + name
                let shares = owners.compactMap { o -> OwnerShare? in
                    let bytes = o.items.filter { ($0.path ?? "").hasPrefix(full) }.compactMap(\.onDisk.bytes).reduce(0, +)
                    return bytes > 0 ? OwnerShare(ownerID: o.id, bytes: bytes) : nil
                }.sorted { $0.bytes > $1.bytes }
                let kind = shares.first.flatMap { s in owners.first { $0.id == s.ownerID }?.kind } ?? .personalFiles
                return FolderEntry(name: name, bytes: size.allocated, kind: kind, isPartial: !size.complete || size.unreadable > 0,
                                   owners: shares, hasChildren: key == "~" && name == "Library")
            }
        }
        return result
    }
}
