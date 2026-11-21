import Charts
import StorageCore
import StorageMac
import SwiftUI

struct FoldersView: View {
    @Bindable var model: AppModel
    @State private var order = [KeyPathComparator(\FolderEntry.sortBytes, order: .reverse)]
    @State private var filter = ""

    /// The table shows this many entries at most, the largest first: a folder can hold a
    /// hundred thousand.
    static let rowLimit = 2_000

    var body: some View {
        if let s = model.snapshot {
            let level = model.folderLevel(model.folderPath)
            let entries = level?.entries ?? []
            let all = filter.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(filter) }
            let rows = all.count > Self.rowLimit
                ? Array(all.sorted { $0.sortBytes > $1.sortBytes }.prefix(Self.rowLimit)).sorted(using: order)
                : all.sorted(using: order)
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        breadcrumbs
                        Spacer()
                        TextField("Filter by name", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                    }
                    Text("Select a folder to see its owners; double-click or Return opens it.").font(.caption).foregroundStyle(.secondary)
                    if s.folders[model.folderPath] == nil, let level {
                        levelStatus(level)
                    }
                    Treemap(nodes: treemapNodes(all), selected: model.selectedFolder) { model.selectedFolder = $0 }
                        .frame(height: 260)
                    if entries.isEmpty, level?.isMeasuring != true, level?.problem == nil {
                        Callout(s.isPartial && model.folderPath == "~" ? "Folder sizes weren't measured: the scan stopped before they were." : "Nothing here takes space.")
                    } else if all.isEmpty, !filter.isEmpty {
                        Callout("Nothing here matches “\(filter)”.")
                    }
                    Table(rows, selection: $model.selectedFolder, sortOrder: $order) {
                        TableColumn("Name", value: \.name) { r in
                            Label(r.name, systemImage: model.isFolder(r) ? "folder" : "doc")
                        }
                        TableColumn("Mostly", value: \.kind.label) { r in Text(r.bytes == nil ? "Unknown" : r.kind.label).foregroundStyle(.secondary) }.width(140)
                        TableColumn("On disk", value: \.sortBytes) { r in
                            if r.bytes == 0, r.isPartial {
                                Text("Couldn't be read").foregroundStyle(.secondary)
                            } else if let b = r.bytes {
                                HStack(spacing: 4) { Text(formatBytes(b)).monospacedDigit(); if r.isPartial { Text("partial").font(.caption2).foregroundStyle(.secondary) } }
                            } else {
                                Text(model.fullDiskAccess || model.demo ? "Not read by the scan" : "Needs Full Disk Access").foregroundStyle(.secondary)
                            }
                        }.width(170)
                    }
                    .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                        if let id = ids.first, let row = rows.first(where: { $0.name == id }), model.canOpen(row) {
                            model.openFolder(model.folderPath + "/" + id)
                        }
                    }
                    if all.count > rows.count {
                        let rest = all.count - rows.count
                        Text("The \(Self.rowLimit.formatted()) largest are listed; \(rest.formatted()) smaller ones aren't. Filter by name to find one.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(16).frame(minWidth: 480)
                FolderDetail(model: model, snapshot: s, folder: rows.first { $0.name == model.selectedFolder })
                    .frame(minWidth: 280, idealWidth: 320)
            }
        }
    }

    /// The largest 200 entries, and the rest as one cell: the treemap folds slivers anyway.
    private func treemapNodes(_ entries: [FolderEntry]) -> [TreemapNode] {
        let sized = entries.filter { ($0.bytes ?? 0) > 0 }.sorted { $0.sortBytes > $1.sortBytes }
        let nodes = sized.prefix(200).map { TreemapNode(id: $0.name, label: $0.name, value: Double($0.bytes ?? 0), reclaimable: 0, color: $0.kind.color) }
        let rest = sized.dropFirst(200)
        guard !rest.isEmpty else { return nodes }
        return nodes + [TreemapNode(id: Treemap.smallerID, label: "\(rest.count.formatted()) smaller", value: Double(rest.compactMap(\.bytes).reduce(0, +)), reclaimable: 0, color: .gray, count: rest.count)]
    }

    /// Home › Library › Caches: every folder above this one opens with a click.
    private var breadcrumbs: some View {
        let parts = model.folderPath.split(separator: "/").map(String.init)
        return HStack(spacing: 4) {
            ForEach(parts.indices, id: \.self) { i in
                let name = i == 0 ? "Home" : parts[i]
                if i > 0 { Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true) }
                if i == parts.count - 1 {
                    Text(name)
                } else {
                    Button(name) { model.openFolder(parts[...i].joined(separator: "/")) }.buttonStyle(.link)
                }
            }
        }
    }

    /// For a level measured after the scan: progress, or why it wasn't listed.
    @ViewBuilder private func levelStatus(_ level: FolderLevel) -> some View {
        switch level.problem {
        case .needsFullDiskAccess?:
            Callout("macOS protects this folder: the app reads it only with Full Disk Access.") {
                Button("Open Privacy & Security…", action: FullDiskAccess.openSettings).buttonStyle(.link)
            }
        case .throughLink?:
            Callout("This folder is reached through a link now. The app doesn't follow links; scan again to see where things are.")
        case .notAFolder?:
            Callout("This isn't a folder anymore. Scan again to see what's here now.")
        case .otherVolume?:
            Callout("This is another volume. The app measures the startup disk only.")
        case .unreadable?:
            Callout("macOS didn't let the app list this folder.")
        case nil where level.isMeasuring:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(level.listing ? "Listing this folder…" : "Measured \(level.measured.formatted()) of \(level.total.formatted())…").foregroundStyle(.secondary)
            }
        case nil:
            Text("Measured when you opened it, after the scan. Owners are matched to the scan's items.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension FolderEntry {
    /// For sorting: unknown sizes last.
    var sortBytes: Int64 { bytes ?? -1 }
}

struct FolderDetail: View {
    let model: AppModel
    let snapshot: Snapshot
    let folder: FolderEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let f = folder {
                Text(f.name).font(.title3.weight(.semibold))
                Text("\(model.folderPath)/\(f.name)").font(.caption).foregroundStyle(.secondary)
                if let b = f.bytes {
                    let attributed = f.owners.map(\.bytes).reduce(0, +)
                    HStack {
                        SizeBox(value: Text(formatBytes(b)), caption: f.isPartial ? "on disk, at least (some folders inside couldn't be read)" : "on disk")
                        SizeBox(value: Text(formatBytes(attributed)), caption: "attributed to owners")
                    }
                    ForEach(f.owners, id: \.ownerID) { share in
                        if let o = snapshot.owner(share.ownerID) {
                            HStack {
                                Button(o.name) { model.show(owner: o.id) }.buttonStyle(.link)
                                Spacer()
                                Text(formatBytes(share.bytes)).monospacedDigit()
                            }
                        }
                    }
                    if f.owners.isEmpty { Callout("No owner claims this \(model.isFolder(f) ? "folder" : "file"). It counts as personal files or “Not attributed yet”.") }
                    HStack {
                        Button("Reveal in Finder") { revealInFinder("\(model.folderPath)/\(f.name)") }
                        if model.canOpen(f) { Button("Open") { model.openFolder(model.folderPath + "/" + f.name) } }
                    }
                    if model.demo, !model.canOpen(f), model.isFolder(f) {
                        Text("The sample data only goes inside Library.").font(.caption).foregroundStyle(.secondary)
                    }
                } else if model.canOpen(f) {
                    // Protected when the scan ran; readable now that Full Disk Access is on.
                    Callout("The scan couldn't read this folder. Open it to measure it now.")
                    Button("Open") { model.openFolder(model.folderPath + "/" + f.name) }
                } else {
                    Callout("macOS doesn't let the app read this folder without Full Disk Access, so its size is part of “Not attributed yet”.")
                    Button("Open Privacy & Security…", action: FullDiskAccess.openSettings)
                }
            } else {
                Text(model.folderPath == "~" ? "Home folder" : model.folderPath).font(.title3.weight(.semibold))
                Callout("Select a folder to see which owners hold space in it.")
            }
            Spacer()
        }
        .padding(16)
    }
}

struct HistoryView: View {
    @Bindable var model: AppModel
    @State private var from = 0
    @State private var to = 0
    @State private var ownerSeries: String?

    var body: some View {
        let h = model.history
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if h.hasComparison {
                    comparison(h)
                } else {
                    VStack(spacing: 6) {
                        Text("Growth history starts with your next scan").font(.headline)
                        Text("This is the first scan, so there's nothing to compare yet. Scan again after a few days of work to see what grew. A forecast appears once there are at least four weeks of scans.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(28)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.quaternary))
                }
                CleanupsLog(model: model)
            }
            .padding(20)
        }
        .onAppear { to = max(0, h.scans.count - 1); from = max(0, h.scans.count - 5) }
    }

    @ViewBuilder
    private func comparison(_ h: History) -> some View {
        let scans = h.scans
        let delta = scans[max(from, to)].used - scans[min(from, to)].used
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(from == to ? "—" : (delta >= 0 ? "+" : "") + formatBytes(delta)).font(.system(size: 34, weight: .semibold)).monospacedDigit()
            Text(from == to ? "pick two different scans to compare" : "used on the whole disk between \(label(scans[min(from, to)])) and \(label(scans[max(from, to)]))").foregroundStyle(.secondary)
        }
        if let f = h.forecast() {
            Text("Forecast, based on the scans from \(f.basedOn.lowerBound.formatted(date: .abbreviated, time: .omitted)) to \(f.basedOn.upperBound.formatted(date: .abbreviated, time: .omitted)): \(forecastText(f).lowercased()).")
                .foregroundStyle(.secondary)
        }
        let owners = Array(Set(scans.flatMap(\.owners.keys))).sorted()
        HStack {
            Text("Space used by").font(.headline)
            Picker("Series", selection: $ownerSeries) {
                Text("the whole disk").tag(String?.none)
                ForEach(owners, id: \.self) { id in Text(scans.last?.names[id] ?? id).tag(String?.some(id)) }
            }.labelsHidden().fixedSize()
        }
        // A scan where the owner couldn't be measured breaks its line: each measured run of
        // scans is its own segment, and a lone measured scan is a point.
        let points = segmented(scans.map(point))
        Chart(points, id: \.index) { p in
            LineMark(x: .value("Scan", scans[p.index].date), y: .value("GB", Double(p.value) / 1e9), series: .value("Segment", p.segment))
                .interpolationMethod(.monotone)
            if p.isAlone || p.index == from || p.index == to {
                PointMark(x: .value("Scan", scans[p.index].date), y: .value("GB", Double(p.value) / 1e9))
            }
        }
        .chartYAxisLabel("GB used per scan")
        .frame(height: 220)
        HStack {
            Text("Compare").font(.headline)
            Picker("From", selection: $from) { ForEach(scans.indices, id: \.self) { Text(label(scans[$0])).tag($0) } }.fixedSize()
            Text("with")
            Picker("To", selection: $to) { ForEach(scans.indices, id: \.self) { Text(label(scans[$0])).tag($0) } }.fixedSize()
        }
        let changes = h.changes(from: from, to: to)
        Table(changes, columns: {
            TableColumn("Owner") { (c: OwnerChange) in Text(c.name) }
            TableColumn("Change") { (c: OwnerChange) in
                Label(c.delta > 0 ? "grew \(formatBytes(c.delta))" : "shrank \(formatBytes(-c.delta))", systemImage: c.delta > 0 ? "arrow.up" : "arrow.down")
                    .foregroundStyle(c.delta > 0 ? Color.errorText : Color.successText).monospacedDigit()
            }.width(150)
            TableColumn("Last scans") { (c: OwnerChange) in
                Chart(segmented(c.series), id: \.index) { p in
                    LineMark(x: .value("i", p.index), y: .value("b", Double(p.value)), series: .value("Segment", p.segment))
                    if p.isAlone { PointMark(x: .value("i", p.index), y: .value("b", Double(p.value))).symbolSize(8) }
                }
                    .chartXAxis(.hidden).chartYAxis(.hidden).frame(width: 90, height: 20).accessibilityHidden(true)
            }.width(100)
            TableColumn("Why") { (c: OwnerChange) in Text(c.notes.joined(separator: "; ")).foregroundStyle(.secondary) }
        })
        .frame(height: CGFloat(max(changes.count, 1)) * 30 + 40)
    }

    private func label(_ s: ScanSummary) -> String { s.date.formatted(date: .abbreviated, time: .omitted) }

    /// The charted value of a scan: the whole disk, or the chosen owner (nil if unmeasured).
    private func point(_ s: ScanSummary) -> Int64? {
        guard let id = ownerSeries else { return s.used }
        return s.size(id)
    }
}

/// Every cleanup run, with its receipt. Shown in every History state.
struct CleanupsLog: View {
    @Bindable var model: AppModel
    @State private var open: Set<UUID> = []

    var body: some View {
        if !model.history.runs.isEmpty {
            Text("Cleanups").font(.headline)
            ForEach(model.history.runs) { run in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(run.started.formatted(date: .abbreviated, time: .shortened))
                        Text(run.summaryText).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(freedText(run, .mac)) freed · \(run.stillInTrash.bytesText) in the Trash · \(freedText(run, .containerDisk)) in Docker's disk")
                            .monospacedDigit().foregroundStyle(.secondary)
                        Button(open.contains(run.id) ? "Hide receipt" : "View receipt") { toggle(run.id) }.buttonStyle(.link)
                    }
                    if open.contains(run.id) { ReceiptView(model: model, run: run) }
                }
                Divider()
            }
            .onAppear { if let id = model.openRunID { open.insert(id); model.openRunID = nil } }
        }
    }

    private func toggle(_ id: UUID) { if open.contains(id) { open.remove(id) } else { open.insert(id) } }
}

/// A run's receipt, read from the full record (History keeps a compact copy).
struct ReceiptView: View {
    let model: AppModel
    let run: RunRecord
    @State private var text: String?

    var body: some View {
        Group {
            if let text {
                Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .task(id: run) { text = Receipt.text(await model.fullRun(run)) }
    }
}

struct CleanupView: View {
    @Bindable var model: AppModel

    var body: some View {
        if let s = model.snapshot, let plan = model.currentPlan {
            let acc = Accounting(s, cleaned: model.actedOn)   // only which items remain matters here
            VStack(spacing: 0) {
                List {
                    Text("Safe items are ticked for you. Probably-safe items start unticked. Review items only appear here once you've picked files in their details, and they only ever go to the Trash.")
                        .foregroundStyle(.secondary)
                    ForEach([Tier.safe, .probablySafe], id: \.self) { tier in
                        let items = s.owners.flatMap { o in o.items.filter { $0.tier == tier && $0.isAutomaticCleanup && !acc.cleaned.contains($0.id) }.map { (o, $0) } }
                        SwiftUI.Section {
                            ForEach(items, id: \.1.id) { owner, item in
                                Toggle(isOn: Binding(get: { model.selected.contains(item.id) },
                                                     set: { on in if on { model.selected.insert(item.id) } else { model.selected.remove(item.id) } })) {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text("\(owner.name) · \(item.name)")
                                            Text(commandText(item)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        if model.cleanupState.partlyCleaned[item.id] != nil {
                                            Text("partly cleaned since this scan").font(.caption).foregroundStyle(.secondary)
                                        }
                                        Text(item.action.destination?.label ?? "").font(.caption).foregroundStyle(.secondary)
                                        HStack(spacing: 2) { if item.reclaimableIsUpperBound { Text("≤") }; MeasureText(measure: item.reclaimable) }
                                            .frame(width: 90, alignment: .trailing)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        } header: {
                            HStack {
                                TierBadge(tier: tier)
                                Text(plural(items.count, "item")).foregroundStyle(.secondary)
                                Spacer()
                                Button("Select all") { items.forEach { model.selected.insert($0.1.id) } }.buttonStyle(.link)
                                Button("Select none") { items.forEach { model.selected.remove($0.1.id) } }.buttonStyle(.link)
                            }
                        }
                    }
                    SwiftUI.Section {
                        ForEach(s.owners.flatMap { o in o.items.filter { $0.action == .pickToTrash }.map { (o, $0) } }, id: \.1.id) { owner, item in
                            let n = model.picks[item.id]?.count ?? 0
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("\(owner.name) · \(item.name)")
                                    Text(n > 0 ? "\(plural(n, "file")) picked; they will go to the Trash when you run cleanup" : "Nothing picked").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(n > 0 ? "Edit picks" : "Pick files…") { model.show(owner: owner.id, item: item.id) }.buttonStyle(.link)
                            }
                        }
                    } header: {
                        HStack { TierBadge(tier: .review); Text("only what you pick in an item's details").foregroundStyle(.secondary) }
                    }
                }
                Divider()
                HStack {
                    Text("\(plural(plan.steps.count, "step")) · \(plan.expectedText(.mac)) right away, \(plan.expectedText(.trash)) after emptying the Trash, \(plan.expectedText(.containerDisk)) inside Docker's disk")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let why = model.cleanupBlocked {
                        Text(why).font(.caption).foregroundStyle(Color.warningText)
                    }
                    Button("Preview cleanup…", action: model.openPreview).buttonStyle(.borderedProminent)
                        .disabled(plan.steps.isEmpty || model.cleanupBlocked != nil).keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        }
    }

    private func commandText(_ item: Item) -> String {
        switch item.action {
        case .runOnTargets(let c, _): c.display(targets: item.targets.count, unit: item.targetUnit)
        case .runAfterRecheck(let c, _): c.display()
        case .clearFolder(let c, _, _): c.display()
        case .moveToTrash: "Move to Trash: \(plural(item.targets.count, item.targetUnit))"
        default: ""
        }
    }
}

struct CoverageView: View {
    let model: AppModel

    var body: some View {
        if let s = model.snapshot {
            // A list, not a table: details wrap instead of being cut off.
            List(s.coverage) { c in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    status(c.status).frame(width: 120, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.area).fontWeight(.medium)
                        Text(c.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if c.status == .noAccess, !model.fullDiskAccess {
                            Button("Open Privacy & Security…", action: FullDiskAccess.openSettings).buttonStyle(.link)
                        }
                    }
                    Spacer()
                    Text(c.seconds.map { String(format: "%.1f s", $0) } ?? "").monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func status(_ s: CoverageEntry.Status) -> some View {
        switch s {
        case .measured: Label { Text("Measured") } icon: { Image(systemName: "checkmark").foregroundStyle(.green) }
        case .skipped: Label("Skipped", systemImage: "minus").foregroundStyle(.secondary)
        case .noAccess: Label { Text("No access") } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        case .notMeasured: Label("Not measured", systemImage: "minus").foregroundStyle(.secondary)
        case .stopped: Label("Not finished", systemImage: "pause.circle").foregroundStyle(.secondary)
        case .failed: Label { Text("Failed") } icon: { Image(systemName: "xmark.octagon.fill").foregroundStyle(.red) }
        }
    }
}

struct WelcomeView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Text("See where your disk space went").font(.title.weight(.semibold))
            Text("macstorage measures what each tool, app and project uses, tells you what you'd really get back, and only removes things after showing you exactly what goes. It works offline and never sends anything anywhere.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 560)
            VStack(alignment: .leading, spacing: 8) {
                if model.fullDiskAccess {
                    Label { Text("**Full Disk Access is on**, so Downloads, Documents and other apps' data are included.") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                } else {
                    Label { Text("**Give it Full Disk Access** (recommended). Without it, macOS hides Downloads, Documents, Mail and other apps' data.") } icon: { Text("1.") }
                    Button("Open Privacy & Security…", action: FullDiskAccess.openSettings).buttonStyle(.link).padding(.leading, 22)
                }
                Label { Text("**Run the first scan.** It reads sizes and asks your tools what they hold. A full scan takes a few minutes; results appear as each area finishes.") } icon: { Text(model.fullDiskAccess ? "1." : "2.") }
                Label { Text("**Nothing is deleted** until you've reviewed a cleanup preview.") } icon: { Text(model.fullDiskAccess ? "2." : "3.") }
            }
            .frame(maxWidth: 520, alignment: .leading)
            if let p = model.scanning {
                ProgressView(value: Double(p.finished.count), total: Double(max(p.total, 1))) {
                    Text("Scanning \(p.running.first ?? "…")")
                }
                .frame(maxWidth: 360)
                Button("Stop scan", action: model.stopScan)
            } else {
                Button("Scan this Mac", action: model.scan).buttonStyle(.borderedProminent).controlSize(.large).disabled(model.demo)
            }
            Text("Container engines that aren't running are left alone. The app never asks for your admin password.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

