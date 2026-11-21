import Foundation
import StorageCore

/// The Nix store: dead paths (exact list, sized by Nix), old system generations, and the rest.
public struct NixProvider: Provider {
    public let area = "Nix"

    public init() {}

    public func scan(_ ctx: ScanContext) async -> ProviderResult {
        guard ctx.exists("/nix/store") else {
            return ProviderResult(coverage: [CoverageEntry(area: area, status: .skipped, detail: "Nix isn't installed.")])
        }
        guard let dead = await ctx.output("nix-store", ["--gc", "--print-dead"], timeout: .seconds(600)) else {
            return ProviderResult(coverage: [ctx.unavailable("nix-store", area: area, what: "Nix")])
        }
        let paths = Parse.paths(dead)
        var deadBytes: Int64 = 0, unsized = 0
        for batch in stride(from: 0, to: paths.count, by: 1_000).map({ Array(paths[$0..<min($0 + 1_000, paths.count)]) }) {
            if let sizes = await ctx.output("nix-store", ["-q", "--size"] + batch, timeout: .seconds(120)) {
                deadBytes += Parse.nixSizes(sizes)
            } else {
                unsized += batch.count
            }
        }
        // Paths Nix couldn't size make the dead total a lower bound, and the rest unknown.
        let sized = unsized == 0
        let generations = ((try? FileManager.default.contentsOfDirectory(atPath: "/nix/var/nix/profiles")) ?? [])
            .filter { $0.hasPrefix("system-") && $0.hasSuffix("-link") }.count
        let volume = SystemProvider.volumeUsed("/nix")
        let facts = [
            Fact(.nixDeadPaths, onDisk: sized ? .bytes(deadBytes) : .atLeast(deadBytes), targets: paths.map { Target($0) }, path: "/nix/store", counts: ["paths": paths.count]),
            Fact(.nixOldGenerations, onDisk: .notMeasured, reclaimable: .notMeasured, counts: ["generations": max(0, generations - 1)]),
            Fact(.nixLive, onDisk: sized ? volume.map { .bytes(max(0, $0 - deadBytes)) } ?? .notMeasured : .notMeasured),
        ]
        return ProviderResult(owners: [Owner(id: "nix", name: "Nix store", kind: .developerTools, location: "/nix (its own APFS volume)",
                                             isOwnVolume: true, items: facts.map(Rules.item))],
                              coverage: [CoverageEntry(area: area, status: sized && volume != nil ? .measured : .failed,
                                                       detail: !sized ? "\(plural(paths.count, "dead path")) found, but Nix couldn't size \(unsized) of them, so the dead total is a lower bound."
                                                           : volume == nil ? "\(plural(paths.count, "dead path")) sized; the /nix volume's size couldn't be read, so the rest of the store isn't measured."
                                                           : "\(plural(paths.count, "dead path")) sized; old generations not measured yet.")])
    }
}

/// Language toolchains' caches: Go, npm, pnpm, volta, uv, pip, Poetry, pyenv, Cargo,
/// rustup, Gradle, Maven.
public struct LanguageCachesProvider: Provider {
    public let area = "Language caches"

    public init() {}

    /// A cache the tool can clear itself, found by asking the tool where it is. Only used when
    /// the tool answers: the executor asks it again before clearing.
    /// The part of a tool's cache folder its clean command empties, when not all of it:
    /// `npm cache clean` empties `_cacache` and leaves `_logs` and `_npx`.
    static let clearedSubfolder: [ItemKind: String] = [.npmCache: "_cacache"]

    /// Returns the fact, or a coverage entry when the tool is installed but didn't answer.
    private func clearable(_ ctx: ScanContext, _ kind: ItemKind, ask tool: String, _ args: [String]) async -> (Fact?, CoverageEntry?) {
        guard let answer = await ctx.output(tool, args) else {
            return (nil, ctx.tools.isInstalled(tool) ? ctx.unavailable(tool, area: "\(tool) cache", what: tool) : nil)
        }
        guard let answered = answer.split(separator: "\n").first.map({ String($0).trimmingCharacters(in: .whitespaces) }),
              answered.hasPrefix("/") else {
            return (nil, CoverageEntry(area: "\(tool) cache", status: .failed, detail: "\(tool) didn't report a cache folder, so its cache wasn't measured."))
        }
        let reported = answered + (Self.clearedSubfolder[kind].map { "/" + $0 } ?? "")
        guard let identity = FileSizes.directoryIdentity(reported), !ctx.isProtected(reported) else { return (nil, nil) }
        // Listed through the real path, so a symlinked cache folder shows what's really in it.
        let options = ctx.walk(), real = FileSizes.realPath(reported) ?? reported
        let (targets, size) = await offload { FileSizes.manifest(real, options) }
        var fact = Fact(kind, onDisk: size.onDisk, sharedBytes: size.shared > 0 ? size.shared : nil, reclaimable: size.reclaimable,
                        targets: targets, root: reported)
        fact.targetsComplete = size.isComplete
        fact.scopeGuard = .folder(identity)
        return (fact, nil)
    }

    /// A folder the app moves to the Trash as a whole, or one only the user handles.
    private func folder(_ ctx: ScanContext, _ kind: ItemKind, _ path: String) async -> Fact? {
        let p = ctx.expand(path), options = ctx.walk()
        guard ctx.exists(p), !ctx.isProtected(p) else { return nil }
        let size = await offload { FileSizes.measure(p, options) }
        return Fact(kind, onDisk: size.onDisk, sharedBytes: size.shared > 0 ? size.shared : nil, reclaimable: size.reclaimable,
                    targets: [Target(p, bytes: size.privateBytes, identity: FileSizes.identity(p))], path: p)
    }

    public func scan(_ ctx: ScanContext) async -> ProviderResult {
        async let goMod = clearable(ctx, .goModuleCache, ask: "go", ["env", "GOMODCACHE"])
        async let goBuild = clearable(ctx, .goBuildCache, ask: "go", ["env", "GOCACHE"])
        async let npm = clearable(ctx, .npmCache, ask: "npm", ["config", "get", "cache"])
        async let uv = clearable(ctx, .uvCache, ask: "uv", ["cache", "dir"])
        async let pip = clearable(ctx, .pipCache, ask: "pip3", ["cache", "dir"])
        let pnpmRoot = await ctx.output("pnpm", ["store", "path"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        var pnpm: Fact?
        if let root = pnpmRoot, root.hasPrefix("/"), ctx.exists(root) {
            let options = ctx.walk()
            let s = await offload { FileSizes.measure(root, options) }
            // Hard links into node_modules folders bound what a prune can free from above.
            pnpm = Fact(.pnpmStore, onDisk: s.onDisk, reclaimable: s.reclaimable, path: root)
        }

        let asked = [await goMod, await goBuild, await npm, await uv, await pip]
        var failures = asked.compactMap(\.1)
        if pnpmRoot == nil, ctx.tools.isInstalled("pnpm") { failures.append(ctx.unavailable("pnpm", area: "pnpm store", what: "pnpm")) }
        let go = [asked[0].0, asked[1].0].compactMap { $0 }
        let node = [asked[2].0, pnpm, await folder(ctx, .voltaToolchains, "~/.volta")].compactMap { $0 }
        let python = [asked[3].0, asked[4].0, await folder(ctx, .poetryCache, "~/Library/Caches/pypoetry"), await folder(ctx, .pyenvVersions, "~/.pyenv/versions")].compactMap { $0 }
        let settings = (ctx.tools as? Shell)?.tools.cacheSettings ?? [:]
        let cargo = settings["CARGO_HOME"] ?? "~/.cargo", rustup = settings["RUSTUP_HOME"] ?? "~/.rustup", gradle = settings["GRADLE_USER_HOME"] ?? "~/.gradle"
        let rust = [await folder(ctx, .cargoRegistry, cargo + "/registry"), await folder(ctx, .rustupToolchains, rustup + "/toolchains")].compactMap { $0 }
        let java = [await folder(ctx, .gradleCaches, gradle + "/caches"), await folder(ctx, .mavenRepository, "~/.m2/repository")].compactMap { $0 }
        let owners = [("go", "Go", go), ("node", "Node.js", node), ("python", "Python", python), ("rust", "Rust", rust), ("jvm", "Java (Gradle, Maven)", java)]
            .compactMap { id, name, facts -> Owner? in
            facts.isEmpty ? nil : Owner(id: id, name: name, kind: .developerTools,
                                        location: facts.compactMap(\.path).map(ctx.display).joined(separator: ", "), items: facts.map(Rules.item))
        }
        return ProviderResult(owners: owners, coverage: [CoverageEntry(area: area, status: .measured, detail: owners.map(\.name).joined(separator: ", ") + ".")] + failures)
    }
}

extension LanguageCachesProvider {
    /// A folder-clearing item listed again, for when the tool used its cache after the
    /// preview (a build or install adds files, and the step is then skipped). nil when the
    /// folder is gone or the list is incomplete.
    public static func refreshed(_ item: Item, _ ctx: ScanContext) async -> Item? {
        guard case .clearFolder(_, let root, _) = item.action, !ctx.isProtected(root), let identity = FileSizes.directoryIdentity(root) else { return nil }
        let real = FileSizes.realPath(root) ?? root, options = ctx.walk()
        let (targets, size) = await offload { FileSizes.manifest(real, options) }
        guard size.isComplete else { return nil }
        var fact = Fact(item.kind, onDisk: size.onDisk, sharedBytes: size.shared > 0 ? size.shared : nil, reclaimable: size.reclaimable,
                        targets: targets, root: root)
        fact.scopeGuard = .folder(identity)
        var fresh = Rules.item(fact)
        fresh.id = item.id
        return fresh
    }
}

/// Homebrew: what `brew cleanup` would remove, from its own dry run.
public struct HomebrewProvider: Provider {
    public let area = "Homebrew"

    public init() {}

    public func scan(_ ctx: ScanContext) async -> ProviderResult {
        guard let dryRun = await ctx.output("brew", ["cleanup", "-n"], timeout: .seconds(300)) else {
            return ProviderResult(coverage: [ctx.unavailable("brew", area: area, what: "Homebrew")])
        }
        let cleanup = Parse.brewCleanup(dryRun)
        let bytes = cleanup.total ?? cleanup.targets.compactMap(\.bytes).reduce(0, +)
        var fact = Fact(.homebrewOldVersions, onDisk: .bytes(bytes), targets: cleanup.targets.map { Target(ctx.display($0.id), bytes: $0.bytes) })
        // A dry run that announces more than removals (pruned links…) isn't a complete list.
        fact.targetsComplete = cleanup.unrecognized.isEmpty
        return ProviderResult(owners: bytes > 0 ? [Owner(id: "homebrew", name: "Homebrew", kind: .developerTools, location: "/opt/homebrew", items: [Rules.item(fact)])] : [],
                              coverage: [CoverageEntry(area: area, status: .measured, detail: "Dry run of brew cleanup.")])
    }
}
