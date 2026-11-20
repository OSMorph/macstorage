import Foundation
import ProbeCore

final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}

/// Read-only discovery of where space goes on this Mac. Produces a raw (not yet
/// anonymized) Markdown report and teaches the scrubber which names to hide.
/// Blocking: run it off the main thread.
final class Discovery {
    let scrubber: Scrubber
    let fullDiskAccess: Bool
    let cancel: CancelToken
    let progress: (String) -> Void

    private let home = NSHomeDirectory()
    private var out: [String] = []
    private var env: [String: String] = [:]
    private var tools: [String: String] = [:]
    private var commandLineToolsInstalled = false
    private var sizeBudgetEnds = Date.distantFuture
    private var gitBudgetEnds = Date.distantFuture

    init(scrubber: Scrubber, fullDiskAccess: Bool, cancel: CancelToken, progress: @escaping (String) -> Void) {
        self.scrubber = scrubber
        self.fullDiskAccess = fullDiskAccess
        self.cancel = cancel
        self.progress = progress
    }

    func run() -> String {
        let started = Date()
        let steps: [(String, () -> Void)] = [
            ("Locating tools", self.locateTools),
            ("System and volumes", self.systemAndVolumes),
            ("Container engines", self.containerEngines),
            ("Container VM disks", self.vmDisks),
            ("Nix", self.nix),
            ("Xcode and simulators", self.xcode),
            ("Homebrew", self.homebrew),
            ("Language caches", self.languageCaches),
            ("Folders in the home folder", self.homeFolders),
            ("Git checkouts", self.gitCheckouts),
        ]
        for (title, step) in steps {
            if cancel.isCancelled { out.append("\n_Stopped before: \(title)_"); break }
            progress(title)
            let t0 = Date()
            out.append("\n## \(title)\n")
            step()
            out.append("\n_\(title): \(String(format: "%.1f", Date().timeIntervalSince(t0))) s_")
        }
        out.append("\n_Discovery total: \(String(format: "%.0f", Date().timeIntervalSince(started))) s_")
        return out.joined(separator: "\n")
    }

    // MARK: - Tools and PATH

    private static let extraDirs = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
        "~/.nix-profile/bin", "/etc/profiles/per-user/$USER/bin", "/run/current-system/sw/bin",
        "/nix/var/nix/profiles/default/bin", "~/.orbstack/bin", "/Applications/Docker.app/Contents/Resources/bin",
        "/Applications/OrbStack.app/Contents/MacOS/xbin", "~/.volta/bin", "~/.bun/bin", "~/.cargo/bin", "~/go/bin",
        "~/.local/bin", "~/Library/pnpm", "~/.rd/bin", "/opt/podman/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    private static let toolNames = [
        "docker", "podman", "colima", "limactl", "orb", "nix", "nix-store", "nix-env", "darwin-rebuild", "home-manager",
        "brew", "go", "node", "npm", "pnpm", "yarn", "bun", "volta", "python3", "pip3", "uv", "cargo", "rustup",
        "gradle", "mvn", "pod", "git", "xcrun", "xcodebuild", "tmutil", "diskutil",
    ]

    /// /usr/bin stubs that open an installer dialog when the Command Line Tools are missing.
    private static let cltStubs: Set<String> = ["git", "python3", "pip3", "xcrun", "xcodebuild", "make", "clang", "swift"]

    private func expand(_ dir: String) -> String {
        dir.replacingOccurrences(of: "~", with: home).replacingOccurrences(of: "$USER", with: NSUserName())
    }

    private func locateTools() {
        let processEnv = ProcessInfo.processInfo.environment
        let guiPath = processEnv["PATH"] ?? ""
        let shell = processEnv["SHELL"] ?? "/bin/zsh"

        let shellResult = Shell.run("\(Shell.quote(shell)) -ilc 'printf \"\\n__MSPATH__%s\\n\" \"$PATH\"'",
                                    environment: processEnv, timeout: 20)
        let shellPath = shellResult.stdout
            .split(separator: "\n")
            .first { $0.hasPrefix("__MSPATH__") }
            .map { String($0.dropFirst("__MSPATH__".count)) } ?? ""

        let xcodeSelect = Shell.run("/usr/bin/xcode-select -p", environment: processEnv, timeout: 10)
        commandLineToolsInstalled = xcodeSelect.succeeded

        var dirs: [String] = []
        var sources: [String: String] = [:]
        func add(_ list: [String], _ source: String) {
            for d in list where !d.isEmpty {
                let e = expand(d)
                if sources[e] == nil { sources[e] = source; dirs.append(e) }
            }
        }
        add(shellPath.split(separator: ":").map(String.init), "login shell PATH")
        add(Self.extraDirs, "known location")
        add(guiPath.split(separator: ":").map(String.init), "app PATH")

        env = [
            "PATH": dirs.joined(separator: ":"),
            "HOME": home,
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "SHELL": shell,
            "LANG": "en_US.UTF-8",
            "TERM": "dumb",
            "NO_COLOR": "1",
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ANALYTICS": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "DOCKER_CLI_HINTS": "false",
        ]
        if let tmp = processEnv["TMPDIR"] { env["TMPDIR"] = tmp }

        out.append("- PATH the app was started with: `\(guiPath)`")
        out.append("- Login shell (\(shell)) PATH: `\(shellPath.isEmpty ? "(could not read: \(shellResult.timedOut ? "timed out" : "exit \(shellResult.exitCode.map { String($0) } ?? "?")"))" : shellPath)`")
        out.append("- Login shell took \(String(format: "%.1f", shellResult.duration)) s")
        out.append("- `xcode-select -p`: \(commandLineToolsInstalled ? xcodeSelect.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : "not set (Command Line Tools missing)")")
        out.append("")
        out.append("| Tool | Path | Found via | In app PATH? |")
        out.append("|---|---|---|---|")
        let guiDirs = Set(guiPath.split(separator: ":").map(String.init))
        for name in Self.toolNames {
            var found: String?
            for d in dirs {
                let p = d + "/" + name
                if FileManager.default.isExecutableFile(atPath: p) { found = p; break }
            }
            guard let path = found else {
                out.append("| \(name) | not found | | |")
                continue
            }
            let dir = (path as NSString).deletingLastPathComponent
            let isStub = dir == "/usr/bin" && Self.cltStubs.contains(name) && !commandLineToolsInstalled
            if !isStub { tools[name] = path }
            out.append("| \(name) | \(path)\(isStub ? " (installer stub, not used)" : "") | \(sources[dir] ?? "?") | \(guiDirs.contains(dir) ? "yes" : "no") |")
        }
    }

    private func has(_ tool: String) -> Bool { tools[tool] != nil }

    // MARK: - Running commands into the report

    @discardableResult
    private func cmd(_ command: String, timeout: TimeInterval = 60, requires: [String] = [], maxLines: Int = 400) -> CommandResult? {
        if cancel.isCancelled { return nil }
        for r in requires where !has(r) {
            out.append("\n`\(command)` — skipped, \(r) not found")
            return nil
        }
        progress(command)
        let r = Shell.run(command, environment: env, timeout: timeout)
        var status = r.launchError.map { "could not start: \($0)" } ?? "exit \(r.exitCode.map { String($0) } ?? "?")"
        if r.timedOut { status += ", timed out after \(Int(timeout)) s" }
        out.append("\n### `\(command)`\n\(status) · \(String(format: "%.1f", r.duration)) s")
        let stdout = clip(r.stdout, maxLines: maxLines)
        if !stdout.isEmpty { out.append("```\n\(stdout)\n```") }
        let stderr = clip(r.stderr, maxLines: 40)
        if !stderr.isEmpty { out.append("stderr:\n```\n\(stderr)\n```") }
        return r
    }

    private func clip(_ s: String, maxLines: Int) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count <= maxLines { return trimmed }
        return lines.prefix(maxLines).joined(separator: "\n") + "\n[... \(lines.count - maxLines) more lines]"
    }

    /// Runs a command without adding it to the report (used to learn names to hide).
    private func quiet(_ command: String, timeout: TimeInterval = 30) -> CommandResult {
        Shell.run(command, environment: env, timeout: timeout)
    }

    // MARK: - Sizes

    private func isProtected(_ path: String) -> Bool {
        guard !fullDiskAccess else { return false }
        let protected = ["/Desktop", "/Documents", "/Downloads", "/Library/Mail", "/Library/Messages", "/Library/Containers",
                         "/Library/Group Containers", "/Library/Mobile Documents", "/Library/Safari", "/Pictures", "/.Trash",
                         "/Library/Application Support/MobileSync"]
        return protected.contains { path == home + $0 || path.hasPrefix(home + $0 + "/") }
    }

    private struct SizeRow { var label: String; var totals: FileSizes.DirTotals?; var note: String? }

    private func measure(_ path: String, limit: TimeInterval = 60, skipping: Set<String> = []) -> SizeRow {
        if isProtected(path) { return SizeRow(label: path, totals: nil, note: "skipped (needs Full Disk Access)") }
        let remaining = sizeBudgetEnds.timeIntervalSinceNow
        if remaining <= 0 { return SizeRow(label: path, totals: nil, note: "skipped (size time budget used up)") }
        progress("Measuring \(path)")
        let t = FileSizes.directoryTotals(path, timeLimit: min(limit, remaining), skipping: skipping)
        if !t.exists { return SizeRow(label: path, totals: nil, note: "not present") }
        return SizeRow(label: path, totals: t, note: nil)
    }

    private func sizeTable(_ rows: [SizeRow], sort: Bool = true, top: Int? = nil) {
        var rows = rows
        if sort { rows.sort { ($0.totals?.allocated ?? -1) > ($1.totals?.allocated ?? -1) } }
        var shown = rows
        if let top, rows.count > top { shown = Array(rows.prefix(top)) }
        out.append("")
        out.append("| Path | Allocated | Private (clone-aware) | Files | Complete | Seconds | Note |")
        out.append("|---|---|---|---|---|---|---|")
        for r in shown {
            if let t = r.totals {
                out.append("| \(r.label) | \(FileSizes.format(t.allocated)) | \(t.privateSizeKnown ? FileSizes.format(t.privateSize) : "n/a") | \(t.files) | \(t.complete ? "yes" : "no (time limit)") | \(String(format: "%.1f", t.seconds)) | \(t.unreadable > 0 ? "\(t.unreadable) unreadable" : "") |")
            } else {
                out.append("| \(r.label) | | | | | | \(r.note ?? "") |")
            }
        }
        if shown.count < rows.count {
            let rest = rows.dropFirst(shown.count).reduce(Int64(0)) { $0 + ($1.totals?.allocated ?? 0) }
            out.append("| (\(rows.count - shown.count) more) | \(FileSizes.format(rest)) | | | | | |")
        }
    }

    private func children(of path: String, includeHidden: Bool = true) -> [String] {
        guard !isProtected(path),
              let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return names.filter { includeHidden || !$0.hasPrefix(".") }.sorted().map { path + "/" + $0 }
    }

    // MARK: - Steps

    private func systemAndVolumes() {
        cmd("sw_vers")
        cmd("uname -m; sysctl -n hw.model hw.memsize hw.ncpu")
        cmd("df -k")
        cmd("mount")
        cmd("diskutil apfs list", timeout: 60)
        cmd("tmutil listlocalsnapshots /", requires: ["tmutil"])
        cmd("diskutil apfs listSnapshots /System/Volumes/Data", timeout: 60)

        // Learn volume names so the scrubber can hide them.
        let plist = quiet("diskutil apfs list -plist", timeout: 60)
        if let data = plist.stdout.data(using: .utf8),
           let root = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            learnVolumeNames(root)
        }

        out.append("\nVolume capacity as Foundation reports it:")
        out.append("")
        out.append("| Volume | Total | Available | Available for important use | Available for opportunistic use |")
        out.append("|---|---|---|---|---|")
        for path in ["/", "/System/Volumes/Data", "/nix"] where FileManager.default.fileExists(atPath: path) {
            let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                             .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityForOpportunisticUsageKey]
            guard let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys) else { continue }
            out.append("| \(path) | \(FileSizes.format(v.volumeTotalCapacity.map { Int64($0) })) | \(FileSizes.format(v.volumeAvailableCapacity.map { Int64($0) })) | \(FileSizes.format(v.volumeAvailableCapacityForImportantUsage)) | \(FileSizes.format(v.volumeAvailableCapacityForOpportunisticUsage)) |")
        }
    }

    private func learnVolumeNames(_ node: Any) {
        if let dict = node as? [String: Any] {
            if let name = dict["Name"] as? String { scrubber.learn(name, as: "volume") }
            for value in dict.values { learnVolumeNames(value) }
        } else if let array = node as? [Any] {
            for value in array { learnVolumeNames(value) }
        }
    }

    private func learnColumns(_ text: String, columns: [Int: String]) {
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            for (index, category) in columns where index < fields.count {
                let value = fields[index]
                if category == "tag" && !Self.isIdentifyingTag(value) { continue }
                if category == "volume" && value.range(of: #"^[0-9a-f]{32,}$"#, options: .regularExpression) != nil { continue }
                scrubber.learn(value, as: category)
            }
        }
    }

    private static func isIdentifyingTag(_ tag: String) -> Bool {
        let common: Set<String> = ["latest", "alpine", "slim", "bookworm", "bullseye", "jammy", "noble", "focal", "stable",
                                   "nightly", "test", "dev", "main", "master", "release", "debug", "arm64", "amd64", "none"]
        let words = tag.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 }
        return words.contains { !common.contains($0) }
    }

    private func containerEngines() {
        if has("docker") {
            cmd("docker version --format '{{.Client.Version}}'", timeout: 15)
            cmd("docker context ls", timeout: 15)
            let list = quiet("docker context ls --format '{{.Name}}\t{{.DockerEndpoint}}'", timeout: 15)
            for line in list.stdout.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let name = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: " *"))
                let endpoint = parts[1]
                scrubber.learn(name, as: "context")
                guard endpoint.hasPrefix("unix://") else {
                    out.append("\nContext `\(name)`: not a local socket, skipped.")
                    continue
                }
                let engine: String
                if endpoint.contains(".orbstack") { engine = "orbstack" }
                else if endpoint.contains(".colima") { engine = "colima" }
                else if endpoint.contains("podman") { engine = "podman" }
                else { engine = "docker-desktop" }
                if !engineRunning(engine) {
                    out.append("\nContext `\(name)` (\(engine)): engine not running, left alone.")
                    continue
                }
                out.append("\n#### Context `\(name)` (\(engine))")
                let c = "docker --context \(Shell.quote(name))"
                let images = quiet("\(c) images --all --format '{{.Repository}}\t{{.Tag}}'", timeout: 60)
                learnColumns(images.stdout, columns: [0: "image", 1: "tag"])
                let ps = quiet("\(c) ps -a --format '{{.Names}}'", timeout: 30)
                learnColumns(ps.stdout, columns: [0: "container"])
                let vols = quiet("\(c) volume ls --format '{{.Name}}'", timeout: 30)
                learnColumns(vols.stdout, columns: [0: "volume"])
                cmd("\(c) system df", timeout: 120)
                cmd("\(c) system df -v", timeout: 180, maxLines: 600)
                cmd("\(c) images --all --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}'", timeout: 60, maxLines: 600)
                cmd("\(c) ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}'", timeout: 30)
                cmd("\(c) buildx du 2>&1 | tail -5", timeout: 60)
            }
        } else {
            out.append("docker CLI not found.")
        }

        if has("podman") {
            cmd("podman --version", timeout: 15)
            cmd("podman machine list", timeout: 30)
            let inspect = cmd("podman machine inspect", timeout: 30, maxLines: 300)
            var running = false
            if let data = inspect?.stdout.data(using: .utf8),
               let machines = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for m in machines {
                    if let name = m["Name"] as? String { scrubber.learn(name, as: "context") }
                    if (m["State"] as? String)?.lowercased() == "running" { running = true }
                }
            }
            if running {
                let images = quiet("podman images --all --format '{{.Repository}}\t{{.Tag}}'", timeout: 60)
                learnColumns(images.stdout, columns: [0: "image", 1: "tag"])
                learnColumns(quiet("podman ps -a --format '{{.Names}}'").stdout, columns: [0: "container"])
                learnColumns(quiet("podman volume ls --format '{{.Name}}'").stdout, columns: [0: "volume"])
                cmd("podman system df", timeout: 120)
                cmd("podman system df -v", timeout: 240, maxLines: 600)
                cmd("podman images --all --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}'", timeout: 60, maxLines: 600)
                cmd("podman ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}'", timeout: 30)
            } else {
                out.append("\nNo podman machine running, left alone.")
            }
        }

        if has("colima") {
            cmd("colima list", timeout: 30)
        }
        if has("limactl") {
            cmd("limactl list", timeout: 30)
        }
        cmd("pgrep -lf 'OrbStack|com.docker.backend|Docker Desktop|colima|limactl|vfkit|krunkit|qemu-system' | cut -c1-160", timeout: 10)
    }

    private func engineRunning(_ engine: String) -> Bool {
        switch engine {
        case "orbstack": return quiet("pgrep -x OrbStack", timeout: 5).succeeded
        case "docker-desktop": return quiet("pgrep -f com.docker.backend", timeout: 5).succeeded
        case "colima": return quiet("colima status", timeout: 15).succeeded
        default: return true
        }
    }

    private func vmDisks() {
        var places = [
            home + "/Library/Containers/com.docker.docker/Data",
            home + "/.orbstack",
            home + "/.local/share/containers/podman/machine",
            home + "/.config/containers/podman/machine",
            home + "/.colima",
            home + "/.lima",
        ]
        for child in children(of: home + "/Library/Group Containers") {
            let lower = child.lowercased()
            if lower.contains("orbstack") || lower.contains("macvirt") || lower.contains("docker") { places.append(child) }
        }
        out.append("Large files (≥ 512 MiB) in container engine folders: logical size vs what is really allocated.")
        out.append("")
        out.append("| File | Logical | Allocated | Private (clone-aware) |")
        out.append("|---|---|---|---|")
        var rows: [SizeRow] = []
        for place in places {
            let row = measure(place, limit: 120)
            rows.append(row)
            for f in row.totals?.largestFiles ?? [] {
                let facts = FileSizes.facts(f.path)
                out.append("| \(f.path) | \(FileSizes.format(f.logical)) | \(FileSizes.format(f.allocated)) | \(FileSizes.format(facts.privateSize)) |")
            }
        }
        out.append("\nFolder totals:")
        sizeTable(rows, sort: false)
    }

    private func nix() {
        guard has("nix-store") || FileManager.default.fileExists(atPath: "/nix/store") else {
            out.append("Nix not found.")
            return
        }
        cmd("nix --version", requires: ["nix"])
        cmd("df -k /nix")
        cmd("ls -la /nix/var/nix/profiles /nix/var/nix/profiles/per-user/\"$USER\" ~/.local/state/nix/profiles 2>&1")
        cmd("nix-env --list-generations", requires: ["nix-env"])
        cmd("test -e /run/current-system && ls -la /run/current-system", timeout: 10)
        cmd("darwin-rebuild --list-generations 2>&1 | tail -20", requires: ["darwin-rebuild"])
        cmd("home-manager generations 2>&1 | head -20", requires: ["home-manager"])
        cmd("ls /nix/store | wc -l", timeout: 120)
        cmd("nix-store --gc --print-roots 2>/dev/null | wc -l", timeout: 300, requires: ["nix-store"])
        cmd("nix-store --gc --print-roots 2>/dev/null | grep -v '^/proc' | head -150", timeout: 300, requires: ["nix-store"])
        cmd("nix-store --gc --print-dead 2>/dev/null | wc -l", timeout: 900, requires: ["nix-store"])
        cmd("nix-store --gc --print-dead 2>/dev/null | xargs -n 1000 nix-store -q --size 2>/dev/null | awk '{s+=$1} END {print s+0, \"bytes in dead paths\"}'",
            timeout: 900, requires: ["nix-store"])
    }

    private func xcode() {
        let developer = home + "/Library/Developer"
        guard commandLineToolsInstalled || FileManager.default.fileExists(atPath: developer) else {
            out.append("No Xcode or Command Line Tools.")
            return
        }
        if commandLineToolsInstalled {
            cmd("xcode-select -p")
            cmd("xcodebuild -version 2>&1", timeout: 30, requires: ["xcodebuild"])
            cmd("xcrun simctl list -j devices", timeout: 90, requires: ["xcrun"], maxLines: 800)
            cmd("xcrun simctl runtime list -j", timeout: 90, requires: ["xcrun"], maxLines: 400)
            cmd("xcrun simctl list -j runtimes", timeout: 90, requires: ["xcrun"], maxLines: 400)
        }
        out.append("\nXcode folders:")
        sizeTable(children(of: developer + "/Xcode").map { measure($0, limit: 120) })
        out.append("\nDerivedData (one folder per project):")
        sizeTable(children(of: developer + "/Xcode/DerivedData").map { measure($0, limit: 30) }, top: 40)
        out.append("\nDevice support (one folder per OS version):")
        var support: [SizeRow] = []
        for kind in ["iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport", "visionOS DeviceSupport"] {
            support += children(of: developer + "/Xcode/" + kind).map { measure($0, limit: 30) }
        }
        sizeTable(support)
        out.append("\nSimulators:")
        sizeTable(children(of: developer + "/CoreSimulator").map { measure($0, limit: 180) })
        sizeTable(["/Library/Developer/CoreSimulator", "/Library/Developer/CoreSimulator/Volumes",
                   "/Library/Developer/CommandLineTools", "/Applications/Xcode.app"].map { measure($0, limit: 120) }, sort: false)
    }

    private func homebrew() {
        guard has("brew") else { out.append("Homebrew not found."); return }
        let prefix = cmd("brew --prefix", timeout: 30)?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cache = cmd("brew --cache", timeout: 30)?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        cmd("brew list --formula | wc -l; brew list --cask | wc -l", timeout: 60)
        cmd("brew cleanup -n", timeout: 300, maxLines: 300)
        var paths = [cache]
        if !prefix.isEmpty { paths += [prefix + "/Cellar", prefix + "/Caskroom"] }
        sizeTable(paths.filter { !$0.isEmpty }.map { measure($0, limit: 120) }, sort: false)
    }

    private func languageCaches() {
        var reported: [String] = []
        func pathsFrom(_ r: CommandResult?) {
            for line in r?.stdout.split(separator: "\n") ?? [] {
                let s = line.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("/") { reported.append(s) }
            }
        }
        pathsFrom(cmd("go env GOCACHE GOMODCACHE GOPATH", requires: ["go"]))
        pathsFrom(cmd("npm config get cache", requires: ["npm"]))
        pathsFrom(cmd("pnpm store path", requires: ["pnpm"]))
        pathsFrom(cmd("yarn cache dir", requires: ["yarn"]))
        pathsFrom(cmd("bun pm cache", requires: ["bun"]))
        pathsFrom(cmd("pip3 cache dir", requires: ["pip3"]))
        pathsFrom(cmd("uv cache dir", requires: ["uv"]))
        cmd("rustup toolchain list", requires: ["rustup"])
        cmd("volta list all 2>&1 | head -40", requires: ["volta"])

        let defaults = [
            "~/Library/Caches/go-build", "~/go/pkg/mod", "~/.npm", "~/Library/pnpm/store", "~/.local/share/pnpm/store",
            "~/Library/Caches/Yarn", "~/.yarn/berry/cache", "~/.bun/install/cache", "~/.volta", "~/Library/Caches/pip",
            "~/.cache/uv", "~/Library/Caches/uv", "~/.cargo/registry", "~/.cargo/git", "~/.rustup/toolchains",
            "~/.gradle/caches", "~/.gradle/wrapper", "~/.m2/repository", "~/Library/Caches/CocoaPods", "~/.cocoapods",
            "~/.pyenv/versions", "~/.nvm/versions", "~/.cache",
        ].map(expand)
        var seen = Set<String>()
        let all = (reported + defaults).filter { seen.insert(($0 as NSString).standardizingPath).inserted }
        sizeTable(all.map { measure($0, limit: 120) })
    }

    private func homeFolders() {
        sizeBudgetEnds = Date().addingTimeInterval(15 * 60)
        out.append("Top level of the home folder (Library is broken down separately):")
        let top = children(of: home).filter { !$0.hasSuffix("/Library") }
        sizeTable(top.map { measure($0, limit: 120) }, top: 40)

        let library = home + "/Library"
        out.append("\n~/Library:")
        sizeTable(children(of: library).map { measure($0, limit: 90) }, top: 40)
        for sub in ["Caches", "Application Support", "Containers", "Group Containers", "Developer", "Logs"] {
            out.append("\n~/Library/\(sub):")
            sizeTable(children(of: library + "/" + sub).map { measure($0, limit: 45) }, top: 25)
        }
        out.append("\nPersonal data:")
        sizeTable([home + "/Library/Application Support/MobileSync/Backup", home + "/Library/Mail",
                   home + "/Library/Messages/Attachments", home + "/.Trash"].map { measure($0, limit: 120) }, sort: false)
        if !fullDiskAccess {
            out.append("\n_Without Full Disk Access, Desktop, Documents, Downloads, Pictures, Mail, Messages, Trash and other apps' containers were skipped._")
        }
    }

    // MARK: - Git

    private struct Repo {
        var root: String
        var kind: String     // repo, worktree, submodule
        var remote: String?
        var lastActivity: Date?
    }

    private static let gitSkip: Set<String> = [
        "Library", ".Trash", "node_modules", ".cache", ".npm", ".cargo", ".rustup", ".gradle", ".m2", ".orbstack",
        ".colima", ".lima", ".nix-profile", ".nix-defexpr", ".local", ".volta", ".bun", "Pictures", "Music", "Movies",
        ".venv", "venv", "target", ".build", "DerivedData", ".direnv", "vendor", "Pods", "Applications",
    ]

    private func gitCheckouts() {
        gitBudgetEnds = Date().addingTimeInterval(10 * 60)
        sizeBudgetEnds = gitBudgetEnds
        progress("Looking for git checkouts")
        let t0 = Date()
        var repos: [Repo] = []
        let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: home), includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [], errorHandler: { _, _ in true })
        var searchComplete = true
        while let url = enumerator?.nextObject() as? URL {
            if cancel.isCancelled || Date().timeIntervalSince(t0) > 180 || repos.count >= 1500 { searchComplete = false; break }
            let path = url.path
            let name = url.lastPathComponent
            if isProtected(path) || Self.gitSkip.contains(name) { enumerator?.skipDescendants(); continue }
            if (enumerator?.level ?? 0) > 7 { enumerator?.skipDescendants(); continue }
            guard name == ".git" else { continue }
            let root = url.deletingLastPathComponent().path
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            if isDir.boolValue {
                enumerator?.skipDescendants()
                repos.append(Repo(root: root, kind: "repo", remote: remote(configAt: path + "/config"), lastActivity: modified(path + "/index") ?? modified(path + "/HEAD")))
            } else {
                let pointer = (try? String(contentsOfFile: path, encoding: .utf8))?
                    .replacingOccurrences(of: "gitdir:", with: "").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let gitDir = pointer.hasPrefix("/") ? pointer : (root as NSString).appendingPathComponent(pointer)
                let isWorktree = gitDir.contains("/worktrees/")
                let common = isWorktree ? ((gitDir as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent : gitDir
                repos.append(Repo(root: root, kind: isWorktree ? "worktree" : "submodule", remote: remote(configAt: common + "/config"),
                                  lastActivity: modified(gitDir + "/index") ?? modified(gitDir + "/HEAD")))
            }
        }
        out.append("- Search: \(String(format: "%.0f", Date().timeIntervalSince(t0))) s, \(searchComplete ? "complete" : "stopped early (time or count limit)"), max depth 7, skipped: \(Self.gitSkip.sorted().joined(separator: ", "))")
        out.append("- Found \(repos.count) checkouts: \(repos.filter { $0.kind == "repo" }.count) repos, \(repos.filter { $0.kind == "worktree" }.count) worktrees, \(repos.filter { $0.kind == "submodule" }.count) submodules")

        // Teach the scrubber project names so they are hidden everywhere in the report.
        for r in repos {
            let base = (r.root as NSString).lastPathComponent.replacingOccurrences(of: #"[-_.](19|20)\d{6}$"#, with: "", options: .regularExpression)
            scrubber.learn(base, as: "dir")
            if let remote = r.remote {
                scrubber.learn(remote, as: "url")
                let repoName = ((remote as NSString).lastPathComponent as NSString).deletingPathExtension
                scrubber.learn(repoName, as: "dir")
            }
        }

        let canRunGit = has("git")
        var byRemote: [String: (count: Int, allocated: Int64, privateSize: Int64)] = [:]
        out.append("")
        out.append("| Checkout | Kind | Remote | Last activity | Changed files | Ahead | Allocated | Private (clone-aware) | Build output |")
        out.append("|---|---|---|---|---|---|---|---|---|")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        for (i, r) in repos.enumerated() {
            if cancel.isCancelled { break }
            if Date() > gitBudgetEnds {
                out.append("| (\(repos.count - i) more not measured: time budget used up) | | | | | | | | |")
                break
            }
            progress("Git checkout \(i + 1) of \(repos.count)")
            var changed = "?"
            var ahead = "?"
            if canRunGit && r.kind != "submodule" {
                let s = quiet("git -C \(Shell.quote(r.root)) status --porcelain=v1 --branch", timeout: 15)
                if s.succeeded {
                    let lines = s.stdout.split(separator: "\n")
                    changed = String(max(0, lines.count - 1))
                    if let first = lines.first, let range = first.range(of: #"ahead (\d+)"#, options: .regularExpression) {
                        ahead = String(first[range].dropFirst("ahead ".count))
                    } else {
                        ahead = lines.first?.contains("...") == true ? "0" : "no upstream"
                    }
                }
            }
            let total = FileSizes.directoryTotals(r.root, timeLimit: min(20, max(1, gitBudgetEnds.timeIntervalSinceNow)))
            var build: [String] = []
            for name in ["node_modules", "target", ".build", "dist", "build", ".direnv", ".venv", ".next", ".turbo", "vendor"] {
                let p = r.root + "/" + name
                guard FileManager.default.fileExists(atPath: p) else { continue }
                let t = FileSizes.directoryTotals(p, timeLimit: 10)
                build.append("\(name) \(FileSizes.format(t.allocated))\(t.complete ? "" : "+")")
            }
            let remoteKey = r.remote ?? "(no remote)"
            var agg = byRemote[remoteKey] ?? (count: 0, allocated: Int64(0), privateSize: Int64(0))
            agg.count += 1; agg.allocated += total.allocated; agg.privateSize += total.privateSize
            byRemote[remoteKey] = agg
            out.append("| \(r.root) | \(r.kind) | \(r.remote ?? "none") | \(r.lastActivity.map { formatter.string(from: $0) } ?? "?") | \(changed) | \(ahead) | \(FileSizes.format(total.allocated))\(total.complete ? "" : "+") | \(total.privateSizeKnown ? FileSizes.format(total.privateSize) : "n/a") | \(build.joined(separator: ", ")) |")
        }

        out.append("\nCheckouts grouped by remote:")
        out.append("")
        out.append("| Remote | Copies | Allocated | Private (clone-aware) |")
        out.append("|---|---|---|---|")
        for (remote, agg) in byRemote.sorted(by: { $0.value.allocated > $1.value.allocated }) {
            out.append("| \(remote) | \(agg.count) | \(FileSizes.format(agg.allocated)) | \(FileSizes.format(agg.privateSize)) |")
        }
    }

    private func remote(configAt path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var inOrigin = false
        var first: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line == "[remote \"origin\"]"
                continue
            }
            if line.hasPrefix("url") , let eq = line.firstIndex(of: "=") {
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if inOrigin { return value }
                if first == nil { first = value }
            }
        }
        return first
    }

    private func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
