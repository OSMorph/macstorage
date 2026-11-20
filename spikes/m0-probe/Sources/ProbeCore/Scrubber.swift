import Foundation

/// Replaces anything that could identify a person, employer, machine or project
/// with stable placeholders (`dir-3`, `image-1`, `USER`, ...), while keeping the
/// shape of the text so it is still useful as a test fixture.
///
/// The same original always maps to the same placeholder within one Scrubber,
/// so relationships in the report (two paths in the same folder, an image used
/// by a container) survive anonymization.
public final class Scrubber {
    public let home: String
    public let userName: String
    public let hostNames: [String]

    private var placeholders: [String: [String: String]] = [:]   // category -> original -> placeholder
    private var counters: [String: Int] = [:]
    private var literals: [(original: String, category: String, caseInsensitive: Bool, prefix: Bool)] = []
    private var replacementCounts: [String: Int] = [:]

    public init(home: String, userName: String, hostNames: [String]) {
        var h = home
        while h.count > 1 && h.hasSuffix("/") { h.removeLast() }
        self.home = h
        self.userName = userName
        self.hostNames = hostNames.filter { $0.count >= 2 }
    }

    // MARK: - Registering things to hide

    /// Registers a literal (an image name, a container name, a git remote...) that
    /// must be replaced wherever it appears. Very short or well-known values are ignored.
    public func learn(_ value: String, as category: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v.count >= 3, !Scrubber.isHarmlessLiteral(v), !Scrubber.isKnownComponent(v) else { return }
        if category == "volume" && Scrubber.isKnownVolumeName(v) { return }
        guard !literals.contains(where: { $0.original == v }) else { return }
        _ = placeholder(for: v, category: category)
        literals.append((v, category, false, false))
    }

    /// Extra words the person wants hidden (an employer's name, a project codename).
    /// Matched case-insensitively.
    public func redact(_ words: [String]) {
        for w in words {
            let v = w.trimmingCharacters(in: .whitespacesAndNewlines)
            guard v.count >= 2 else { continue }
            guard !literals.contains(where: { $0.original.lowercased() == v.lowercased() }) else { continue }
            _ = placeholder(for: v.lowercased(), category: "redacted")
            literals.append((v, "redacted", true, false))
        }
    }

    /// A person's name, word by word. Also hides words that start with it
    /// ("Jane" hides "Janes-MacBook" and "Jane's"), case-insensitively.
    public func redactName(_ words: [String]) {
        for w in words {
            let v = w.trimmingCharacters(in: .whitespacesAndNewlines)
            guard v.count >= 3 else { continue }
            guard !literals.contains(where: { $0.original.lowercased() == v.lowercased() }) else { continue }
            _ = placeholder(for: v.lowercased(), category: "redacted")
            literals.append((v, "redacted", true, true))
        }
    }

    /// How many replacements of each kind the last `scrub` call made. Never includes originals.
    public var lastSummary: [String: Int] { replacementCounts }

    // MARK: - Scrubbing

    public func scrub(_ input: String) -> String {
        replacementCounts = [:]

        // 0. Paths under the home folder first, while the home path is still intact
        //    (a name redaction would otherwise rewrite the username inside it).
        var text = scrubHomePaths(input)

        // 1. Learned literals and redactions, longest first so "acme-api" wins over "acme".
        for item in literals.sorted(by: { $0.original.count > $1.original.count }) {
            let key = item.caseInsensitive ? item.original.lowercased() : item.original
            let replacement = placeholder(for: key, category: item.category)
            let escaped = NSRegularExpression.escapedPattern(for: item.original)
            let pattern = item.prefix
                ? "(?<![A-Za-z0-9])" + escaped + "[A-Za-z']*"
                : "(?<![A-Za-z0-9])" + escaped + "(?![A-Za-z0-9])"
            let options: NSRegularExpression.Options = item.caseInsensitive ? [.caseInsensitive] : []
            text = replace(pattern, options: options, in: text, category: item.category) { _ in replacement }
        }

        // 2. URLs (except local sockets and files), and scp-style git remotes.
        text = replace(#"\b(?:https?|ssh|git|tcp|ftp)://[^\s"'<>`)\]]+|\b[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[A-Za-z0-9._/~-]+"#,
                       in: text, category: "url") { m in self.placeholder(for: m, category: "url") }

        // 3. Email addresses.
        text = replace(#"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#, in: text, category: "email") { m in
            self.placeholder(for: m.lowercased(), category: "email")
        }

        // 4. Per-user temporary folders (/var/folders/xx/yyyy/) are random but stable per account.
        text = replace(#"/var/folders/[^/\s]+/[^/\s]+/"#, in: text, category: "path") { _ in "/var/folders/XX/XXXX/" }

        // 5. Names of mounted volumes.
        text = replace(#"(?<=/Volumes/)[^/\s"'`,;:()\[\]<>]+"#, in: text, category: "volume") { m in
            Scrubber.knownVolumeNames.contains(m) ? m : self.placeholder(for: m, category: "volume")
        }

        // 6. Host / computer names, then the username (host names often contain it).
        for host in hostNames.sorted(by: { $0.count > $1.count }) {
            text = replace("(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: host) + "(?![A-Za-z0-9])",
                           options: [.caseInsensitive], in: text, category: "host") { _ in "HOST" }
        }
        if userName.count >= 2 {
            text = replace("(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: userName) + "(?![A-Za-z0-9])",
                           in: text, category: "user") { _ in "USER" }
        }

        // 7. UUIDs (volume, device and simulator identifiers).
        text = replace(#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#,
                       in: text, category: "uuid") { m in self.placeholder(for: m.uppercased(), category: "uuid") }

        // 8. IPv4 addresses other than loopback / unspecified.
        text = replace(#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, in: text, category: "ip") { m in
            (m == "127.0.0.1" || m == "0.0.0.0") ? m : self.placeholder(for: m, category: "ip")
        }

        return text
    }

    // MARK: - Home paths

    private func scrubHomePaths(_ input: String) -> String {
        // Protect well-known folder names that contain spaces, so the path regex can treat
        // a space as the end of a path.
        var text = input
        for (i, name) in Scrubber.spacedNames.enumerated() {
            text = text.replacingOccurrences(of: name, with: "\u{1}\(i)\u{1}")
        }

        let homeEscaped = NSRegularExpression.escapedPattern(for: home)
        let pattern = homeEscaped + #"(?![^/\s"'`,;:()\[\]<>{}|=])((?:/[^/\s"'`,;:()\[\]<>{}|=]+)*)"#
        text = replace(pattern, in: text, category: "path") { match in
            let rest = String(match.dropFirst(self.home.count))
            let parts = rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            let mapped = parts.map { self.scrubComponent($0) }
            return "/Users/USER" + (mapped.isEmpty ? "" : "/" + mapped.joined(separator: "/"))
        }

        for (i, name) in Scrubber.spacedNames.enumerated() {
            text = text.replacingOccurrences(of: "\u{1}\(i)\u{1}", with: name)
        }
        return text
    }

    private func scrubComponent(_ component: String) -> String {
        // Protected spaced names come through as \u{1}N\u{1}.
        if component.hasPrefix("\u{1}") { return component }
        if Scrubber.isKnownComponent(component) { return component }
        // Placeholders produced earlier (url-1, image-2) stay as they are.
        if component.range(of: #"^(dir|url|email|uuid|ip|volume|image|container|remote|redacted|context)-\d+$"#,
                           options: .regularExpression) != nil { return component }

        // Keep a trailing date (worktree-20261006) and a short extension (.xcworkspace).
        var base = component
        var suffix = ""
        if let r = base.range(of: #"[-_.](19|20)\d{6}$"#, options: .regularExpression) {
            suffix = String(base[r]); base = String(base[..<r.lowerBound])
        } else if let r = base.range(of: #"\.[A-Za-z][A-Za-z0-9]{0,11}$"#, options: .regularExpression),
                  r.lowerBound != base.startIndex {
            let ext = String(base[r])
            if Scrubber.keptExtensions.contains(ext.lowercased()) { suffix = ext; base = String(base[..<r.lowerBound]) }
        }
        if Scrubber.isKnownComponent(base) { return base + suffix }
        return placeholder(for: base, category: "dir") + suffix
    }

    // MARK: - Helpers

    private func placeholder(for original: String, category: String) -> String {
        if let existing = placeholders[category]?[original] { return existing }
        let n = (counters[category] ?? 0) + 1
        counters[category] = n
        let value = "\(category)-\(n)"
        placeholders[category, default: [:]][original] = value
        return value
    }

    private func replace(_ pattern: String,
                         options: NSRegularExpression.Options = [],
                         in text: String,
                         category: String,
                         _ transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let ns = NSString(string: text)
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var last = 0
        for m in matches {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let original = ns.substring(with: m.range)
            let replacement = transform(original)
            if replacement != original { replacementCounts[category, default: 0] += 1 }
            result += replacement
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    // MARK: - Allow lists

    static func isKnownComponent(_ c: String) -> Bool {
        if knownComponents.contains(c.lowercased()) { return true }
        // Versions and numbers: 0, 17.5, v1.22.3
        if c.range(of: #"^v?\d[\d._]*$"#, options: .regularExpression) != nil { return true }
        // Content hashes: nix store hashes, docker ids, DerivedData suffixes are not identifying.
        if c.range(of: #"^[0-9a-f]{16,}$"#, options: .regularExpression) != nil { return true }
        // Apple's own bundle identifiers and well-known tool vendors.
        if c.hasPrefix("com.apple.") { return true }
        if knownVendorIDs.contains(where: { c.lowercased().contains($0) }) { return true }
        return false
    }

    static func isHarmlessLiteral(_ v: String) -> Bool {
        let lower = v.lowercased()
        if harmlessLiterals.contains(lower) { return true }
        // Official single-name images (postgres, docker.io/library/redis) say nothing about anyone.
        let stripped = lower
            .replacingOccurrences(of: "docker.io/library/", with: "")
            .replacingOccurrences(of: "library/", with: "")
        return officialImages.contains(stripped)
    }

    static let spacedNames = [
        "Application Support", "Group Containers", "Mobile Documents", "Saved Application State",
        "iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport", "visionOS DeviceSupport",
        "Xcode DeviceSupport", "Photos Library.photoslibrary", "Docker Desktop",
    ]

    static let keptExtensions: Set<String> = [
        ".xcworkspace", ".xcodeproj", ".xcarchive", ".app", ".raw", ".img", ".qcow2", ".sparsebundle",
        ".dmg", ".iso", ".sock", ".json", ".plist", ".log", ".db", ".sqlite", ".zip", ".tar", ".gz", ".git",
    ]

    static let knownVolumeNames: Set<String> = ["Macintosh HD", "Macintosh HD - Data", "Macintosh", "Recovery", "Preboot", "VM",
                                                 "Data", "Update", "xarts", "xART", "iSCPreboot", "Hardware", "Nix", "Nix Store"]

    static func isKnownVolumeName(_ name: String) -> Bool {
        knownVolumeNames.contains(name) || name.hasPrefix("Macintosh HD")
    }

    // Matched as substrings, so only dotted identifiers that can't be part of a project name.
    static let knownVendorIDs = ["com.docker.", "group.com.docker", "dev.kdrag0n.", "dev.orbstack.", ".orbstack", "com.github.",
                                 "org.nixos.", "com.jetbrains.", "com.microsoft.vscode"]

    static let harmlessLiterals: Set<String> = [
        "<none>", "none", "default", "desktop-linux", "orbstack", "colima", "podman-machine-default",
        "bridge", "host", "null", "true", "false", "origin", "main", "master",
    ]

    static let officialImages: Set<String> = [
        "alpine", "ubuntu", "debian", "busybox", "postgres", "redis", "mysql", "mariadb", "mongo", "nginx",
        "httpd", "node", "python", "golang", "rust", "openjdk", "eclipse-temurin", "hello-world", "registry",
        "traefik", "memcached", "rabbitmq", "elasticsearch", "minio/minio", "localstack/localstack",
    ]

    static let knownComponents: Set<String> = Set([
        // macOS home layout
        "library", "caches", "logs", "developer", "containers", "preferences", "cookies", "webkit", "mail",
        "messages", "safari", "mobilesync", "backup", "downloads", "desktop", "documents", "pictures", "movies",
        "music", "public", ".trash", "trash", "application scripts", "httpstorages", "diagnosticreports",
        "crashreporter", "metadata", "calendars", "contacts", "keychains", "photos", "fonts", "data", "tmp",
        "shared", "applications", "users", "user",
        // Xcode
        "xcode", "deriveddata", "archives", "coresimulator", "devices", "runtimes", "volumes", "userdata",
        "products", "intermediates.noindex", "index.noindex", "build", "sourcepackages", "modulecache.noindex",
        "products", "simulators", "profiles", "provisioning profiles",
        // dot folders and tools
        ".cache", ".config", ".local", "share", "state", "bin", "lib", "libexec", "include", "etc", "opt", "var",
        ".ssh", ".docker", ".orbstack", ".colima", ".lima", "_lima", "containers", "podman", "machine", "applehv",
        "libkrun", "qemu", "vms", "0", "storage", "overlay", "overlay-images", "overlay-layers", "volumes",
        "docker.raw", "data.img", "diffdisk", "basedisk", "disk", "run", "go", "pkg", "mod", "cache", "go-build",
        ".npm", "_cacache", "_npx", ".pnpm-store", "pnpm", "store", ".yarn", "yarn", "berry", ".bun", "install",
        ".volta", "tools", "image", "node", "npm", "inventory", ".cargo", "registry", "index", "src", "git",
        "checkouts", "db", ".rustup", "toolchains", "downloads", "update-hashes", "tmp", ".gradle", "caches",
        "wrapper", "dists", "daemon", "native", "jdks", ".m2", "repository", ".cocoapods", "repos", "cocoapods",
        "pip", "http", "http-v2", "wheels", "uv", "archive-v0", "builds-v0", "wheels-v5", "python", ".pyenv",
        "versions", ".nvm", ".nix-profile", ".nix-defexpr", "nix", "profiles", "per-user", "gcroots", "homebrew",
        "cellar", "caskroom", "api", ".direnv", ".git", "worktrees", "objects", "pack", "refs", "node_modules",
        ".bin", "target", "debug", "release", ".build", "dist", "out", ".venv", "venv", "__pycache__",
        ".next", ".turbo", ".vscode", ".idea", "jetbrains", "code", "user", "workspacestorage", "extensions",
        "google", "chrome", "default", "service worker", "cachestorage", "com.docker.docker", "group.com.docker",
        "docker", "ollama", "models", "blobs", "manifests", "projects", "src", "code", "work", "dev", "repos",
        "workspace", "workspaces", "github", "gitlab", "backups",
    ])
}
