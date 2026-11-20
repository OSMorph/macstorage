import Foundation
import StorageCore

/// Git checkouts anywhere in the home folder, grouped into build output that can go,
/// checkouts holding unsaved work, and recently used ones.
public struct GitProvider: Provider {
    public let area = "Git checkouts"
    static let skip: Set<String> = ["Library", ".Trash", "node_modules", ".cache", ".npm", ".cargo", ".rustup", ".gradle", ".m2",
                                    ".orbstack", ".colima", ".lima", ".nix-profile", ".local", ".volta", ".bun", "Pictures", "Music",
                                    "Movies", ".venv", "venv", "target", ".build", "DerivedData", "vendor", "Pods", "Applications"]
    static let buildOutputNames = ["node_modules", ".next", "dist", "target", ".build", ".turbo"]
    static let inactiveAfter: TimeInterval = 90 * 86_400

    public init() {}

    struct Checkout {
        var path: String
        var isWorktree: Bool
        var lastActivity: Date
        var hasUnsavedWork: Bool
        var size: FolderSize
        var buildOutput: [Target]
    }

    public func scan(_ ctx: ScanContext) async -> ProviderResult {
        guard ctx.shell.tools.url(for: "git") != nil else {
            return ProviderResult(coverage: [CoverageEntry(area: area, status: .skipped, detail: "git isn't available (Command Line Tools missing).")])
        }
        var checkouts: [Checkout] = []
        for (path, isWorktree) in find(in: ctx.home, fullDiskAccess: ctx.fullDiskAccess) {
            if Task.isCancelled { break }
            checkouts.append(await inspect(ctx, path, isWorktree: isWorktree))
        }
        let inactive = Date().addingTimeInterval(-Self.inactiveAfter)
        let unsaved = checkouts.filter(\.hasUnsavedWork)
        let idle = checkouts.filter { !$0.hasUnsavedWork && $0.lastActivity < inactive }
        let build = idle.flatMap(\.buildOutput)
        let total = checkouts.map(\.size.privateBytes).reduce(0, +)
        let unsavedBytes = unsaved.map(\.size.privateBytes).reduce(0, +)
        let buildBytes = build.compactMap(\.bytes).reduce(0, +)
        let facts = [
            Fact(.gitBuildOutput, onDisk: .bytes(buildBytes), targets: build, counts: ["checkouts": idle.filter { !$0.buildOutput.isEmpty }.count]),
            Fact(.gitUnsavedWork, onDisk: .bytes(unsavedBytes), targets: unsaved.map { Target($0.path, bytes: $0.size.privateBytes) }, counts: ["checkouts": unsaved.count]),
            Fact(.gitRecent, onDisk: .bytes(max(0, total - unsavedBytes - buildBytes))),
        ]
        let allocated = checkouts.map(\.size.allocated).reduce(0, +)
        let worktrees = checkouts.filter(\.isWorktree).count
        let owner = Owner(id: "git", name: "Git checkouts", kind: .developerTools, location: "\(plural(checkouts.count, "checkout")) in your home folder",
                          note: "\(plural(checkouts.count - worktrees, "repo")) and \(plural(worktrees, "worktree")). \(ByteFormat.string(allocated)) if shared blocks were counted per copy.",
                          items: facts.map(Rules.item))
        return ProviderResult(owners: checkouts.isEmpty ? [] : [owner],
                              coverage: [CoverageEntry(area: area, status: .measured, detail: "\(plural(checkouts.count, "checkout")) found.")])
    }

    /// Finds checkouts (a `.git` folder) and worktrees (a `.git` file) up to seven levels deep.
    func find(in home: String, fullDiskAccess: Bool) -> [(String, Bool)] {
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: home), includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        let protected: Set<String> = ["Desktop", "Documents", "Downloads"]
        var found: [(String, Bool)] = []
        while let url = walker.nextObject() as? URL {
            let name = url.lastPathComponent
            if Self.skip.contains(name) || walker.level > 7 || (!fullDiskAccess && walker.level == 1 && protected.contains(name)) {
                walker.skipDescendants(); continue
            }
            guard name == ".git" else { continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            found.append((url.deletingLastPathComponent().path, !isDir))
            if isDir { walker.skipDescendants() }
        }
        return found
    }

    func inspect(_ ctx: ScanContext, _ path: String, isWorktree: Bool) async -> Checkout {
        // "## main...origin/main [ahead 2]" plus one line per changed file.
        let status = await ctx.output("git", ["-C", path, "status", "--porcelain=v1", "--branch"], timeout: .seconds(20)) ?? ""
        let lines = status.split(separator: "\n")
        let head = lines.first.map(String.init) ?? ""
        let unsaved = lines.count > 1 || head.contains("ahead") || !head.contains("...")
        let index = path + (isWorktree ? "/.git" : "/.git/index")
        let modified = (try? FileManager.default.attributesOfItem(atPath: index))?[.modificationDate] as? Date ?? .distantPast
        let build = Self.buildOutputNames.map { path + "/" + $0 }.filter { FileManager.default.fileExists(atPath: $0) }
            .map { Target($0, bytes: FileSizes.measure($0, limit: .seconds(20)).privateBytes) }
        return Checkout(path: path, isWorktree: isWorktree, lastActivity: modified, hasUnsavedWork: unsaved,
                        size: FileSizes.measure(path, limit: .seconds(30)), buildOutput: build)
    }
}
