import Foundation
import StorageCore

/// Docker-compatible engines reached through `docker` contexts (Docker Desktop, OrbStack, colima).
/// Podman is measured by `PodmanProvider`, even when a context reaches it.
/// Engines that aren't running are left alone: the app never starts one.
public struct DockerProvider: Provider {
    public let area = "Container engines"

    public init() {}

    public func scan(_ ctx: ScanContext) async -> ProviderResult {
        guard let list = await ctx.output("docker", ["context", "ls", "--format", "{{json .}}"]) else {
            return ProviderResult(coverage: [ctx.unavailable("docker", area: area, what: "Docker")])
        }
        var result = ProviderResult()
        var seenEngines = Set<String>(), seenDisks = Set<String>()
        var stopped: [(name: String, endpoint: String)] = []
        for context in Parse.jsonLines(list) {
            guard let name = context["Name"], let endpoint = context["DockerEndpoint"], endpoint.hasPrefix("unix://") else { continue }
            // Two contexts can point at the same engine; count each engine once.
            // The engine says what it is; the socket path doesn't (`default` often points at OrbStack).
            guard let info = await ctx.output("docker", ["--context", name, "info", "--format", "{{.ID}}\t{{.OperatingSystem}}"], timeout: .seconds(10))?
                .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t", maxSplits: 1).map(String.init),
                  let engineID = info.first, !engineID.isEmpty else {
                stopped.append((name, endpoint))
                continue
            }
            guard seenEngines.insert(engineID).inserted else { continue }
            // Podman answers Docker's API too (through its Docker socket); its machines are
            // measured with podman, so they aren't counted twice.
            // When the version can't be read, a Podman machine's Fedora system gives it away.
            let components = await ctx.output("docker", ["--context", name, "version", "--format", "{{range .Server.Components}}{{.Name}};{{end}}"], timeout: .seconds(10))
            if components?.localizedCaseInsensitiveContains("podman") ?? (info.last ?? "").localizedCaseInsensitiveContains("fedora") {
                result.coverage.append(CoverageEntry(area: "Docker context \(name)", status: .skipped, detail: "Reaches Podman; measured under Podman instead."))
                continue
            }
            let engineName = Self.engineName(info.last ?? "", endpoint: endpoint)
            let disk = Self.vmDisk(engineName, context: name, ctx)
            if let disk { seenDisks.insert(disk) }
            let (owner, coverage) = await engine(ctx, context: name, engineID: engineID, engineName: engineName, disk: disk)
            result.coverage += coverage
            if let owner { result.owners.append(owner) }
        }
        // Engines that aren't running are never started, but their VM disk still takes space.
        for (name, endpoint) in stopped {
            let engineName = Self.engineName("", endpoint: endpoint)
            guard let disk = Self.vmDisk(engineName, context: name, ctx), seenDisks.insert(disk).inserted else {
                result.coverage.append(CoverageEntry(area: "Docker context \(name)", status: .skipped, detail: "Engine not running, left alone."))
                continue
            }
            let onMac = await offload { FileSizes.measure(disk).allocated }
            let folder = (disk as NSString).deletingLastPathComponent
            result.owners.append(Owner(id: "docker:\(name)", name: engineName, kind: .developerTools, location: ctx.display(folder),
                                       note: "Not running. Its VM disk is \(ByteFormat.string(onMac)) on disk; the app never starts an engine to look inside.",
                                       hostBytes: onMac, items: [Rules.item(Fact(.dockerVMDisk, onDisk: .bytes(onMac), path: folder))]))
            result.coverage.append(CoverageEntry(area: "\(engineName) (\(name))", status: .notMeasured, detail: "Engine not running: only its VM disk file was measured."))
        }
        return result
    }

    /// The engine's VM disk file on the Mac, if it can be found (and read without prompting).
    static func vmDisk(_ engineName: String, context: String, _ ctx: ScanContext) -> String? {
        var candidates: [String]
        switch engineName {
        case "Docker Desktop":
            candidates = ["~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"]
        case "OrbStack":
            candidates = ["~/.orbstack/data/data.img"]
            let groups = ctx.expand("~/Library/Group Containers")
            if !ctx.isProtected(groups) {
                candidates += ((try? FileManager.default.contentsOfDirectory(atPath: groups)) ?? [])
                    .filter { $0.hasSuffix(".dev.orbstack") }.map { "~/Library/Group Containers/\($0)/data/data.img" }
            }
        case "colima":
            candidates = ["~/.colima/_lima/_disks/\(context)/datadisk", "~/.colima/_lima/\(context)/diffdisk"]
        default:
            candidates = []
        }
        return candidates.map(ctx.expand).first { !ctx.isProtected($0) && FileManager.default.fileExists(atPath: $0) }
    }

    static func engineName(_ operatingSystem: String, endpoint: String) -> String {
        if operatingSystem.localizedCaseInsensitiveContains("OrbStack") { return "OrbStack" }
        if operatingSystem.localizedCaseInsensitiveContains("Docker Desktop") { return "Docker Desktop" }
        if endpoint.contains(".colima") { return "colima" }
        if endpoint.contains("orbstack") { return "OrbStack" }
        if operatingSystem.isEmpty, endpoint.contains("/.docker/run/") { return "Docker Desktop" }
        return operatingSystem.isEmpty ? "Docker engine" : operatingSystem
    }

    /// What `docker image rm` should be given for these unused images: each tag of a tagged
    /// image (removing every tag removes the image) and the ID of an untagged one, once each.
    /// Each carries the image ID it named at scan time, checked again before removal.
    /// `size` reads the listed size (Docker prints "1.2GB", Podman a byte count).
    static func imageRefs(_ images: [[String: String]], size: (String) -> Int64? = Parse.dockerSize) -> [Target] {
        var seen = Set<String>()
        return images.compactMap { img in
            let repo = img["Repository"] ?? "<none>", tag = img["Tag"] ?? "<none>", id = img["ID"] ?? ""
            let ref = repo == "<none>" || tag == "<none>" ? id : "\(repo):\(tag)"
            guard !ref.isEmpty, !id.isEmpty, seen.insert(ref).inserted else { return nil }
            return Target(ref, bytes: size(img["Size"] ?? ""), fingerprint: id)
        }
    }

    private func engine(_ ctx: ScanContext, context: String, engineID: String, engineName: String, disk: String?) async -> (Owner?, [CoverageEntry]) {
        let d = ["--context", context]
        guard let df = await ctx.output("docker", d + ["system", "df", "--format", "{{json .}}"], timeout: .seconds(120)) else {
            return (nil, [CoverageEntry(area: engineName, status: .failed, detail: "Running, but docker system df failed through the \(context) context.")])
        }
        let usage = Dictionary(Parse.dockerSystemDF(df).map { ($0.type, $0) }, uniquingKeysWith: { a, _ in a })

        // Top-level images only: intermediate layers can't be removed on their own.
        let imageListing = await ctx.output("docker", d + ["images", "--no-trunc", "--format", "{{json .}}"])
        let containerListing = await ctx.output("docker", d + ["ps", "--all", "--no-trunc", "--format", "{{json .}}"])
        let images = Parse.jsonLines(imageListing ?? ""), containers = Parse.jsonLines(containerListing ?? "")
        let usedImages = Set(containers.compactMap { $0["Image"] })
        let unusedImages = images.filter { img in
            let ref = "\(img["Repository"] ?? ""):\(img["Tag"] ?? "")"
            return !usedImages.contains(img["ID"] ?? "") && !usedImages.contains(ref) && !usedImages.contains(img["Repository"] ?? "")
        }
        let stopped = containers.filter { ($0["State"] ?? "") != "running" }
        let volumeListing = await ctx.output("docker", d + ["volume", "ls", "--filter", "dangling=true", "--format", "{{json .}}"])
        let volumes = Parse.jsonLines(volumeListing ?? "")
        // The builder named after the context is the engine's own; listing and pruning both use it.
        let cacheListing = await ctx.output("docker", d + ["buildx", "du", "--builder", context, "--verbose"], timeout: .seconds(120))
        let cache = Parse.buildxRecords(cacheListing ?? "").filter(\.reclaimable)

        let size = { (type: String) in usage[type].map { Measure.bytes($0.size) } ?? .bytes(0) }
        let imageTargets = Self.imageRefs(unusedImages)
        // Images share layers, so their listed sizes overlap: cap the estimate at what Docker says is reclaimable.
        let uniqueImageBytes = Dictionary(unusedImages.compactMap { i in i["ID"].map { ($0, Parse.dockerSize(i["Size"] ?? "") ?? 0) } }, uniquingKeysWith: { a, _ in a })
        let imageBytes = min(uniqueImageBytes.values.reduce(0, +), usage["Images"]?.reclaimable ?? 0)
        // A listing that failed leaves its item out (its size stays in the engine's total)
        // rather than showing an empty list as "nothing to clean".
        var failed: [String] = []
        var facts: [Fact] = []
        if cacheListing != nil {
            facts.append(Fact(.dockerBuildCache, onDisk: size("Build Cache"), reclaimable: .bytes(cache.compactMap(\.bytes).reduce(0, +)),
                              targets: cache.map { Target($0.id, bytes: $0.bytes) }, root: context, counts: ["records": cache.count]))
        } else { failed.append("build cache (docker buildx du)") }
        if imageListing != nil, containerListing != nil {
            facts.append(Fact(.dockerUnusedImages, onDisk: size("Images"), reclaimable: .bytes(imageBytes), targets: imageTargets,
                              root: context, counts: ["unused": uniqueImageBytes.count, "total": Set(images.compactMap { $0["ID"] }).count]))
            facts.append(Fact(.dockerStoppedContainers, onDisk: size("Containers"),
                              targets: stopped.compactMap { $0["Names"].map { Target($0) } }, root: context, counts: ["stopped": stopped.count, "total": containers.count]))
        } else { failed.append("images and containers (docker images, docker ps)") }
        if volumeListing != nil {
            facts.append(Fact(.dockerUnusedVolumes, onDisk: size("Local Volumes"),
                              targets: volumes.compactMap { $0["Name"].map { Target($0) } }, root: context, counts: ["unused": volumes.count, "total": usage["Local Volumes"]?.total ?? volumes.count]))
        } else { failed.append("volumes (docker volume ls)") }

        // Every command is checked against this engine right before it runs.
        for i in facts.indices { facts[i].scopeGuard = .dockerEngine(id: engineID) }

        // On the Mac, the engine occupies its VM disk; the items above are sized inside it.
        let dataFolder = disk.map { ($0 as NSString).deletingLastPathComponent }
        for i in facts.indices { facts[i].path = dataFolder }
        var note = "Sized inside the engine's VM. Its disk file on your Mac wasn't found\(ctx.fullDiskAccess ? "" : " (it may need Full Disk Access)"), so its size on your Mac is unknown and isn't counted in the disk totals."
        var hostBytes: Int64?
        if let disk {
            let onMac = await offload { FileSizes.measure(disk).allocated }
            let logical = ((try? FileManager.default.attributesOfItem(atPath: disk))?[.size] as? NSNumber)?.int64Value ?? 0
            let contents = usage.values.map(\.size).reduce(0, +)
            note = "One VM disk file, \((disk as NSString).lastPathComponent): \(ByteFormat.string(logical)) logical, \(ByteFormat.string(onMac)) on disk. Items are sized inside it."
            hostBytes = onMac
            if onMac > contents { facts.append(Fact(.dockerDiskSlack, onDisk: .bytes(onMac - contents), path: dataFolder)) }
        }
        var coverage = [CoverageEntry(area: engineName, status: .measured, detail: "Running; measured through the \(context) context.")]
        if !failed.isEmpty {
            coverage.append(CoverageEntry(area: "\(engineName) listings", status: .failed,
                                          detail: "Couldn't list \(failed.joined(separator: "; ")), so those items aren't shown" + (disk == nil ? "." : "; their space is still in the VM disk's size.")))
        }
        let owner = Owner(id: "docker:\(context)", name: engineName, kind: .developerTools,
                          location: dataFolder.map(ctx.display) ?? "context \(context)", note: note, hostBytes: hostBytes, hostSizeUnknown: disk == nil,
                          items: facts.map(Rules.item))
        return (owner, coverage)
    }
}
