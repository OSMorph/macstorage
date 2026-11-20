import Foundation
import StorageCore

/// Docker-compatible engines reached through `docker` contexts (Docker Desktop, OrbStack, colima).
/// Engines that aren't running are left alone: the app never starts one.
public struct DockerProvider: Provider {
    public let area = "Container engines"

    public init() {}

    public func scan(_ ctx: ScanContext) async -> ProviderResult {
        guard let list = await ctx.output("docker", ["context", "ls", "--format", "{{json .}}"]) else {
            return ProviderResult(coverage: [CoverageEntry(area: area, status: .skipped, detail: "docker isn't installed.")])
        }
        var result = ProviderResult()
        var seenEngines = Set<String>()
        for context in Parse.jsonLines(list) {
            guard let name = context["Name"], let endpoint = context["DockerEndpoint"], endpoint.hasPrefix("unix://") else { continue }
            // Two contexts can point at the same engine; count each engine once.
            guard let engineID = await ctx.output("docker", ["--context", name, "info", "--format", "{{.ID}}"], timeout: .seconds(10))?
                .trimmingCharacters(in: .whitespacesAndNewlines), !engineID.isEmpty else {
                result.coverage.append(CoverageEntry(area: "Docker context \(name)", status: .skipped, detail: "Engine not running, left alone."))
                continue
            }
            guard seenEngines.insert(engineID).inserted else { continue }
            if let owner = await engine(ctx, context: name, endpoint: endpoint) {
                result.owners.append(owner)
                result.coverage.append(CoverageEntry(area: owner.name, status: .measured, detail: "Running; measured through the \(name) context."))
            }
        }
        return result
    }

    private func engine(_ ctx: ScanContext, context: String, endpoint: String) async -> Owner? {
        let d = ["--context", context]
        guard let df = await ctx.output("docker", d + ["system", "df", "--format", "{{json .}}"], timeout: .seconds(120)) else { return nil }
        let usage = Dictionary(Parse.dockerSystemDF(df).map { ($0.type, $0) }, uniquingKeysWith: { a, _ in a })

        let images = Parse.jsonLines(await ctx.output("docker", d + ["images", "--all", "--no-trunc", "--format", "{{json .}}"]) ?? "")
        let containers = Parse.jsonLines(await ctx.output("docker", d + ["ps", "--all", "--no-trunc", "--format", "{{json .}}"]) ?? "")
        let usedImages = Set(containers.compactMap { $0["Image"] })
        let unusedImages = images.filter { img in
            let ref = "\(img["Repository"] ?? ""):\(img["Tag"] ?? "")"
            return !usedImages.contains(img["ID"] ?? "") && !usedImages.contains(ref) && !usedImages.contains(img["Repository"] ?? "")
        }
        let stopped = containers.filter { ($0["State"] ?? "") != "running" }
        let volumes = Parse.jsonLines(await ctx.output("docker", d + ["volume", "ls", "--filter", "dangling=true", "--format", "{{json .}}"]) ?? "")
        let cacheIDs = (await ctx.output("docker", d + ["buildx", "du", "--verbose"], timeout: .seconds(120)) ?? "")
            .split(separator: "\n").filter { $0.hasPrefix("ID:") }.map { $0.dropFirst(3).trimmingCharacters(in: .whitespaces) }

        let bytes = { (type: String) in usage[type].map { Measure.bytes($0.size) } ?? .bytes(0) }
        let reclaim = { (type: String) in usage[type].map { Measure.bytes($0.reclaimable) } }
        var facts = [
            Fact(.dockerBuildCache, onDisk: bytes("Build Cache"), reclaimable: reclaim("Build Cache"),
                 targets: cacheIDs.map { Target($0) }, root: context, counts: ["records": cacheIDs.count]),
            Fact(.dockerUnusedImages, onDisk: bytes("Images"), reclaimable: reclaim("Images"),
                 targets: unusedImages.compactMap { img in img["ID"].map { Target($0, bytes: Parse.dockerSize(img["Size"] ?? "")) } },
                 root: context, counts: ["unused": unusedImages.count, "total": images.count]),
            Fact(.dockerStoppedContainers, onDisk: bytes("Containers"),
                 targets: stopped.compactMap { $0["Names"].map { Target($0) } }, root: context, counts: ["stopped": stopped.count, "total": containers.count]),
            Fact(.dockerUnusedVolumes, onDisk: bytes("Local Volumes"),
                 targets: volumes.compactMap { $0["Name"].map { Target($0) } }, root: context, counts: ["unused": volumes.count, "total": usage["Local Volumes"]?.total ?? volumes.count]),
        ]

        // The VM disk on the Mac versus what's inside it.
        let (name, disk): (String, String?) =
            endpoint.contains(".orbstack") ? ("OrbStack", nil)
            : endpoint.contains(".colima") ? ("colima", nil)
            : ("Docker Desktop", ctx.expand("~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"))
        // `root` names the Docker context; the items live with the engine's data, if known.
        for i in facts.indices { facts[i].path = nil }
        var note: String?
        if let disk, FileManager.default.fileExists(atPath: disk) {
            let onMac = FileSizes.measure(disk).allocated
            let logical = ((try? FileManager.default.attributesOfItem(atPath: disk))?[.size] as? NSNumber)?.int64Value ?? 0
            let contents = usage.values.map(\.size).reduce(0, +)
            note = "One VM disk file, Docker.raw: \(ByteFormat.string(logical)) logical, \(ByteFormat.string(onMac)) on disk."
            if onMac > contents { facts.append(Fact(.dockerDiskSlack, onDisk: .bytes(onMac - contents))) }
            for i in facts.indices { facts[i].path = ctx.expand("~/Library/Containers/com.docker.docker") }
        }
        return Owner(id: "docker-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))", name: name, kind: .developerTools,
                     location: disk.map { ctx.display(($0 as NSString).deletingLastPathComponent) } ?? "context \(context)", note: note,
                     items: facts.map(Rules.item))
    }
}
