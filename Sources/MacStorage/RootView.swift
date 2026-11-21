import StorageCore
import StorageMac
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: Binding<AppSection?>(get: { model.section }, set: { if let s = $0 { model.section = s } })) { s in
                Label(s.title, systemImage: s.symbol)
                    .badge(s == .cleanup ? model.cleanupCount : 0)
                    .tag(s)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { DiskFooter(disk: model.snapshot?.disk) }
            .disabled(model.snapshot == nil)
        } detail: {
            VStack(spacing: 0) {
                StatusStrips(model: model)
                Group {
                    if model.loading {
                        ProgressView("Loading the last scan…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if model.snapshot == nil {
                        WelcomeView(model: model)
                    } else {
                        switch model.section {
                        case .overview: OverviewView(model: model)
                        case .owners: OwnersView(model: model)
                        case .folders: FoldersView(model: model)
                        case .history: HistoryView(model: model)
                        case .cleanup: CleanupView(model: model)
                        case .coverage: CoverageView(model: model)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(model.snapshot == nil ? "Welcome" : model.section.title)
            .navigationSubtitle(statusText)
            .toolbar {
                ToolbarItem {
                    if model.scanning != nil {
                        Button("Stop scan", action: model.stopScan)
                    } else {
                        Button(model.snapshot == nil ? "Scan this Mac" : "Scan again", action: model.scan)
                            .buttonStyle(.borderedProminent)
                            .disabled(model.demo || model.sheet != nil)
                            .help(model.demo ? "Demo mode shows sample data." : "Measure everything again.")
                    }
                }
            }
            .searchable(text: $model.search, placement: .toolbar, prompt: "Owners, items, folders")
            .searchSuggestions { SearchSuggestions(model: model) }
        }
        .sheet(isPresented: Binding(get: { model.sheet != nil }, set: { if !$0 { model.sheet = nil } })) {
            CleanupSheet(model: model).frame(width: 780, height: 680)
        }
    }

    private var statusText: String {
        if let p = model.scanning {
            return "Scanning \(p.running.first ?? "…") (\(min(p.finished.count + 1, p.total)) of \(p.total))"
        }
        guard let s = model.snapshot else { return "No scan yet" }
        if s.isPartial { return "Partial scan, stopped" }
        let when = s.date.formatted(date: .abbreviated, time: .shortened)
        return model.demo ? "Demo data" : "Last scan \(when) · took \(Duration.seconds(s.scanDuration).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))"
    }
}

/// Notices above the content: scanning, partial results, unsaved records, sizes from
/// before a cleanup, missing Full Disk Access.
struct StatusStrips: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let p = model.scanning {
                if model.snapshot == nil || model.snapshot?.isPartial == true {
                    strip("First scan in progress: results appear as each area finishes (\(p.finished.count) of \(p.total) done). Stopping keeps what's finished.", .blue)
                } else {
                    strip("You're looking at the previous scan. These numbers refresh when the new scan finishes.", .blue)
                }
            } else if let s = model.snapshot, s.isPartial {
                HStack {
                    Label("Scan stopped before \(s.unfinishedAreas.joined(separator: ", ")) finished. These totals are partial and weren't saved.", systemImage: "pause.circle")
                    Spacer()
                    Button("Scan again", action: model.scan).disabled(model.demo)
                }
                .padding(8).background(.blue.opacity(0.1))
            }
            if let error = model.scanSaveError {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                    Spacer()
                    Button("Try again", action: model.retrySaveScan)
                }
                .padding(8).background(.yellow.opacity(0.15))
            }
            if !model.unsavedRuns.isEmpty, model.sheet == nil {
                HStack {
                    Label("\(plural(model.unsavedRuns.count, "cleanup record")) couldn't be saved. \(model.unsavedRuns.first?.value ?? "")", systemImage: "exclamationmark.triangle.fill")
                    Spacer()
                    Button("Try again") {
                        Task { for run in model.history.runs where model.unsavedRuns[run.id] != nil { await model.persist(run) } }
                    }
                }
                .padding(8).background(.yellow.opacity(0.15))
            }
            if !model.cleaned.isEmpty || !model.cleanupState.partlyCleaned.isEmpty {
                strip("Sizes are from the scan before today's cleanup. Completed steps have left Cleanup; By owner keeps their scan-time sizes, marked “Cleaned today”. Scan again to re-measure.", .blue)
            }
            if !model.fullDiskAccess, !model.demo {
                HStack {
                    Label("Full Disk Access is off. Downloads, Documents and other apps' data are skipped, so their space shows as “Not attributed yet”.", systemImage: "exclamationmark.triangle.fill")
                    Spacer()
                    Button("Open Privacy & Security…", action: FullDiskAccess.openSettings)
                }
                .padding(8).background(.yellow.opacity(0.15))
            }
        }
    }

    private func strip(_ text: String, _ tint: Color) -> some View {
        Text(text).frame(maxWidth: .infinity, alignment: .leading).padding(8).background(tint.opacity(0.1))
    }
}

struct DiskFooter: View {
    let disk: DiskUsage?

    var body: some View {
        if let disk, disk.total > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Text("Macintosh HD").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: Double(disk.used), total: Double(disk.total))
                Text("\(formatBytes(disk.free)) free of \(formatBytes(disk.total))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(12)
        }
    }
}

struct SearchSuggestions: View {
    let model: AppModel

    var body: some View {
        let q = model.search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, let s = model.snapshot {
            let owners = s.owners.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.location.localizedCaseInsensitiveContains(q) }
            let items = s.owners.flatMap { o in o.items.filter { $0.name.localizedCaseInsensitiveContains(q) }.map { (o, $0) } }
            ForEach(owners) { o in
                Button { model.show(owner: o.id); model.search = "" } label: { Label("\(o.name) · \(formatBytes(o.onDisk))", systemImage: "square.grid.2x2") }
            }
            ForEach(items, id: \.1.id) { o, item in
                Button { model.show(owner: o.id, item: item.id); model.search = "" } label: { Label("\(o.name) · \(item.name)", systemImage: "doc") }
            }
            if owners.isEmpty, items.isEmpty {
                Text("No owners or items match “\(q)”.")
            }
        }
    }
}
