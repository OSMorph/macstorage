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
            // The engine says what it is; the socket path doesn't (`default` often points at OrbStack).
            guard let info = await ctx.output("docker", ["--context", name, "info", "--format", "{{.ID}}\t{{.OperatingSystem}}"], timeout: .seconds(10))?
                .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t", maxSplits: 1).map(String.init),
                  let engineID = info.first, !engineID.isEmpty else {
                result.coverage.append(CoverageEntry(area: "Docker context \(name)", status: .skipped, detail: "Engine not running, left alone."))
                continue
            }
            guard seenEngines.insert(engineID).inserted else { continue }
            if let owner = await engine(ctx, context: name, engineName: Self.engineName(info.last ?? "", endpoint: endpoint)) {
                result.owners.append(owner)
                result.coverage.append(CoverageEntry(area: owner.name, status: .measured, detail: "Running; measured through the \(name) context."))
            }
        }
        return result
    }

    static func engineName(_ operatingSystem: String, endpoint: String) -> String {
        if operatingSystem.localizedCaseInsensitiveContains("OrbStack") { return "OrbStack" }
        if operatingSystem.localizedCaseInsensitiveContains("Docker Desktop") { return "Docker Desktop" }
        return endpoint.contains(".colima") ? "colima" : operatingSystem.isEmpty ? "Docker engine" : operatingSystem
    }

    /// What `docker image rm` should be given for these unused images: each tag of a tagged
    /// image (removing every tag removes the image) and the ID of an untagged one, once each.
    static func imageRefs(_ images: [[String: String]]) -> [Target] {
        var seen = Set<String>()
        return images.compactMap { img in
            let repo = img["Repository"] ?? "<none>", tag = img["Tag"] ?? "<none>"
            let ref = repo == "<none>" || tag == "<none>" ? img["ID"] ?? "" : "\(repo):\(tag)"
            guard !ref.isEmpty, seen.insert(ref).inserted else { return nil }
            return Target(ref, bytes: Parse.dockerSize(img["Size"] ?? ""))
        }
    }

    private func engine(_ ctx: ScanContext, context: String, engineName: String) async -> Owner? {
        let d = ["--context", context]
        guard let df = await ctx.output("docker", d + ["system", "df", "--format", "{{json .}}"], timeout: .seconds(120)) else { return nil }
        let usage = Dictionary(Parse.dockerSystemDF(df).map { ($0.type, $0) }, uniquingKeysWith: { a, _ in a })

        // Top-level images only: intermediate layers can't be removed on their own.
        let images = Parse.jsonLines(await ctx.output("docker", d + ["images", "--no-trunc", "--format", "{{json .}}"]) ?? "")
        let containers = Parse.jsonLines(await ctx.output("docker", d + ["ps", "--all", "--no-trunc", "--format", "{{json .}}"]) ?? "")
        let usedImages = Set(containers.compactMap { $0["Image"] })
        let unusedImages = images.filter { img in
            let ref = "\(img["Repository"] ?? ""):\(img["Tag"] ?? "")"
            return !usedImages.contains(img["ID"] ?? "") && !usedImages.contains(ref) && !usedImages.contains(img["Repository"] ?? "")
        }
        let stopped = containers.filter { ($0["State"] ?? "") != "running" }
        let volumes = Parse.jsonLines(await ctx.output("docker", d + ["volume", "ls", "--filter", "dangling=true", "--format", "{{json .}}"]) ?? "")
        // The builder named after the context is the engine's own; listing and pruning both use it.
        let cache = Parse.buildxRecords(await ctx.output("docker", d + ["buildx", "du", "--builder", context, "--verbose"], timeout: .seconds(120)) ?? "")
            .filter(\.reclaimable)

        let size = { (type: String) in usage[type].map { Measure.bytes($0.size) } ?? .bytes(0) }
        let imageTargets = Self.imageRefs(unusedImages)
        // Images share layers, so their listed sizes overlap: cap the estimate at what Docker says is reclaimable.
        let uniqueImageBytes = Dictionary(unusedImages.compactMap { i in i["ID"].map { ($0, Parse.dockerSize(i["Size"] ?? "") ?? 0) } }, uniquingKeysWith: { a, _ in a })
        let imageBytes = min(uniqueImageBytes.values.reduce(0, +), usage["Images"]?.reclaimable ?? 0)
        var facts = [
            Fact(.dockerBuildCache, onDisk: size("Build Cache"), reclaimable: .bytes(cache.compactMap(\.bytes).reduce(0, +)),
                 targets: cache.map { Target($0.id, bytes: $0.bytes) }, root: context, counts: ["records": cache.count]),
            Fact(.dockerUnusedImages, onDisk: size("Images"), reclaimable: .bytes(imageBytes), targets: imageTargets,
                 root: context, counts: ["unused": uniqueImageBytes.count, "total": Set(images.compactMap { $0["ID"] }).count]),
            Fact(.dockerStoppedContainers, onDisk: size("Containers"),
                 targets: stopped.compactMap { $0["Names"].map { Target($0) } }, root: context, counts: ["stopped": stopped.count, "total": containers.count]),
            Fact(.dockerUnusedVolumes, onDisk: size("Local Volumes"),
                 targets: volumes.compactMap { $0["Name"].map { Target($0) } }, root: context, counts: ["unused": volumes.count, "total": usage["Local Volumes"]?.total ?? volumes.count]),
        ]

        // On the Mac, the engine occupies its VM disk; the items above are sized inside it.
        let name = engineName
        let disk: String? = engineName == "Docker Desktop" ? ctx.expand("~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw") : nil
        let dataFolder = disk.map { ($0 as NSString).deletingLastPathComponent }
        for i in facts.indices { facts[i].path = dataFolder }
        var note: String? = disk == nil ? "Sized inside the engine's VM; the VM disk file on your Mac isn't measured yet." : nil
        var hostBytes: Int64?
        if let disk, FileManager.default.fileExists(atPath: disk) {
            let onMac = await offload { FileSizes.measure(disk).allocated }
            let logical = ((try? FileManager.default.attributesOfItem(atPath: disk))?[.size] as? NSNumber)?.int64Value ?? 0
            let contents = usage.values.map(\.size).reduce(0, +)
            note = "One VM disk file, Docker.raw: \(ByteFormat.string(logical)) logical, \(ByteFormat.string(onMac)) on disk. Items are sized inside it."
            hostBytes = onMac
            if onMac > contents { facts.append(Fact(.dockerDiskSlack, onDisk: .bytes(onMac - contents), path: dataFolder)) }
        }
        return Owner(id: "docker:\(context)", name: name, kind: .developerTools,
                     location: dataFolder.map(ctx.display) ?? "context \(context)", note: note, hostBytes: hostBytes,
                     items: facts.map(Rules.item))
    }
}
