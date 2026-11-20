import Foundation
import Security
import Darwin

// MARK: - 1. Install and signing

struct InstallInfo {
    var version = "?"
    var build = "?"
    var commit = "?"
    var bundlePath = ""
    var quarantine: String?          // value of com.apple.quarantine, nil when absent
    var identifier: String?
    var certificates: [String] = []
    var teamID: String?
    var designatedRequirement: String?
    var signatureValid: String = "unknown"

    static func current() -> InstallInfo {
        var info = InstallInfo()
        let bundle = Bundle.main
        info.version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        info.build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        info.commit = bundle.infoDictionary?["MSGitCommit"] as? String ?? "?"
        info.bundlePath = bundle.bundlePath

        let size = getxattr(info.bundlePath, "com.apple.quarantine", nil, 0, 0, 0)
        if size >= 0 {
            var buf = [UInt8](repeating: 0, count: size + 1)
            let n = getxattr(info.bundlePath, "com.apple.quarantine", &buf, size, 0, 0)
            info.quarantine = n >= 0 ? String(decoding: buf.prefix(n), as: UTF8.self) : "(present)"
        }

        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return info }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return info }

        let validity = SecStaticCodeCheckValidity(staticCode, [], nil)
        info.signatureValid = validity == errSecSuccess
            ? "valid"
            : "not valid (\(SecCopyErrorMessageString(validity, nil) as String? ?? "OSStatus \(validity)"))"

        var cfInfo: CFDictionary?
        if SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &cfInfo) == errSecSuccess,
           let dict = (cfInfo as NSDictionary?) as? [String: Any] {
            info.identifier = dict[kSecCodeInfoIdentifier as String] as? String
            info.teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
            if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate] {
                info.certificates = certs.map { (SecCertificateCopySubjectSummary($0) as String?) ?? "?" }
            }
        }
        var requirement: SecRequirement?
        if SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement {
            var text: CFString?
            if SecRequirementCopyString(requirement, [], &text) == errSecSuccess {
                info.designatedRequirement = text as String?
            }
        }
        return info
    }

    var report: String {
        """
        - Version: \(version) (build \(build), commit \(commit))
        - Location: \(bundlePath)
        - Quarantine mark: \(quarantine.map { "present (\($0))" } ?? "absent")
        - Signature: \(signatureValid)
        - Identifier: \(identifier ?? "n/a")
        - Certificate chain: \(certificates.isEmpty ? "none (ad hoc or unsigned)" : certificates.joined(separator: " → "))
        - Team ID: \(teamID ?? "none")
        - Designated requirement: `\(designatedRequirement ?? "n/a")`
        """
    }
}

// MARK: - 2. Full Disk Access

struct AccessCheck: Identifiable {
    enum Status: Equatable { case readable, denied(String), missing }
    var id: String { label }
    var label: String
    var path: String
    var status: Status
}

enum DiskAccess {
    /// Locations that are only readable with Full Disk Access. Desktop, Documents and
    /// Downloads are left out on purpose: touching them without access shows a consent prompt.
    static func check() -> [AccessCheck] {
        let home = NSHomeDirectory()
        let targets: [(String, String)] = [
            ("Privacy database (TCC.db)", home + "/Library/Application Support/com.apple.TCC/TCC.db"),
            ("Safari", home + "/Library/Safari"),
            ("Mail", home + "/Library/Mail"),
            ("Messages", home + "/Library/Messages"),
            ("Time Machine settings", "/Library/Preferences/com.apple.TimeMachine.plist"),
        ]
        return targets.map { label, path in
            AccessCheck(label: label, path: path, status: probe(path))
        }
    }

    static func hasFullDiskAccess(_ checks: [AccessCheck]) -> Bool {
        checks.contains { $0.status == .readable && ($0.label.hasPrefix("Privacy") || $0.label == "Safari") }
    }

    private static func probe(_ path: String) -> AccessCheck.Status {
        var isDir: ObjCBool = false
        // fileExists can report false for protected items, so try to open before deciding it's missing.
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let fd = open(path, O_RDONLY)
        if fd >= 0 {
            defer { close(fd) }
            if isDir.boolValue {
                do { _ = try FileManager.default.contentsOfDirectory(atPath: path); return .readable }
                catch { return .denied(error.localizedDescription) }
            }
            var byte: UInt8 = 0
            return read(fd, &byte, 1) >= 0 ? .readable : .denied(String(cString: strerror(errno)))
        }
        let err = errno
        if err == ENOENT && !exists { return .missing }
        return .denied(String(cString: strerror(err)))
    }

    static func report(_ checks: [AccessCheck]) -> String {
        var lines = ["- Full Disk Access: **\(hasFullDiskAccess(checks) ? "granted" : "not granted")**"]
        for c in checks {
            let status: String
            switch c.status {
            case .readable: status = "readable"
            case .missing: status = "not present"
            case .denied(let why): status = "denied (\(why))"
            }
            lines.append("- \(c.label): \(status) — \(c.path)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 3. APFS size behaviour

struct APFSRow {
    var label: String
    var facts: FileFacts
}

enum APFSProbe {
    /// Creates a few small test files in a temporary folder, measures them, then removes the folder.
    static func run() -> (rows: [APFSRow], notes: [String]) {
        var notes: [String] = []
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("macstorage-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            return ([], ["Could not create test folder: \(error.localizedDescription)"])
        }
        notes.append("Test folder (removed afterwards): \(dir)")

        let original = dir + "/original.bin"
        let clone = dir + "/clone.bin"
        let hardLink = dir + "/hardlink.bin"
        let sparse = dir + "/sparse.bin"
        var rows: [APFSRow] = []

        let mib = 1 << 20
        var bytes = [UInt8](repeating: 0, count: 32 * mib)
        for i in 0..<bytes.count { bytes[i] = UInt8(truncatingIfNeeded: (i &* 31) ^ (i >> 7)) }
        let content = Data(bytes)
        guard FileManager.default.createFile(atPath: original, contents: content) else {
            return ([], notes + ["Could not write test file"])
        }
        rows.append(APFSRow(label: "32 MiB file", facts: FileSizes.facts(original)))

        if clonefile(original, clone, 0) == 0 {
            rows.append(APFSRow(label: "original after cloning", facts: FileSizes.facts(original)))
            rows.append(APFSRow(label: "clone (unchanged)", facts: FileSizes.facts(clone)))
            if let h = FileHandle(forWritingAtPath: clone) {
                h.seek(toFileOffset: UInt64(8 * mib))
                h.write(Data(repeating: 0x5A, count: 2 * mib))
                try? h.synchronize()
                try? h.close()
            }
            rows.append(APFSRow(label: "clone after changing 2 MiB", facts: FileSizes.facts(clone)))
            rows.append(APFSRow(label: "original after clone changed", facts: FileSizes.facts(original)))
        } else {
            notes.append("clonefile failed: \(String(cString: strerror(errno)))")
        }

        if link(original, hardLink) == 0 {
            rows.append(APFSRow(label: "hard link to original", facts: FileSizes.facts(hardLink)))
        } else {
            notes.append("link failed: \(String(cString: strerror(errno)))")
        }

        if FileManager.default.createFile(atPath: sparse, contents: nil), let h = FileHandle(forWritingAtPath: sparse) {
            try? h.truncate(atOffset: UInt64(1024 * mib))
            h.seek(toFileOffset: 0)
            h.write(Data(repeating: 0x33, count: mib))
            try? h.synchronize()
            try? h.close()
            rows.append(APFSRow(label: "sparse 1 GiB, 1 MiB written", facts: FileSizes.facts(sparse)))
        }
        return (rows, notes)
    }

    private static func text<T: BinaryInteger>(_ value: T?) -> String {
        guard let value else { return "n/a" }
        return String(value)
    }

    static func report(_ rows: [APFSRow], notes: [String]) -> String {
        var lines = notes.map { "- \($0)" }
        lines.append("")
        lines.append("| File | logical | allocated (st_blocks) | URL allocated | URL total allocated | private size | clone id | clone refs | links | error |")
        lines.append("|---|---|---|---|---|---|---|---|---|---|")
        for r in rows {
            let f = r.facts
            let cells: [String] = [
                r.label,
                String(f.logical),
                String(f.allocated),
                text(f.urlAllocated),
                text(f.urlTotalAllocated),
                text(f.privateSize),
                text(f.cloneID),
                text(f.cloneRefCount),
                String(f.linkCount),
                f.error ?? "",
            ]
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }
}
