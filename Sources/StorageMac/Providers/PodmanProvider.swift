import Foundation
import StorageCore

/// Podman machines: each machine's VM disk on the Mac, and inside a running one, images no
/// container uses, stopped containers and unused volumes, through its connections (the
/// rootless one and, when it holds anything, the rootful one). Machines that aren't running
/// are left alone: the app never starts one.
public struct PodmanProvider: Provider {
    public let area = "Podman"

    public init() {}

    public func scan(_ ctx: ScanContext) async -> ProviderResult {
        guard ctx.tools.isInstalled("podman") else {
            return ProviderResult(coverage: [CoverageEntry(area: area, status: .skipped, detail: "Podman isn't installed.")])
        }
        // Podman 5.3+ lists every provider's machines with --all-providers; older versions
        // know one provider and don't accept the flag.
        let allProviders = await ctx.output("podman", ["machine", "list", "--all-providers", "--format", "json"])
        guard let listing = await allProviders.asyncFallback({ await ctx.output("podman", ["machine", "list", "--format", "json"]) }),
              let machines = Parse.jsonArray(listing) else {
            return ProviderResult(coverage: [ctx.unavailable("podman", area: area, what: "Podman")])
        }
        guard !machines.isEmpty else {
            return ProviderResult(coverage: [CoverageEntry(area: area, status: .skipped, detail: "Podman has no machine on this Mac.")])
        }
        let connections = Self.connections(await ctx.output("podman", ["system", "connection", "list", "--format", "json"]) ?? "")
        var result = ProviderResult()
        // `podman machine list` marks the default machine with "*" in some versions.
        let named = machines.compactMap { m in m["Name"].map { (machine: m, name: $0.hasSuffix("*") ? String($0.dropLast()) : $0) } }
        let names = named.map(\.name)
        for (machine, name) in named {
            let vmType = machine["VMType"] ?? ""
            // The same name can exist under two providers (applehv and libkrun).
            let id = names.filter { $0 == name }.count > 1 ? "podman:\(vmType):\(name)" : "podman:\(name)"
            let title = name == "podman-machine-default" ? "Podman" : "Podman (\(name))"
            let disk = Self.vmDisk(name, vmType: vmType, others: names, ctx)
            let onMac = await disk.asyncMap { path in await offload { FileSizes.measure(path).allocated } }
            let location = disk.map { ctx.display(($0 as NSString).deletingLastPathComponent) } ?? "machine \(name)"
            /// Only the disk file, for a machine the app can't look inside.
            func diskOnly(_ why: String, _ coverage: CoverageEntry) {
                guard let disk, let onMac else {
                    return result.coverage.append(CoverageEntry(area: title, status: coverage.status, detail: coverage.detail + " Its disk file wasn't found either."))
                }
                result.owners.append(Owner(id: id, name: title, kind: .developerTools, location: location,
                                           note: "\(why) Its VM disk is \(ByteFormat.string(onMac)) on disk.", hostBytes: onMac,
                                           items: [Rules.item(Fact(.podmanVMDisk, onDisk: .bytes(onMac), path: disk))]))
                result.coverage.append(coverage)
            }
            guard machine["Running"] == "true" else {
                diskOnly("Not running; the app never starts a machine to look inside.",
                         CoverageEntry(area: title, status: .notMeasured, detail: "Machine not running: only its VM disk file was measured."))
                continue
            }
            // The rootless connection is named after the machine; the rootful one adds
            // "-root". Only connections to a machine on this Mac are asked: one with the
            // same name to another host, or a rootful one aliasing the rootless socket, isn't.
            var facts: [Fact] = [], contents: Int64 = 0, problems: [String] = [], asked = Set<String>()
            for (connection, rootful) in [(name, false), (name + "-root", true)] {
                guard let uri = connections[connection].flatMap(Self.localMachineURI), asked.insert(uri).inserted else { continue }
                let found = await engine(ctx, connection: connection, uri: uri, rootful: rootful)
                problems += found.problems
                contents += found.contents
                // The rootful store is usually empty; it's only shown when it holds something.
                if !rootful || found.contents > 0 || found.facts.contains(where: { !$0.targets.isEmpty }) { facts += found.facts }
            }
            guard !facts.isEmpty else {
                let why = asked.isEmpty ? "Podman has no connection to it on this Mac" : "Podman didn't answer through its connection"
                diskOnly(why + ", so the app couldn't look inside.",
                         CoverageEntry(area: title, status: .failed, detail: "Running, but \(why.prefix(1).lowercased() + why.dropFirst()) (\(problems.isEmpty ? "nothing to ask" : problems.joined(separator: "; "))). Only its VM disk file was measured."))
                continue
            }
            // Each machine's items point at its own disk file: machines share their folder.
            for i in facts.indices { facts[i].path = disk }
            var note = "Sized inside the machine. Its disk file on your Mac wasn't found, so its size on your Mac is unknown and isn't counted in the disk totals."
            if let disk, let onMac {
                let logical = ((try? FileManager.default.attributesOfItem(atPath: disk))?[.size] as? NSNumber)?.int64Value ?? 0
                note = "One VM disk file, \((disk as NSString).lastPathComponent): \(ByteFormat.string(logical)) logical, \(ByteFormat.string(onMac)) on disk. Items are sized inside it."
                if onMac > contents { facts.append(Fact(.dockerDiskSlack, onDisk: .bytes(onMac - contents), path: disk)) }
            }
            result.owners.append(Owner(id: id, name: title, kind: .developerTools, location: location, note: note,
                                       hostBytes: onMac, hostSizeUnknown: disk == nil, items: facts.map(Rules.item)))
            result.coverage.append(problems.isEmpty
                ? CoverageEntry(area: title, status: .measured, detail: "Running; measured through the \(name) connection.")
                : CoverageEntry(area: title, status: .failed, detail: "Running, but couldn't list \(problems.joined(separator: "; ")), so those items aren't shown."))
        }
        return result
    }

    /// What one connection holds: its items, their total size, and what couldn't be listed.
    private func engine(_ ctx: ScanContext, connection: String, uri: String, rootful: Bool) async -> (facts: [Fact], contents: Int64, problems: [String]) {
        let c = ["--connection", connection], label = rootful ? " (rootful)" : ""
        guard let df = await ctx.output("podman", c + ["system", "df", "--format", "{{json .}}"], timeout: .seconds(120)) else {
            return ([], 0, ["anything through the \(connection) connection (podman system df)"])
        }
        let usage = Dictionary(Parse.dockerSystemDF(df).map { ($0.type, $0) }, uniquingKeysWith: { a, _ in a })
        let size = { (type: String) in usage[type].map { Measure.bytes($0.size) } ?? .bytes(0) }
        var facts: [Fact] = [], problems: [String] = []

        // Podman counts each image's containers, running or stopped.
        if let listing = await ctx.output("podman", c + ["images", "--format", "{{json .}}"]) {
            let images = Parse.jsonLines(listing)
            let unused = images.filter { $0["Containers"] == "0" }
                .map { ["Repository": $0["repository"] ?? "<none>", "Tag": $0["tag"] ?? "<none>", "ID": $0["Id"] ?? "", "Size": $0["Size"] ?? ""] }
            let unique = Dictionary(unused.compactMap { i in i["ID"].map { ($0, Int64(i["Size"] ?? "") ?? 0) } }, uniquingKeysWith: { a, _ in a })
            let reclaimable = min(unique.values.reduce(0, +), usage["Images"]?.reclaimable ?? 0)
            facts.append(Fact(.podmanUnusedImages, key: connection, name: "Images no container uses" + label, onDisk: size("Images"),
                              reclaimable: .bytes(reclaimable), targets: DockerProvider.imageRefs(unused, size: { Int64($0) }), root: connection,
                              counts: ["unused": unique.count, "total": Set(images.compactMap { $0["Id"] }).count]))
        } else { problems.append("images through \(connection) (podman images)") }
        if let listing = await ctx.output("podman", c + ["ps", "--all", "--format", "{{.Names}}\t{{.State}}\t{{.IsInfra}}"]) {
            let rows = listing.split(whereSeparator: \.isNewline).map { $0.split(separator: "\t").map(String.init) }.filter { $0.count >= 2 }
            // Stopped ones only: not running or paused, and not a pod's infra container
            // (`podman rm` refuses those; the pod owns them).
            let stopped = rows.filter { ["exited", "created", "stopped", "configured"].contains($0[1]) && $0.dropFirst(2).first != "true" }.map { Target($0[0]) }
            facts.append(Fact(.podmanStoppedContainers, key: connection, name: "Stopped containers" + label, onDisk: size("Containers"),
                              targets: stopped, root: connection, counts: ["stopped": stopped.count, "total": rows.count]))
        } else { problems.append("containers through \(connection) (podman ps)") }
        if let listing = await ctx.output("podman", c + ["volume", "ls", "--filter", "dangling=true", "--format", "{{.Name}}"]) {
            let volumes = listing.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { Target($0) }
            facts.append(Fact(.podmanUnusedVolumes, key: connection, name: "Volumes no container uses" + label, onDisk: size("Local Volumes"),
                              targets: volumes, root: connection, counts: ["unused": volumes.count, "total": usage["Local Volumes"]?.total ?? volumes.count]))
        } else { problems.append("volumes through \(connection) (podman volume ls)") }
        // Every command is checked against this connection right before it runs.
        for i in facts.indices { facts[i].scopeGuard = .podmanConnection(uri: uri) }
        return (facts, usage.values.map(\.size).reduce(0, +), problems)
    }

    /// Connections by name, from `podman system connection list --format json`.
    static func connections(_ json: String) -> [String: [String: String]] {
        Dictionary((Parse.jsonArray(json) ?? []).compactMap { c in c["Name"].map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
    }

    /// The connection's address when it reaches a machine on this Mac: over a local socket
    /// or SSH to this Mac itself, and not marked as something other than a machine
    /// (`IsMachine` is left out when false in some versions, so the address decides).
    /// Nil for anything else.
    static func localMachineURI(_ connection: [String: String]) -> String? {
        guard connection["IsMachine"] != "false", let uri = connection["URI"], let url = URL(string: uri) else { return nil }
        let local = url.scheme == "unix" || ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host ?? "")
        return local ? uri : nil
    }

    /// The local machine address a connection points at now, or nil if it's gone, points
    /// elsewhere, or can't be listed.
    static func connectionURI(_ name: String, tools: any ToolRunning) async -> String? {
        guard let out = try? await tools.run("podman", ["system", "connection", "list", "--format", "json"], timeout: .seconds(20)), out.succeeded else { return nil }
        return connections(out.stdout)[name].flatMap(localMachineURI)
    }

    /// The machine's disk file: Podman keeps it in a folder per VM type, named after the
    /// machine ("podman-machine-default-arm64.raw"; older versions "…_fedora-coreos-….qcow2").
    static func vmDisk(_ machine: String, vmType: String, others: [String], _ ctx: ScanContext) -> String? {
        let root = ctx.expand("~/.local/share/containers/podman/machine")
        let types = vmType.isEmpty ? ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []) : [vmType]
        return types.flatMap { type -> [String] in
            let folder = root + "/" + type
            return ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
                .filter { isDisk($0, of: machine, others: others) }.map { folder + "/" + $0 }
        }
        .filter { FileManager.default.fileExists(atPath: $0) }
        .max { FileSizes.measure($0).allocated < FileSizes.measure($1).allocated }
    }

    /// True for a disk image file named after `machine`, and not after another machine
    /// whose name starts with it ("dev" and "dev-2").
    static func isDisk(_ file: String, of machine: String, others: [String] = []) -> Bool {
        let ext = (file as NSString).pathExtension
        guard ["raw", "img", "qcow2"].contains(ext) else { return false }
        let stem = (file as NSString).deletingPathExtension
        let named = { (m: String) in stem == m || stem.hasPrefix(m + "-") || stem.hasPrefix(m + "_") }
        return named(machine) && !others.contains { $0.count > machine.count && named($0) }
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }

    func asyncFallback(_ other: () async -> Wrapped?) async -> Wrapped? {
        if let self { return self }
        return await other()
    }
}
