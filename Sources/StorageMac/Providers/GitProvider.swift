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
    /// The whole provider stops measuring after this and reports a partial result.
    static let budget: Duration = .seconds(300)

    public init() {}

    struct Checkout {
        var path: String
        var isWorktree: Bool
        var lastActivity: Date
        var hasUnsavedWork: Bool
        var size: FolderSize
        var buildOutput: [(target: Target, size: FolderSize)]
    }

    public func scan(_ ctx: ScanContext) async -> ProviderResult {
        guard ctx.tools.isInstalled("git") else {
            return ProviderResult(coverage: [CoverageEntry(area: area, status: .skipped, detail: "git isn't available (Command Line Tools missing).")])
        }
        let deadline = ContinuousClock.now + Self.budget
        let (found, searchFinished) = await offload { self.find(ctx, until: deadline) }
        var checkouts: [Checkout] = []
        for (path, isWorktree) in found {
            if Task.isCancelled || ctx.stop.isStopped || ContinuousClock.now > deadline { break }
            checkouts.append(await inspect(ctx, path, isWorktree: isWorktree))
        }
        let partial = checkouts.count < found.count || !searchFinished
        let inactive = Date().addingTimeInterval(-Self.inactiveAfter)
        let unsaved = checkouts.filter(\.hasUnsavedWork)
        let idle = checkouts.filter { !$0.hasUnsavedWork && $0.lastActivity < inactive }
        let build = idle.flatMap(\.buildOutput)
        // On disk is allocated; what removing frees is private (clones of other checkouts aren't freed).
        let total = FolderSize.total(checkouts.map(\.size)), unsavedSize = FolderSize.total(unsaved.map(\.size))
        let buildSize = FolderSize.total(build.map(\.size))
        let rest = total.allocated - unsavedSize.allocated - buildSize.allocated
        var buildFact = Fact(.gitBuildOutput, onDisk: buildSize.onDisk, reclaimable: buildSize.reclaimable, targets: build.map(\.target),
                             counts: ["checkouts": idle.filter { !$0.buildOutput.isEmpty }.count])
        buildFact.targetsComplete = buildSize.isComplete
        let facts = [
            buildFact,
            Fact(.gitUnsavedWork, onDisk: unsavedSize.onDisk, targets: unsaved.map { Target($0.path, bytes: $0.size.allocated) }, counts: ["checkouts": unsaved.count]),
            Fact(.gitRecent, onDisk: total.isComplete ? .bytes(max(0, rest)) : .atLeast(max(0, rest))),
        ]
        let worktrees = checkouts.filter(\.isWorktree).count
        let owner = Owner(id: "git", name: "Git checkouts", kind: .developerTools, location: "\(plural(checkouts.count, "checkout")) in your home folder",
                          note: "\(plural(checkouts.count - worktrees, "repo")) and \(plural(worktrees, "worktree")). \(ByteFormat.string(total.shared)) of their space is shared between clones.",
                          items: facts.map(Rules.item))
        let detail = partial ? "\(plural(found.count, "checkout")) found\(searchFinished ? "" : " before the search time limit"); \(checkouts.count) measured."
            : "\(plural(checkouts.count, "checkout")) found."
        return ProviderResult(owners: checkouts.isEmpty ? [] : [owner], coverage: [CoverageEntry(area: area, status: .measured, detail: detail)])
    }

    /// Finds checkouts (a `.git` folder) and worktrees and submodules (a `.git` file) up to
    /// seven levels deep. Each is measured without the checkouts nested in it.
    func find(_ ctx: ScanContext, until deadline: ContinuousClock.Instant) -> (found: [(String, Bool)], finished: Bool) {
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: ctx.home), includingPropertiesForKeys: [.isDirectoryKey]) else { return ([], true) }
        let protected = ctx.protectedPaths
        var found: [(String, Bool)] = []
        while let url = walker.nextObject() as? URL {
            if ctx.stop.isStopped || ContinuousClock.now > deadline { return (found, false) }
            let name = url.lastPathComponent
            if Self.skip.contains(name) || walker.level > 7 || protected.contains(url.path) {
                walker.skipDescendants(); continue
            }
            guard name == ".git" else { continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            found.append((url.deletingLastPathComponent().path, !isDir))
            if isDir { walker.skipDescendants() }
        }
        return (found, true)
    }

    /// When the checkout was last used: its index and HEAD change on every commit, checkout
    /// or staging. A worktree's live git folder is the one its `.git` file points to.
    static func lastActivity(_ path: String, isWorktree: Bool) -> Date {
        var gitDir = path + "/.git"
        if isWorktree, let pointer = try? String(contentsOfFile: gitDir, encoding: .utf8),
           let line = pointer.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
            let dir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDir = dir.hasPrefix("/") ? dir : (path as NSString).appendingPathComponent(dir)
        }
        return ["index", "HEAD", "logs/HEAD"].compactMap {
            (try? FileManager.default.attributesOfItem(atPath: gitDir + "/" + $0))?[.modificationDate] as? Date
        }.max() ?? .distantPast
    }

    /// From `git status --porcelain=v1 --branch`: changed files, unpushed commits or no upstream.
    static func hasUnsavedWork(_ status: String) -> Bool {
        let lines = status.split(separator: "\n")
        let head = lines.first.map(String.init) ?? ""
        return lines.count > 1 || head.contains("ahead") || !head.contains("...")
    }

    /// Why build output in `checkout` may no longer be removed, or nil if it still may:
    /// checked again right before each move.
    public static func ineligibility(_ tools: any ToolRunning, checkout: String) async -> String? {
        guard let out = try? await tools.run("git", ["-C", checkout, "status", "--porcelain=v1", "--branch"], timeout: .seconds(20)),
              out.succeeded else { return "its checkout's status couldn't be read." }
        if hasUnsavedWork(out.stdout) { return "its checkout now has uncommitted or unpushed work." }
        let isWorktree = !FileSizes.isDirectory(checkout + "/.git")
        if lastActivity(checkout, isWorktree: isWorktree) > Date().addingTimeInterval(-inactiveAfter) { return "its checkout was used in the last 90 days." }
        return nil
    }

    func inspect(_ ctx: ScanContext, _ path: String, isWorktree: Bool) async -> Checkout {
        let status = await ctx.output("git", ["-C", path, "status", "--porcelain=v1", "--branch"], timeout: .seconds(20))
        let modified = Self.lastActivity(path, isWorktree: isWorktree)
        // Build output only counts when git ignores it and tracks nothing inside it: a
        // committed dist/ is source.
        var ignored: [String] = []
        for name in Self.buildOutputNames where FileManager.default.fileExists(atPath: path + "/" + name) {
            guard let check = try? await ctx.tools.run("git", ["-C", path, "check-ignore", "-q", name], timeout: .seconds(10)), check.status == 0,
                  let tracked = try? await ctx.tools.run("git", ["-C", path, "ls-files", "--", name], timeout: .seconds(20)),
                  tracked.succeeded, tracked.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            ignored.append(path + "/" + name)
        }
        let short = ctx.walk(limit: .seconds(20)), long = ctx.walk(limit: .seconds(30), skipGitCheckouts: true), outputs = ignored
        let (build, size) = await offload {
            (outputs.map { p in
                let size = FileSizes.measure(p, short)
                return (target: Target(p, bytes: size.privateBytes, identity: FileSizes.identity(p)), size: size)
            },
             FileSizes.measure(path, long))
        }
        return Checkout(path: path, isWorktree: isWorktree, lastActivity: modified,
                        hasUnsavedWork: status.map(Self.hasUnsavedWork) ?? true,   // unreadable status: treat as unsaved
                        size: size, buildOutput: build)
    }
}
