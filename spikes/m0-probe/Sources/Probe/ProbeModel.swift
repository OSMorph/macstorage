import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import ProbeCore

@MainActor
@Observable
final class ProbeModel {
    var install = InstallInfo.current()
    var access: [AccessCheck] = DiskAccess.check()
    var running = false
    var progress = ""
    var startedAt: Date?
    var finishedIn: TimeInterval?
    var redactionText = ""
    var report = ""
    var summary = ""

    private var rawReport = ""
    private var scrubber: Scrubber?
    private var cancel = CancelToken()

    var hasFullDiskAccess: Bool { DiskAccess.hasFullDiskAccess(access) }

    func recheckAccess() {
        access = DiskAccess.check()
        install = InstallInfo.current()
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        guard !running else { return }
        recheckAccess()
        running = true
        report = ""
        summary = ""
        startedAt = Date()
        finishedIn = nil
        cancel = CancelToken()

        let scrubber = makeScrubber()
        self.scrubber = scrubber
        let fda = hasFullDiskAccess
        let token = cancel
        let header = reportHeader()

        Task.detached(priority: .userInitiated) {
            let apfs = APFSProbe.run()
            let discovery = Discovery(scrubber: scrubber, fullDiskAccess: fda, cancel: token) { message in
                Task { @MainActor in self.progress = message }
            }
            let body = discovery.run()
            let raw = header
                + "\n## APFS size behaviour\n\n" + APFSProbe.report(apfs.rows, notes: apfs.notes)
                + "\n" + body
            await MainActor.run {
                self.rawReport = raw
                self.finishedIn = self.startedAt.map { Date().timeIntervalSince($0) }
                self.running = false
                self.progress = ""
                self.applyRedactions()
            }
        }
    }

    func stop() { cancel.cancel() }

    func applyRedactions() {
        guard let scrubber, !rawReport.isEmpty else { return }
        let words = redactionText.split(whereSeparator: { $0 == "," || $0 == "\n" }).map(String.init)
        scrubber.redact(words)
        report = scrubber.scrub(rawReport)
        let counts = scrubber.lastSummary.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }
        summary = counts.isEmpty ? "Nothing needed replacing." : "Replaced: " + counts.joined(separator: ", ")
    }

    func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "macstorage-probe-report.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    private func makeScrubber() -> Scrubber {
        var hosts: [String] = []
        let hostName = ProcessInfo.processInfo.hostName
        hosts.append(hostName)
        if hostName.hasSuffix(".local") { hosts.append(String(hostName.dropLast(".local".count))) }
        if let computer = Host.current().localizedName { hosts.append(computer) }
        let scrubber = Scrubber(home: NSHomeDirectory(), userName: NSUserName(), hostNames: hosts)
        // The account's full name, word by word.
        scrubber.redact(NSFullUserName().split(separator: " ").map(String.init).filter { $0.count >= 3 })
        return scrubber
    }

    private func reportHeader() -> String {
        """
        # macstorage probe report

        Anonymized on this Mac before saving. Generated \(ISO8601DateFormatter().string(from: Date()).prefix(10)).

        ## This copy of the app

        \(install.report)

        ## Full Disk Access

        \(DiskAccess.report(access))
        """
    }
}
