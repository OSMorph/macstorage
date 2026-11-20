import Foundation
import StorageCore

/// The Nix store: dead paths (exact list, sized by Nix), old system generations, and the rest.
public struct NixProvider: Provider {
    public let area = "Nix"

    public init() {}

    public func scan(_ ctx: ScanContext) async -> ProviderResult {
        guard ctx.exists("/nix/store"), let dead = await ctx.output("nix-store", ["--gc", "--print-dead"], timeout: .seconds(600)) else {
            return ProviderResult(coverage: [CoverageEntry(area: area, status: .skipped, detail: "Nix isn't installed.")])
        }
        let paths = Parse.paths(dead)
        var deadBytes: Int64 = 0
        for batch in stride(from: 0, to: paths.count, by: 1_000).map({ Array(paths[$0..<min($0 + 1_000, paths.count)]) }) {
            deadBytes += Parse.nixSizes(await ctx.output("nix-store", ["-q", "--size"] + batch, timeout: .seconds(120)) ?? "")
        }
        let generations = ((try? FileManager.default.contentsOfDirectory(atPath: "/nix/var/nix/profiles")) ?? [])
            .filter { $0.hasPrefix("system-") && $0.hasSuffix("-link") }.count
        let total = SystemProvider.volumeUsed("/nix") ?? 0
        let facts = [
            Fact(.nixDeadPaths, onDisk: .bytes(deadBytes), targets: paths.map { Target($0) }, path: "/nix/store", counts: ["paths": paths.count]),
            Fact(.nixOldGenerations, onDisk: .notMeasured, reclaimable: .notMeasured, counts: ["generations": max(0, generations - 1)]),
            Fact(.nixLive, onDisk: .bytes(max(0, total - deadBytes))),
        ]
        return ProviderResult(owners: [Owner(id: "nix", name: "Nix store", kind: .developerTools, location: "/nix (its own APFS volume)",
                                             isOwnVolume: true, items: facts.map(Rules.item))],
                              coverage: [CoverageEntry(area: area, status: .measured, detail: "\(plural(paths.count, "dead path")) sized; old generations not measured yet.")])
    }
}

/// Language toolchains' caches: Go, npm, pnpm, volta, uv, pip, Poetry, pyenv.
public struct LanguageCachesProvider: Provider {
    public let area = "Language caches"

    public init() {}

    /// A cache the tool can clear itself, found by asking the tool where it is.
    private func clearable(_ ctx: ScanContext, _ kind: ItemKind, ask tool: String, _ args: [String], fallback: String) async -> Fact? {
        let reported = await ctx.output(tool, args)?.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        let root = reported.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? ctx.expand(fallback)
        guard ctx.exists(root) else { return nil }
        let size = FileSizes.measure(root)
        return Fact(kind, onDisk: .bytes(size.privateBytes), sharedBytes: size.shared > 0 ? size.shared : nil,
                    targets: FileSizes.manifest(root), root: root)
    }

    private func folder(_ ctx: ScanContext, _ kind: ItemKind, _ path: String) -> Fact? {
        let p = ctx.expand(path)
        guard ctx.exists(p) else { return nil }
        let size = FileSizes.measure(p)
        return Fact(kind, onDisk: .bytes(size.privateBytes), targets: [Target(p, bytes: size.privateBytes)], path: p)
    }

    public func scan(_ ctx: ScanContext) async -> ProviderResult {
        async let goMod = clearable(ctx, .goModuleCache, ask: "go", ["env", "GOMODCACHE"], fallback: "~/go/pkg/mod")
        async let goBuild = clearable(ctx, .goBuildCache, ask: "go", ["env", "GOCACHE"], fallback: "~/Library/Caches/go-build")
        async let npm = clearable(ctx, .npmCache, ask: "npm", ["config", "get", "cache"], fallback: "~/.npm")
        async let uv = clearable(ctx, .uvCache, ask: "uv", ["cache", "dir"], fallback: "~/.cache/uv")
        async let pip = clearable(ctx, .pipCache, ask: "pip3", ["cache", "dir"], fallback: "~/Library/Caches/pip")
        let pnpmRoot = await ctx.output("pnpm", ["store", "path"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pnpm = pnpmRoot.flatMap { root -> Fact? in
            guard ctx.exists(root) else { return nil }
            let s = FileSizes.measure(root)
            // Hard links into node_modules folders are counted once, so private bytes bound what a prune can free.
            return Fact(.pnpmStore, onDisk: .bytes(s.allocated), reclaimable: .bytes(s.privateBytes), path: root)
        }

        let go = [await goMod, await goBuild].compactMap { $0 }
        let node = [await npm, pnpm, folder(ctx, .voltaToolchains, "~/.volta")].compactMap { $0 }
        let python = [await uv, await pip, folder(ctx, .poetryCache, "~/Library/Caches/pypoetry"), folder(ctx, .pyenvVersions, "~/.pyenv/versions")].compactMap { $0 }
        let owners = [("go", "Go", go), ("node", "Node.js", node), ("python", "Python", python)].compactMap { id, name, facts -> Owner? in
            facts.isEmpty ? nil : Owner(id: id, name: name, kind: .developerTools,
                                        location: facts.compactMap(\.path).map(ctx.display).joined(separator: ", "), items: facts.map(Rules.item))
        }
        return ProviderResult(owners: owners, coverage: [CoverageEntry(area: area, status: .measured, detail: owners.map(\.name).joined(separator: ", ") + ".")])
    }
}

/// Homebrew: what `brew cleanup` would remove, from its own dry run.
public struct HomebrewProvider: Provider {
    public let area = "Homebrew"

    public init() {}

    public func scan(_ ctx: ScanContext) async -> ProviderResult {
        guard let dryRun = await ctx.output("brew", ["cleanup", "-n"], timeout: .seconds(300)) else {
            return ProviderResult(coverage: [CoverageEntry(area: area, status: .skipped, detail: "Homebrew isn't installed.")])
        }
        let cleanup = Parse.brewCleanup(dryRun)
        let bytes = cleanup.total ?? cleanup.targets.compactMap(\.bytes).reduce(0, +)
        let fact = Fact(.homebrewOldVersions, onDisk: .bytes(bytes), targets: cleanup.targets.map { Target(ctx.display($0.id), bytes: $0.bytes) })
        return ProviderResult(owners: bytes > 0 ? [Owner(id: "homebrew", name: "Homebrew", kind: .developerTools, location: "/opt/homebrew", items: [Rules.item(fact)])] : [],
                              coverage: [CoverageEntry(area: area, status: .measured, detail: "Dry run of brew cleanup.")])
    }
}
