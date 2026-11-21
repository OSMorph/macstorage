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
        return DiskUsage(total: total, free: free, purgeable: max(0, important - free),
                         dataVolumeUsed: volumeUsed(dataVolume).map { min($0, total - free) })
    }

    /// True when a volume is mounted at `path` (not just a folder on the volume above it).
    static func isMountPoint(_ path: String) -> Bool {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return false }
        let mountedOn = withUnsafeBytes(of: &fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return mountedOn == path
    }

    /// Bytes used by the APFS volume mounted at `path`: its own space, not its container's
    /// (`statfs` reports the whole container's used space for every APFS volume). Nil when
    /// no volume is mounted there or it doesn't say.
    static func volumeUsed(_ path: String) -> Int64? {
        guard isMountPoint(path) else { return nil }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
        var buffer = [UInt8](repeating: 0, count: 64)
        guard getattrlist(path, &request, &buffer, buffer.count, 0) == 0 else { return nil }
        // The reply: its length, the attributes returned (five groups: common, volume, dir,
        // file, fork), then the space used. The volume can decline to return it.
        return buffer.withUnsafeBytes { raw -> Int64? in
            let returned = raw.loadUnaligned(fromByteOffset: 8, as: attrgroup_t.self)
            guard returned & attrgroup_t(ATTR_VOL_SPACEUSED) != 0 else { return nil }
            return raw.loadUnaligned(fromByteOffset: 4 + MemoryLayout<attribute_set_t>.size, as: Int64.self)
        }
    }

    static let dataVolume = "/System/Volumes/Data"
    static let volumes = ["/": "System volume", "/System/Volumes/Preboot": "Preboot", "/System/Volumes/VM": "Swap and sleep image", "/System/Volumes/Update": "Staged updates"]

    public func scan(_ ctx: ScanContext) async -> ProviderResult {
        // A volume that's mounted but can't be measured stays listed, as not measured.
        let mounted = Self.volumes.sorted { $0.key < $1.key }.filter { Self.isMountPoint($0.key) }
        let facts = mounted.map { path, name in Fact(.macOSVolume, key: name, name: name, onDisk: Self.volumeUsed(path).map(Measure.bytes) ?? .notMeasured) }
        let failed = facts.filter { $0.onDisk.bytes == nil }.compactMap(\.name) + (Self.volumeUsed(Self.dataVolume) == nil ? ["Data volume"] : [])
        var owners = [Owner(id: "macos", name: "macOS", kind: .system, location: "System, Preboot, VM and Update volumes", isOwnVolume: true, items: facts.map(Rules.item))]
        let clt = "/Library/Developer/CommandLineTools"
        if ctx.exists(clt) {
            let options = ctx.walk()
            let size = await offload { FileSizes.measure(clt, options) }
            owners.append(Owner(id: "clt", name: "Command Line Tools", kind: .system, location: clt,
                                items: [Rules.item(Fact(.commandLineTools, onDisk: size.onDisk, path: clt))]))
        }
        let coverage = failed.isEmpty
            ? CoverageEntry(area: area, status: .measured, detail: "Disk capacity, purgeable space and macOS volumes.")
            : CoverageEntry(area: area, status: .failed, detail: "Disk capacity and purgeable space measured; macOS didn't report the size of: \(failed.joined(separator: ", ")).")
        return ProviderResult(owners: owners, coverage: [coverage])
    }
}

/// Xcode: DerivedData, Archives, device support and unavailable simulators.
public struct XcodeProvider: Provider {
    public let area = "Xcode"

    public init() {}

    public func scan(_ ctx: ScanContext) async -> ProviderResult {
        let dev = ctx.expand("~/Library/Developer/Xcode")
        guard ctx.exists(dev) else { return ProviderResult(coverage: [CoverageEntry(area: area, status: .skipped, detail: "Xcode hasn't been used on this Mac.")]) }
        let options = ctx.walk()
        typealias Entry = (target: Target, size: FolderSize)
        func entries(_ sub: String) async -> [Entry] {
            await offload {
                (FileSizes.children(of: dev + "/" + sub, options) ?? []).map { name, size in
                    let path = dev + "/" + sub + "/" + name
                    return (Target(path, bytes: size.privateBytes, identity: FileSizes.identity(path)), size)
                }
            }
        }
        func fact(_ kind: ItemKind, _ entries: [Entry], _ sub: String) -> Fact? {
            guard !entries.isEmpty else { return nil }
            let size = FolderSize.total(entries.map(\.size))
            var fact = Fact(kind, onDisk: size.onDisk, sharedBytes: size.shared > 0 ? size.shared : nil, reclaimable: size.reclaimable,
                            targets: entries.map(\.target), path: dev + "/" + sub)
            fact.targetsComplete = size.isComplete
            return fact
        }
        // Keep device support for the newest OS version of each platform; older ones are stale.
        var support: [Entry] = []
        for sub in ["iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport"] {
            support += await entries(sub).sorted { Self.osVersion($0.target.id).compare(Self.osVersion($1.target.id), options: .numeric) == .orderedDescending }.dropFirst()
        }
        var facts = [fact(.xcodeDerivedData, await entries("DerivedData"), "DerivedData"), fact(.xcodeArchives, await entries("Archives"), "Archives"),
                     fact(.xcodeDeviceSupport, support, "")].compactMap { $0 }
        if let json = await ctx.output("xcrun", ["simctl", "list", "devices", "unavailable", "-j"]),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(SimctlDevices.self, from: data) {
            let udids = decoded.devices.values.flatMap { $0 }.map(\.udid)
            if !udids.isEmpty {
                let root = ctx.expand("~/Library/Developer/CoreSimulator/Devices")
                let sizes = await offload { udids.map { FileSizes.measure(root + "/" + $0, options) } }
                let total = FolderSize.total(sizes)
                facts.append(Fact(.simulatorsUnavailable, onDisk: total.onDisk, reclaimable: total.reclaimable,
                                  targets: zip(udids, sizes).map { Target($0, bytes: $1.privateBytes) }, path: root))
            }
        }
        return ProviderResult(owners: facts.isEmpty ? [] : [Owner(id: "xcode", name: "Xcode", kind: .developerTools, location: ctx.display(dev), items: facts.map(Rules.item))],
                              coverage: [CoverageEntry(area: area, status: .measured, detail: "DerivedData, Archives, device support and simulators.")])
    }

    /// The OS version in a device support folder's name ("iPhone15,2 17.2 (21C62)" → "17.2").
    static func osVersion(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.split(separator: " ").first { $0.contains(".") && $0.allSatisfy { $0.isNumber || $0 == "." } }.map(String.init) ?? name
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
        var unlisted: [String] = []
        func collect(_ folder: String, _ kind: ItemKind) async {
            let root = ctx.expand(folder), options = ctx.walk()
            guard !ctx.protectedPaths.contains(root) else { return }
            guard let children = await offload({ FileSizes.children(of: root, options) }) else { unlisted.append(folder); return }
            for (name, size) in children where size.allocated >= Self.threshold {
                let path = root + "/" + name
                // macOS services' caches: grouped, never cleaned (background services can't be detected as running).
                let service = kind == .appCache && Self.isSystemService(name)
                let key = service ? Self.systemServicesKey : Self.appKey(name), factKind = service ? .systemCache : kind
                var fact = Fact(factKind, key: "\((folder as NSString).lastPathComponent)/\(name)", name: service ? name : nil, onDisk: size.onDisk,
                                sharedBytes: size.shared > 0 ? size.shared : nil, reclaimable: size.reclaimable,
                                targets: factKind == .appCache ? [Target(path, bytes: size.privateBytes, identity: FileSizes.identity(path))] : [], path: path)
                fact.appBundleID = factKind == .appCache ? key : nil   // matched against running apps before trashing
                byApp[key, default: []].append(fact)
            }
        }
        await collect("~/Library/Caches", .appCache)
        await collect("~/Library/Application Support", .appData)
        await collect("~/Library/Containers", .appData)
        await collect("~/Library/Group Containers", .appData)
        // Developer tools have their own providers (keys as `appKey` returns them).
        let toolKeys: Set<String> = ["go-build", "pip", "pypoetry", "Homebrew", "com.docker.docker", "com.docker", "dev.orbstack", "pnpm", "uv"]
        let owners = byApp.filter { !toolKeys.contains($0.key) }.map { key, facts in
            key == Self.systemServicesKey
                ? Owner(id: "macos-services", name: "macOS services' caches", kind: .system, location: "~/Library/Caches", items: facts.map(Rules.item))
                : Owner(id: "app:" + key, name: Self.appName(key), kind: .apps, location: facts.compactMap(\.path).map(ctx.display).joined(separator: ", "), items: facts.map(Rules.item))
        }
        // Logs go to the Trash folder by folder (one per app), so the list stays short.
        let logs = ctx.expand("~/Library/Logs"), options = ctx.walk()
        let listed = await offload { FileSizes.children(of: logs, options) }
        let logFolders = listed ?? []
        let logTargets = logFolders.map { Target(logs + "/" + $0.name, bytes: $0.size.privateBytes, identity: FileSizes.identity(logs + "/" + $0.name)) }
        var logSize = FolderSize.total(logFolders.map(\.size))
        if listed == nil { logSize.unreadable += 1 }   // the folder couldn't be listed: a lower bound, not zero
        let logBytes = logSize.allocated
        var logFact = Fact(.appLogs, onDisk: logSize.onDisk, reclaimable: logSize.reclaimable, targets: logTargets, path: logs)
        logFact.targetsComplete = logSize.isComplete
        let logOwner = Owner(id: "logs", name: "Logs", kind: .system, location: "~/Library/Logs", items: [Rules.item(logFact)])
        return ProviderResult(owners: owners + (logBytes > 0 || listed == nil ? [logOwner] : []),
                              coverage: [CoverageEntry(area: area, status: .measured, detail: "Caches, app data\(ctx.fullDiskAccess ? ", containers" : "") and logs in ~/Library.")]
                                  + (listed == nil ? [CoverageEntry(area: "Logs", status: .failed, detail: "~/Library/Logs couldn't be listed, so its size is a lower bound.")] : [])
                                  + unlisted.map { CoverageEntry(area: $0, status: .failed, detail: "Couldn't be listed, so the apps in it weren't measured.") })
    }

    static let systemServicesKey = "macOS services"

    /// Caches of Apple's background services, which run without being visible apps.
    static func isSystemService(_ folder: String) -> Bool {
        folder.hasPrefix("com.apple.") || ["CloudKit", "GeoServices", "FamilyCircle", "familycircled", "PassKit", "Metadata"].contains(folder)
    }

    /// Folders of one app share a key: "com.tinyspeck.slackmacgap", "TEAMID.com.example.app" → bundle ID.
    static func appKey(_ folder: String) -> String {
        let parts = folder.split(separator: ".")
        if parts.count >= 3, parts[0].count == 10, parts[0].uppercased() == parts[0] { return parts.dropFirst().joined(separator: ".") }
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
        let options = ctx.walk(), noGit = ctx.walk(skipGitCheckouts: true)
        let (listed, documentsSize) = await offload { (FileSizes.children(of: downloads, options), FileSizes.measure(documents, noGit)) }
        let children = listed ?? []
        // The pickable list: the largest entries not touched for 90 days.
        let candidates = children.filter { name, _ in
            let date = (try? FileManager.default.attributesOfItem(atPath: downloads + "/" + name))?[.modificationDate] as? Date
            return (date ?? .distantPast) < oldEnough
        }.prefix(50).map { Target(downloads + "/" + $0.name, bytes: $0.size.privateBytes, identity: FileSizes.identity(downloads + "/" + $0.name)) }
        let facts = [
            Fact(.downloads, onDisk: listed == nil ? .notMeasured : FolderSize.total(children.map(\.size)).onDisk, targets: Array(candidates), path: downloads),
            // Git checkouts inside Documents belong to the Git owner; don't count them twice.
            Fact(.documents, onDisk: documentsSize.onDisk, path: documents),
        ]
        return ProviderResult(owners: [
            Owner(id: "downloads", name: "Downloads", kind: .personalFiles, location: "~/Downloads", items: [Rules.item(facts[0])]),
            Owner(id: "documents", name: "Documents", kind: .personalFiles, location: "~/Documents", items: [Rules.item(facts[1])]),
        ], coverage: [CoverageEntry(area: area, status: .measured, detail: "Downloads and Documents.")])
    }
}
