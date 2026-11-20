import AppKit
import Foundation
import StorageCore

/// macOS itself: the system, Preboot, Recovery and VM volumes, the Command Line Tools,
/// and the disk's capacity.
public struct SystemProvider: Provider {
    public let area = "Volumes"

    public init() {}

    public static func diskUsage() -> DiskUsage {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys)
        let total = Int64(v?.volumeTotalCapacity ?? 0), free = Int64(v?.volumeAvailableCapacity ?? 0)
        let important = v?.volumeAvailableCapacityForImportantUsage ?? free
        return DiskUsage(total: total, free: free, purgeable: max(0, important - free), dataVolumeUsed: volumeUsed("/System/Volumes/Data") ?? 0)
    }

    /// Bytes used on the APFS volume mounted at `path` (its own consumption, not the container's).
    static func volumeUsed(_ path: String) -> Int64? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        return Int64(fs.f_blocks - fs.f_bfree) * Int64(fs.f_bsize)
    }

    public func scan(_ ctx: ScanContext) async -> ProviderResult {
        let volumes = ["/": "System volume", "/System/Volumes/Preboot": "Preboot", "/System/Volumes/VM": "Swap and sleep image", "/System/Volumes/Update": "Staged updates"]
        let facts = volumes.sorted { $0.key < $1.key }.compactMap { path, name in
            Self.volumeUsed(path).map { Fact(.macOSVolume, key: name, name: name, onDisk: .bytes($0)) }
        }
        var owners = [Owner(id: "macos", name: "macOS", kind: .system, location: "System, Preboot, VM and Update volumes", isOwnVolume: true, items: facts.map(Rules.item))]
        let clt = "/Library/Developer/CommandLineTools"
        if ctx.exists(clt) {
            owners.append(Owner(id: "clt", name: "Command Line Tools", kind: .system, location: clt,
                                items: [Rules.item(Fact(.commandLineTools, onDisk: FileSizes.measure(clt, ctx.walk()).onDisk, path: clt))]))
        }
        return ProviderResult(owners: owners, coverage: [CoverageEntry(area: area, status: .measured, detail: "Disk capacity, purgeable space and macOS volumes.")])
    }
}

/// Xcode: DerivedData, Archives, device support and unavailable simulators.
public struct XcodeProvider: Provider {
    public let area = "Xcode"

    public init() {}

    public func scan(_ ctx: ScanContext) async -> ProviderResult {
        let dev = ctx.expand("~/Library/Developer/Xcode")
        guard ctx.exists(dev) else { return ProviderResult(coverage: [CoverageEntry(area: area, status: .skipped, detail: "Xcode hasn't been used on this Mac.")]) }
        func entries(_ sub: String) -> [Target] {
            FileSizes.children(of: dev + "/" + sub, ctx.walk()).map { name, size in
                let path = dev + "/" + sub + "/" + name
                return Target(path, bytes: size.privateBytes, identity: FileSizes.identity(path))
            }
        }
        func fact(_ kind: ItemKind, _ targets: [Target], _ sub: String) -> Fact? {
            targets.isEmpty ? nil : Fact(kind, onDisk: .bytes(targets.compactMap(\.bytes).reduce(0, +)), targets: targets, path: dev + "/" + sub)
        }
        // Keep device support for the newest OS version of each platform; older ones are stale.
        let support = ["iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport"].flatMap { sub in
            entries(sub).sorted { $0.id.localizedStandardCompare($1.id) == .orderedDescending }.dropFirst()
        }
        var facts = [fact(.xcodeDerivedData, entries("DerivedData"), "DerivedData"), fact(.xcodeArchives, entries("Archives"), "Archives"),
                     fact(.xcodeDeviceSupport, Array(support), "")].compactMap { $0 }
        if let json = await ctx.output("xcrun", ["simctl", "list", "devices", "unavailable", "-j"]),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(SimctlDevices.self, from: data) {
            let udids = decoded.devices.values.flatMap { $0 }.map(\.udid)
            if !udids.isEmpty {
                let root = ctx.expand("~/Library/Developer/CoreSimulator/Devices")
                let targets = udids.map { Target($0, bytes: FileSizes.measure(root + "/" + $0, ctx.walk()).privateBytes) }
                facts.append(Fact(.simulatorsUnavailable, onDisk: .bytes(targets.compactMap(\.bytes).reduce(0, +)), targets: targets, path: root))
            }
        }
        return ProviderResult(owners: facts.isEmpty ? [] : [Owner(id: "xcode", name: "Xcode", kind: .developerTools, location: ctx.display(dev), items: facts.map(Rules.item))],
                              coverage: [CoverageEntry(area: area, status: .measured, detail: "DerivedData, Archives, device support and simulators.")])
    }

    struct SimctlDevices: Decodable {
        struct Device: Decodable { let udid: String }
        let devices: [String: [Device]]
    }
}

/// Apps' caches and data in ~/Library, grouped by app, plus logs.
public struct LibraryProvider: Provider {
    public let area = "Apps"
    /// Smaller folders aren't worth an owner of their own.
    static let threshold: Int64 = 300_000_000

    public init() {}

    public func scan(_ ctx: ScanContext) async -> ProviderResult {
        var byApp: [String: [Fact]] = [:]
        func collect(_ folder: String, _ kind: ItemKind) {
            let root = ctx.expand(folder)
            guard !ctx.protectedPaths.contains(root) else { return }
            for (name, size) in FileSizes.children(of: root, ctx.walk()) where size.allocated >= Self.threshold {
                let path = root + "/" + name, key = Self.appKey(name)
                var fact = Fact(kind, key: "\((folder as NSString).lastPathComponent)/\(name)", onDisk: size.onDisk,
                                sharedBytes: size.shared > 0 ? size.shared : nil, reclaimable: size.reclaimable,
                                targets: kind == .appCache ? [Target(path, bytes: size.privateBytes, identity: FileSizes.identity(path))] : [], path: path)
                fact.appBundleID = key.contains(".") ? key : nil
                byApp[key, default: []].append(fact)
            }
        }
        collect("~/Library/Caches", .appCache)
        collect("~/Library/Application Support", .appData)
        collect("~/Library/Containers", .appData)
        collect("~/Library/Group Containers", .appData)
        // Developer tools have their own providers.
        let toolKeys: Set<String> = ["go-build", "pip", "pypoetry", "Homebrew", "com.docker.docker", "group.com.docker", "pnpm", "uv"]
        let owners = byApp.filter { !toolKeys.contains($0.key) }.map { key, facts in
            Owner(id: "app:" + key, name: Self.appName(key), kind: .apps, location: facts.compactMap(\.path).map(ctx.display).joined(separator: ", "), items: facts.map(Rules.item))
        }
        let logs = ctx.expand("~/Library/Logs")
        let (logTargets, logSize) = FileSizes.manifest(logs, ctx.walk())
        var logFact = Fact(.appLogs, onDisk: logSize.onDisk, reclaimable: logSize.reclaimable, targets: logTargets, path: logs)
        logFact.targetsComplete = logSize.isComplete
        let logBytes = logSize.allocated
        let logOwner = Owner(id: "logs", name: "Logs", kind: .system, location: "~/Library/Logs", items: [Rules.item(logFact)])
        return ProviderResult(owners: owners + (logBytes > 0 ? [logOwner] : []),
                              coverage: [CoverageEntry(area: area, status: .measured, detail: "Caches, app data\(ctx.fullDiskAccess ? ", containers" : "") and logs in ~/Library.")])
    }

    /// Folders of one app share a key: "com.tinyspeck.slackmacgap", "TEAMID.com.example.app" → bundle ID.
    static func appKey(_ folder: String) -> String {
        let parts = folder.split(separator: ".")
        if parts.count > 3, parts[0].count == 10, parts[0].uppercased() == parts[0] { return parts.dropFirst().joined(separator: ".") }
        return folder.hasPrefix("group.") ? String(folder.dropFirst(6)) : folder
    }

    /// The app's real name when it's installed, otherwise the folder name.
    static func appName(_ key: String) -> String {
        guard key.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) else { return key }
        return (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
    }
}

/// Downloads and Documents: the user's own files, never cleaned in bulk.
public struct PersonalFilesProvider: Provider {
    public let area = "Personal files"

    public init() {}

    public func scan(_ ctx: ScanContext) async -> ProviderResult {
        guard ctx.fullDiskAccess else {
            return ProviderResult(coverage: [CoverageEntry(area: area, status: .noAccess, detail: "Downloads and Documents need Full Disk Access.")])
        }
        let downloads = ctx.expand("~/Downloads"), documents = ctx.expand("~/Documents")
        let oldEnough = Date().addingTimeInterval(-90 * 86_400)
        // The pickable list: the largest entries not touched for 90 days.
        let candidates = FileSizes.children(of: downloads, ctx.walk()).filter { name, _ in
            let date = (try? FileManager.default.attributesOfItem(atPath: downloads + "/" + name))?[.modificationDate] as? Date
            return (date ?? .distantPast) < oldEnough
        }.prefix(50).map { Target(downloads + "/" + $0.name, bytes: $0.size.privateBytes, identity: FileSizes.identity(downloads + "/" + $0.name)) }
        let facts = [
            Fact(.downloads, onDisk: FileSizes.measure(downloads, ctx.walk()).onDisk, targets: Array(candidates), path: downloads),
            // Git checkouts inside Documents belong to the Git owner; don't count them twice.
            Fact(.documents, onDisk: FileSizes.measure(documents, ctx.walk(skipGitCheckouts: true)).onDisk, path: documents),
        ]
        return ProviderResult(owners: [
            Owner(id: "downloads", name: "Downloads", kind: .personalFiles, location: "~/Downloads", items: [Rules.item(facts[0])]),
            Owner(id: "documents", name: "Documents", kind: .personalFiles, location: "~/Documents", items: [Rules.item(facts[1])]),
        ], coverage: [CoverageEntry(area: area, status: .measured, detail: "Downloads and Documents.")])
    }
}
