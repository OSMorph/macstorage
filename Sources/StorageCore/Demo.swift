import Foundation

/// A realistic, anonymous developer Mac for demo mode, screenshots and tests.
/// Built from facts through the real rules, so it can't drift from them.
public enum Demo {
    static let gb: Int64 = 1_000_000_000
    static func gb(_ v: Double) -> Int64 { Int64(v * 1e9) }
    static func list(_ n: Int, _ make: (Int) -> String, bytes: Int64) -> [Target] {
        (0..<n).map { Target(make($0), bytes: bytes / Int64(max(n, 1))) }
    }
    static func hex(_ i: Int, _ len: Int = 32) -> String {
        var x = UInt64(truncatingIfNeeded: i &* 2_654_435_761 &+ 97)
        var s = ""
        while s.count < len { x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; s += String(x >> 33, radix: 36) }
        return String(s.prefix(len))
    }

    public static let scanDate = Date(timeIntervalSince1970: 1_795_000_000)

    public static func snapshot() -> Snapshot {
        func owner(_ id: String, _ name: String, _ kind: OwnerKind, _ location: String, note: String? = nil, ownVolume: Bool = false, _ facts: [Fact]) -> Owner {
            Owner(id: id, name: name, kind: kind, location: location, note: note, isOwnVolume: ownVolume, items: facts.map(Rules.item))
        }
        let pkgs = ["openssl", "python3", "nodejs", "go", "llvm", "git", "curl", "sqlite", "zlib", "cmake", "rustc", "ffmpeg"]
        let owners = [
            owner("downloads", "Downloads", .personalFiles, "~/Downloads", [
                Fact(.downloads, onDisk: .bytes(gb(64)), targets: [
                    Target("~/Downloads/old-backups/", bytes: gb(21.4)), Target("~/Downloads/Xcode_26.1.xip", bytes: gb(11.9)),
                    Target("~/Downloads/ubuntu-24.04-desktop-arm64.iso", bytes: gb(6.1)), Target("~/Downloads/screen-recording.mov", bytes: gb(4.2)),
                    Target("~/Downloads/Docker.dmg", bytes: gb(0.6)),
                ]),
            ]),
            owner("nix", "Nix store", .developerTools, "/nix (its own APFS volume)", ownVolume: true, [
                Fact(.nixDeadPaths, onDisk: .bytes(gb(16.7)), targets: list(30_496, { "/nix/store/\(hex($0))-\(pkgs[$0 % pkgs.count])-1.\($0 % 13)" }, bytes: gb(16.7)), counts: ["paths": 30_496]),
                Fact(.nixOldGenerations, onDisk: .notMeasured, reclaimable: .notMeasured, counts: ["generations": 34]),
                Fact(.nixLive, onDisk: .bytes(gb(98))),
            ]),
            owner("docker", "Docker Desktop", .developerTools, "~/Library/Containers/com.docker.docker", note: "One VM disk file, Docker.raw: 64 GB logical, 50.1 GB on disk.", [
                Fact(.dockerBuildCache, onDisk: .bytes(gb(24.3)), reclaimable: .bytes(gb(21.5)), targets: list(737, { "cache record \(hex($0 + 1000, 12))" }, bytes: gb(21.5)), counts: ["records": 737]),
                Fact(.dockerUnusedImages, onDisk: .bytes(gb(8.3)), reclaimable: .bytes(gb(7.5)), targets: list(23, { "image-\($0):old \(hex($0 + 2000, 12))" }, bytes: gb(7.5)), counts: ["unused": 23, "total": 44]),
                Fact(.dockerStoppedContainers, onDisk: .bytes(110_000_000), targets: list(31, { "api-\($0 + 1)" }, bytes: 40_000_000), counts: ["stopped": 31, "total": 58]),
                Fact(.dockerUnusedVolumes, onDisk: .bytes(gb(3)), targets: list(20, { "pgdata-\(hex($0 + 3000, 6))" }, bytes: gb(2.1)), counts: ["unused": 20, "total": 25]),
                Fact(.dockerDiskSlack, onDisk: .bytes(gb(14.4))),
            ]),
            owner("slack", "Slack", .apps, "~/Library/Containers/com.tinyspeck.slackmacgap", [
                Fact(.appCache, key: "slack", onDisk: .bytes(gb(3.2)), targets: [Target("~/Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Caches", bytes: gb(3.2))]),
                Fact(.appData, key: "slack", onDisk: .bytes(gb(5.1))),
            ]),
            owner("go", "Go", .developerTools, "~/go/pkg/mod, ~/Library/Caches/go-build", [
                Fact(.goModuleCache, onDisk: .bytes(gb(10.5)), targets: list(2_140, { "~/go/pkg/mod/github.com/example/module\($0 % 97)@v1.\($0 % 40).\($0 % 9)" }, bytes: gb(10.5)), root: "~/go/pkg/mod"),
                Fact(.goBuildCache, onDisk: .bytes(gb(3)), targets: list(32_026, { "~/Library/Caches/go-build/\(hex($0 + 4000, 2))/\(hex($0 + 4000))-d" }, bytes: gb(3)), root: "~/Library/Caches/go-build"),
            ]),
            owner("git", "Git checkouts", .developerTools, "88 checkouts in ~/Developer", note: "61 repos and 27 worktrees. 15.2 GB if shared blocks were counted per copy.", [
                Fact(.gitBuildOutput, onDisk: .bytes(gb(3.9)), targets: list(22, { "~/Developer/project-\($0)/node_modules" }, bytes: gb(3.9)), counts: ["checkouts": 22]),
                Fact(.gitUnsavedWork, onDisk: .bytes(gb(5.6)), counts: ["checkouts": 31]),
                Fact(.gitRecent, onDisk: .bytes(gb(1.2))),
            ]),
            owner("node", "Node.js", .developerTools, "~/.npm, ~/Library/pnpm", [
                Fact(.npmCache, onDisk: .bytes(gb(5.6)), targets: list(1_800, { "~/.npm/_cacache/content-v2/sha512/\(hex($0 + 5000, 2))/\(hex($0 + 5000))" }, bytes: gb(5.6)), root: "~/.npm/_cacache"),
                Fact(.pnpmStore, onDisk: .bytes(gb(2.8)), reclaimable: .bytes(gb(1))),
            ]),
            owner("chrome", "Google Chrome", .apps, "~/Library/Caches/Google", [
                Fact(.appCache, key: "chrome", onDisk: .bytes(gb(2.3)), targets: [Target("~/Library/Caches/Google/Chrome", bytes: gb(2.3))]),
            ]),
            owner("python", "Python", .developerTools, "~/.cache/uv, ~/Library/Caches/pip", [
                Fact(.uvCache, onDisk: .bytes(350_000_000), sharedBytes: gb(2.9), targets: list(1_200, { "~/.cache/uv/archive-v0/\(hex($0 + 6000, 21))" }, bytes: 350_000_000), root: "~/.cache/uv"),
                Fact(.pipCache, onDisk: .bytes(400_000_000), targets: list(412, { "~/Library/Caches/pip/http-v2/\(hex($0 + 7000))" }, bytes: 400_000_000), root: "~/Library/Caches/pip"),
            ]),
            owner("homebrew", "Homebrew", .developerTools, "/opt/homebrew, ~/Library/Caches/Homebrew", [
                Fact(.homebrewOldVersions, onDisk: .bytes(240_000_000), targets: [Target("/opt/homebrew/Library/Homebrew/vendor/portable-ruby/3.3.4_1", bytes: 33_600_000), Target("~/Library/Caches/Homebrew/downloads/node-24.18.0.bottle.tar.gz", bytes: 206_400_000)]),
            ]),
            owner("logs", "Logs", .system, "~/Library/Logs", [
                Fact(.appLogs, onDisk: .bytes(840_000_000), targets: list(884, { "~/Library/Logs/DiagnosticReports/report-\($0).log" }, bytes: 840_000_000)),
            ]),
            owner("macos", "macOS", .system, "System, Preboot, Recovery and VM volumes", ownVolume: true, [
                Fact(.macOSVolume, onDisk: .bytes(gb(50.5))),
            ]),
        ]
        let disk = DiskUsage(total: gb(994.7), free: gb(512), purgeable: gb(3.4), dataVolumeUsed: gb(285))
        let coverage = [
            CoverageEntry(area: "Full Disk Access", status: .measured, detail: "Granted."),
            CoverageEntry(area: "Docker Desktop", status: .measured, detail: "Running. Two Docker contexts point to the same engine, so it was counted once.", seconds: 4),
            CoverageEntry(area: "podman", status: .skipped, detail: "Installed, but no podman machine exists."),
            CoverageEntry(area: "Nix", status: .measured, detail: "Dead paths sized; old generations not measured yet (takes about 30 s).", seconds: 16),
            CoverageEntry(area: "Xcode", status: .skipped, detail: "Not installed (Command Line Tools only)."),
            CoverageEntry(area: "Home folder and Library", status: .measured, detail: "All folders measured.", seconds: 187),
            CoverageEntry(area: "Outside the home folder", status: .notMeasured, detail: "/Applications, /Library and /private/var aren't measured yet; they make up most of \"Not attributed yet\"."),
        ]
        return Snapshot(date: scanDate, scanDuration: 386, disk: disk, owners: owners, coverage: coverage, folders: [
            "~": [
                FolderEntry(name: "Downloads", bytes: gb(64), kind: .personalFiles, owners: [OwnerShare(ownerID: "downloads", bytes: gb(64))]),
                FolderEntry(name: "Library", bytes: gb(96), kind: .apps, owners: [OwnerShare(ownerID: "docker", bytes: gb(50.1)), OwnerShare(ownerID: "slack", bytes: gb(8.3))], hasChildren: true),
                FolderEntry(name: "Developer", bytes: gb(10.7), kind: .developerTools, owners: [OwnerShare(ownerID: "git", bytes: gb(10.7))]),
                FolderEntry(name: "go", bytes: gb(10.5), kind: .developerTools, owners: [OwnerShare(ownerID: "go", bytes: gb(10.5))]),
            ],
        ])
    }

    /// Nine weekly scans ending at the demo snapshot, with one earlier cleanup.
    public static func history() -> History {
        let week: TimeInterval = 7 * 86_400
        let used: [Double] = [440, 446, 455, 459, 468, 439, 458, 470, 482.7]
        let docker: [Double] = [36, 41, 46, 34, 39, 44, 33, 42, 50.1]
        let scans = used.indices.map { i in
            ScanSummary(date: scanDate.addingTimeInterval(-Double(used.count - 1 - i) * week), used: gb(used[i]), free: gb(994.7 - used[i]),
                        owners: ["docker": gb(docker[i]), "downloads": gb(58 + Double(i) * 0.75)], names: ["docker": "Docker Desktop", "downloads": "Downloads"],
                        events: i == 8 ? [ScanEvent(ownerID: "docker", text: "New builds of 4 projects"), ScanEvent(ownerID: "downloads", text: "2 disk images added")]
                            : i == 5 ? [ScanEvent(ownerID: "docker", text: "Pruned in a cleanup")] : [])
        }
        return History(scans: scans)
    }
}
