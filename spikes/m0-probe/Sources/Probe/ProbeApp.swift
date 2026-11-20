import AppKit
import SwiftUI

@main
struct ProbeApp: App {
    @State private var model = ProbeModel()

    var body: some Scene {
        WindowGroup("MacStorage Probe") {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 640)
        }
        .defaultSize(width: 900, height: 820)
    }
}

struct ContentView: View {
    @Bindable var model: ProbeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("This throwaway app checks what macstorage will be able to do on this Mac. It only reads: the one exception is a small test folder in the temporary directory, which it deletes again. It makes no network requests.")
                    .foregroundStyle(.secondary)

                GroupBox("1. This copy of the app") {
                    VStack(alignment: .leading, spacing: 4) {
                        row("Version", "\(model.install.version) (build \(model.install.build), \(model.install.commit))")
                        row("Quarantine mark", model.install.quarantine == nil ? "absent" : "present")
                        row("Signature", model.install.signatureValid)
                        row("Signed by", model.install.certificates.first ?? "ad hoc / unsigned")
                        row("Requirement", model.install.designatedRequirement ?? "n/a")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("2. Full Disk Access") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(model.hasFullDiskAccess ? "Granted" : "Not granted",
                              systemImage: model.hasFullDiskAccess ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(model.hasFullDiskAccess ? .green : .orange)
                            .font(.headline)
                        ForEach(model.access) { check in
                            row(check.label, describe(check.status))
                        }
                        if !model.hasFullDiskAccess {
                            Text("Open the settings, turn on MacStorageProbe (use + to add it from Applications if it isn't listed), then quit and reopen this app.")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Open Full Disk Access settings") { model.openFullDiskAccessSettings() }
                            Button("Check again") { model.recheckAccess() }
                            Button("Quit") { NSApp.terminate(nil) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("3. Discovery") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Measures where space goes and runs read-only commands for each tool it finds (Docker, OrbStack, podman, colima, Nix, Xcode, Homebrew, language caches, git checkouts). Container engines that aren't running are left alone. It can take 5 to 30 minutes.")
                            .foregroundStyle(.secondary)
                        if !model.hasFullDiskAccess {
                            Text("Without Full Disk Access, Desktop, Documents, Downloads and other apps' data are skipped so macOS doesn't show a series of permission prompts.")
                                .foregroundStyle(.orange)
                        }
                        HStack {
                            if model.running {
                                Button("Stop") { model.stop() }
                                ProgressView().controlSize(.small)
                                Text(model.progress).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            } else {
                                Button(model.report.isEmpty ? "Run discovery" : "Run again") { model.start() }
                                    .keyboardShortcut(.defaultAction)
                                if let seconds = model.finishedIn {
                                    Text("Finished in \(Int(seconds)) s").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !model.report.isEmpty {
                    GroupBox("4. Review the anonymized report") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Names of people, machines, projects, images, remotes and folders were replaced with placeholders. Read it through before saving. Add anything else to hide (an employer's name, a codename), separated by commas.")
                                .foregroundStyle(.secondary)
                            HStack {
                                TextField("Extra words to hide", text: $model.redactionText)
                                Button("Apply") { model.applyRedactions() }
                            }
                            Text(model.summary).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Save report…") { model.save() }
                                Button("Copy") { model.copy() }
                            }
                            ScrollView {
                                Text(preview(model.report))
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(6)
                            }
                            .frame(minHeight: 360)
                            .background(Color(nsColor: .textBackgroundColor))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(20)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).frame(width: 190, alignment: .leading).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func describe(_ status: AccessCheck.Status) -> String {
        switch status {
        case .readable: return "readable"
        case .missing: return "not present"
        case .denied(let why): return "denied (\(why))"
        }
    }

    private func preview(_ text: String) -> String {
        let limit = 150_000
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n\n[Preview cut off here. Save or copy to get the full report.]"
    }
}
