import StorageCore
import SwiftUI

struct OwnersView: View {
    @Bindable var model: AppModel

    var body: some View {
        if let s = model.snapshot, let acc = model.accounting {
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    breadcrumb(s)
                    if let owner = model.selectedOwnerID.flatMap(s.owner) {
                        Treemap(nodes: owner.items.map { node($0, owner.kind, acc) }, selected: model.selectedItemID) { model.selectedItemID = $0 }
                            .frame(height: 150)
                        ItemTable(model: model, owner: owner, accounting: acc)
                    } else {
                        Treemap(nodes: s.owners.map { o in
                            TreemapNode(id: o.id, label: o.name, value: Double(o.onDisk), reclaimable: Double(acc.reclaimable(owner: o).byDestination.values.reduce(0, +)), color: o.kind.color)
                        }, selected: nil) { model.show(owner: $0) }
                        .frame(height: 300)
                        OwnerTable(model: model, snapshot: s, accounting: acc)
                    }
                }
                .padding(16)
                .frame(minWidth: 480)
                Inspector(model: model, snapshot: s, accounting: acc)
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            }
        }
    }

    private func node(_ item: Item, _ kind: OwnerKind, _ acc: Accounting) -> TreemapNode {
        let reclaim = item.tier.isCleanable && !acc.cleaned.contains(item.id) ? Double(item.reclaimable.bytes ?? 0) : 0
        return TreemapNode(id: item.id, label: item.name, value: Double(item.onDisk.bytes ?? 0), reclaimable: reclaim, color: kind.color)
    }

    private func breadcrumb(_ s: Snapshot) -> some View {
        HStack {
            if let owner = model.selectedOwnerID.flatMap(s.owner) {
                Button("All owners") { model.selectedOwnerID = nil; model.selectedItemID = nil }.buttonStyle(.link)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                Text(owner.name)
                Spacer()
                Text(owner.note ?? owner.location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("All owners")
                Spacer()
                Label("hatched = reclaimable", systemImage: "line.diagonal").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct OwnerTable: View {
    let model: AppModel
    let snapshot: Snapshot
    let accounting: Accounting
    @State private var selection: Owner.ID?
    @State private var order = [KeyPathComparator(\Owner.onDisk, order: .reverse)]

    var body: some View {
        Table(snapshot.owners.sorted(using: order), selection: $selection, sortOrder: $order) {
            TableColumn("Owner", value: \.name) { o in
                Label { Text(o.name) } icon: { RoundedRectangle(cornerRadius: 2).fill(o.kind.color).frame(width: 8, height: 8) }
            }
            TableColumn("Kind", value: \.kind.label) { o in Text(o.kind.label).foregroundStyle(.secondary) }.width(130)
            TableColumn("On disk", value: \.onDisk) { o in Text(formatBytes(o.onDisk)).monospacedDigit() }.width(90)
            TableColumn("Reclaimable") { o in ReclaimableText(label: accounting.reclaimableLabel(owner: o)) }.width(170)
        }
        .contextMenu(forSelectionType: Owner.ID.self) { _ in } primaryAction: { ids in
            if let id = ids.first { model.show(owner: id) }
        }
    }
}

struct ItemTable: View {
    @Bindable var model: AppModel
    let owner: Owner
    let accounting: Accounting

    var body: some View {
        Table(owner.items, selection: $model.selectedItemID) {
            TableColumn("Item") { i in Text(i.name) }
            TableColumn("On disk") { i in MeasureText(measure: i.onDisk) }.width(100)
            TableColumn("Reclaimable") { i in
                if accounting.cleaned.contains(i.id) {
                    Text("Cleaned today").foregroundStyle(.secondary)
                } else if i.tier == .leaveAlone || i.tier == .notRemovable {
                    Text("0 bytes").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 4) {
                        if i.reclaimableIsUpperBound { Text("at most") }
                        MeasureText(measure: i.reclaimable)
                        if i.action.destination == .containerDisk { Text("in Docker's disk").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }.width(170)
            TableColumn("Recommendation") { i in TierBadge(tier: i.tier) }.width(130)
        }
    }
}

struct Inspector: View {
    @Bindable var model: AppModel
    let snapshot: Snapshot
    let accounting: Accounting
    @State private var showTargets = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let owner = model.selectedOwnerID.flatMap(snapshot.owner),
                   let item = owner.items.first(where: { $0.id == model.selectedItemID }) {
                    details(owner, item)
                } else {
                    Text("All owners").font(.title3.weight(.semibold))
                    Text("\(plural(snapshot.owners.count, "owner")) · \(formatBytes(snapshot.owners.map(\.onDisk).reduce(0, +))) attributed").foregroundStyle(.secondary)
                    Callout("Pick an owner in the map or the list (Return opens it) to see what it's made of, the recommendation, and the exact command or action.")
                    Callout("\(formatBytes(snapshot.unattributed)) not attributed yet: space on the Data volume no owner accounts for, mostly because this scan didn't look outside your home folder.") {
                        Button("See scan coverage") { model.section = .coverage }.buttonStyle(.link)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: model.selectedItemID) { showTargets = false }
    }

    @ViewBuilder
    private func details(_ owner: Owner, _ item: Item) -> some View {
        Text(item.name).font(.title3.weight(.semibold))
        Text("\(owner.name) · \(owner.kind.label)").foregroundStyle(.secondary)
        if let runID = model.cleaned[item.id] {
            Callout("Cleaned today. The on-disk size shown is from the scan before the cleanup; scan again to re-measure.") {
                Button("View its receipt") { model.section = .history; model.openRunID = runID }.buttonStyle(.link)
            }
        } else {
            TierBadge(tier: item.tier)
            HStack(spacing: 8) {
                SizeBox(value: MeasureText(measure: item.onDisk), caption: item.sharedBytes.map { "on disk (+ \(formatBytes($0)) shared with other files)" } ?? "on disk")
                SizeBox(value: reclaimValue(item), caption: reclaimCaption(item))
            }
            Text(item.explanation).fixedSize(horizontal: false, vertical: true)
            if let basis = item.basis { Text(basis).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            ActionBox(item: item)
            if item.action == .pickToTrash {
                PickerList(model: model, item: item)
            } else if !item.targets.isEmpty {
                Button(showTargets ? "Hide the list" : "Show all \(plural(item.targets.count, item.targetUnit))") { showTargets.toggle() }
                if showTargets { TargetList(targets: item.targets, unit: item.targetUnit) }
            }
            HStack {
                if let path = item.path { Button("Reveal in Finder") { revealInFinder(path) } }
            }
            if item.isAutomaticCleanup, let d = item.action.destination {
                Toggle(isOn: Binding(get: { model.selected.contains(item.id) },
                                     set: { on in if on { model.selected.insert(item.id) } else { model.selected.remove(item.id) } })) {
                    HStack { Text("Include in cleanup"); Spacer(); Text(d.label).font(.caption).foregroundStyle(.secondary) }
                }
                .toggleStyle(.checkbox)
                .padding(8).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            }
        }
        Text(owner.location).font(.caption).foregroundStyle(.secondary)
    }

    private func reclaimValue(_ item: Item) -> some View {
        Group {
            if item.action == .pickToTrash {
                Text(formatBytes(pickedBytes(item))).monospacedDigit()
            } else if item.tier == .leaveAlone || item.tier == .notRemovable {
                Text("0 bytes").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 2) { if item.reclaimableIsUpperBound { Text("≤") }; MeasureText(measure: item.reclaimable) }
            }
        }
    }

    private func reclaimCaption(_ item: Item) -> String {
        if item.action == .pickToTrash { return "in what you picked, after emptying the Trash" }
        if item.tier == .leaveAlone || item.tier == .notRemovable { return "not removable" }
        return item.action.destination?.label ?? "depends on what you decide"
    }

    private func pickedBytes(_ item: Item) -> Int64 {
        let ids = model.picks[item.id] ?? []
        return item.targets.filter { ids.contains($0.id) }.compactMap(\.bytes).reduce(0, +)
    }
}

/// What the app would run, or what the user has to do, for an item.
struct ActionBox: View {
    let item: Item

    var body: some View {
        switch item.action {
        case .runOnTargets(let c, _):
            command("When you run cleanup, the app runs:", c.display(targets: item.targets.count, unit: item.targetUnit))
        case .runAfterRecheck(let c, _):
            command("When you run cleanup, the app runs:", c.display())
            Text("Only if a fresh listing still matches the \(plural(item.targets.count, item.targetUnit)) below.").font(.caption).foregroundStyle(.secondary)
        case .clearFolder(let c, let root, _):
            command("When you run cleanup, the app runs:", c.display())
            Text("Resolved: \(root)").font(.caption).foregroundStyle(.secondary)
        case .moveToTrash:
            command("When you run cleanup, the app moves to the Trash:", plural(item.targets.count, item.targetUnit) + (item.path.map { " in \($0)" } ?? ""))
        case .userRunsCommand(let c, let admin):
            command(admin ? "Needs admin rights, so the app never runs it. Copy it into Terminal:" : "The app never runs this. Check the list, then copy the command and run it yourself:", c)
            Button("Copy command") { copyToPasteboard(c) }
        case .userActsInApp(let text):
            Callout(text)
        case .pickToTrash:
            Text("Pick what to move to the Trash:").font(.caption).foregroundStyle(.secondary)
        case .none:
            EmptyView()
        }
    }

    private func command(_ caption: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .padding(6).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// The user's own files: picked one by one, never in bulk.
struct PickerList: View {
    @Bindable var model: AppModel
    let item: Item

    var body: some View {
        let removed = model.removedPicks[item.id] ?? []
        let rows = item.targets.filter { !removed.contains($0.id) }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows, id: \.id) { t in
                HStack {
                    Toggle(isOn: binding(t.id)) { Text((t.id as NSString).lastPathComponent) }.toggleStyle(.checkbox)
                    Spacer()
                    Button("Reveal") { revealInFinder(t.id) }.buttonStyle(.link).font(.caption)
                    Text(t.bytes.map(formatBytes) ?? "").monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                Divider()
            }
            if rows.isEmpty { Text("Nothing left to pick here.").foregroundStyle(.secondary).padding(.vertical, 4) }
        }
        .padding(8).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { model.picks[item.id]?.contains(id) ?? false },
                set: { on in if on { model.picks[item.id, default: []].insert(id) } else { model.picks[item.id]?.remove(id) } })
    }
}

struct SizeBox<V: View>: View {
    let value: V
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            value.font(.title3.weight(.semibold))
            Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}

struct Callout<Extra: View>: View {
    let text: String
    @ViewBuilder var extra: Extra

    init(_ text: String, @ViewBuilder extra: () -> Extra) {
        self.text = text
        self.extra = extra()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).fixedSize(horizontal: false, vertical: true)
            extra
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension Callout where Extra == EmptyView {
    init(_ text: String) { self.init(text) { EmptyView() } }
}
