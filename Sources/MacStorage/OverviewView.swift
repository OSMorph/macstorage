import StorageCore
import SwiftUI

struct OverviewView: View {
    let model: AppModel

    var body: some View {
        if let s = model.snapshot, let acc = model.accounting {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hero(s)
                    DiskBar(snapshot: s, accounting: acc)
                    HStack(alignment: .top, spacing: 12) {
                        TierTile(tier: .safe, accounting: acc) { model.section = .cleanup }
                        TierTile(tier: .probablySafe, accounting: acc, action: nil)
                        Tile(title: { TierBadge(tier: .review) }, value: formatBytes(acc.reviewOnDisk), unit: "on disk",
                             note: "Your own data. Nothing estimated: only you can decide what goes.")
                        Tile(title: { Text("Not attributed yet") }, value: formatBytes(s.unattributed), unit: "on disk",
                             note: model.fullDiskAccess || model.demo ? "Mostly outside your home folder (/Applications, /Library, /private), which this scan didn't measure."
                                : "Folders macOS hides without Full Disk Access, plus places outside your home folder this scan didn't measure.",
                             link: ("See scan coverage", { model.section = .coverage }))
                    }
                    Text("Biggest owners").font(.headline)
                    OwnerRanking(model: model, snapshot: s, accounting: acc)
                    Text("In each bar, the solid part is reclaimable (safe and probably-safe items) and the faded part is the rest. On disk counts blocks shared between copies (APFS clones, hard links) once.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
            }
        }
    }

    private func hero(_ s: Snapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(formatBytes(s.disk.used)).font(.system(size: 34, weight: .semibold)).monospacedDigit()
            Text("used of \(formatBytes(s.disk.total))").foregroundStyle(.secondary)
            Text("· \(formatBytes(s.disk.free)) free, plus \(formatBytes(s.disk.purgeable)) macOS can purge on its own").foregroundStyle(.tertiary)
            Spacer()
            if let f = model.history.forecast() {
                Button(forecastText(f)) { model.section = .history }.buttonStyle(.link)
            }
        }
    }
}

struct DiskBar: View {
    let snapshot: Snapshot
    let accounting: Accounting

    var body: some View {
        let byKind = accounting.onDiskByKind
        let segments: [(String, Int64, Color)] = OwnerKind.allCases.map { ($0.label, byKind[$0, default: 0], $0.color) }
            + [("Not attributed yet", snapshot.unattributed, .secondary.opacity(0.35)), ("Free", snapshot.disk.free, .clear)]
        let total = Double(segments.map(\.1).reduce(0, +))
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(segments, id: \.0) { name, value, color in
                        RoundedRectangle(cornerRadius: 3).fill(color)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.quaternary, lineWidth: color == .clear ? 1 : 0))
                            .frame(width: max(0, geo.size.width * Double(value) / max(total, 1) - 2))
                            .help("\(name): \(formatBytes(value))")
                    }
                }
            }
            .frame(height: 28)
            .accessibilityElement()
            .accessibilityLabel("Disk usage: " + segments.map { "\($0.0) \(formatBytes($0.1))" }.joined(separator: ", "))
            HStack(spacing: 14) {
                ForEach(segments, id: \.0) { name, value, color in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(color).overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.quaternary)).frame(width: 10, height: 10)
                        Text(name).foregroundStyle(.secondary)
                        Text(formatBytes(value)).fontWeight(.semibold).monospacedDigit()
                    }
                }
            }
            .font(.callout)
        }
    }
}

struct Tile<Title: View>: View {
    @ViewBuilder var title: Title
    var value: String
    var unit: String
    var secondary: String? = nil
    var note: String
    var link: (String, () -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            title
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.title2.weight(.semibold)).monospacedDigit()
                Text(unit).foregroundStyle(.secondary)
            }
            if let secondary { Text(secondary).font(.callout.weight(.medium)).monospacedDigit() }
            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let link { Button(link.0, action: link.1).buttonStyle(.link).font(.caption) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }
}

/// Safe and Probably safe: right away and after the Trash at the same weight, Docker's disk apart.
struct TierTile: View {
    let tier: Tier
    let accounting: Accounting
    let action: (() -> Void)?

    var body: some View {
        let r = accounting.reclaimable(tier: tier)
        let userRun = accounting.userRunItems(tier: tier).count
        let unmeasured = accounting.unmeasuredCount(tier: tier)
        Tile(title: { TierBadge(tier: tier) }, value: formatBytes(r[.mac]), unit: "right away",
             secondary: "+ \(formatBytes(r[.trash])) after emptying the Trash",
             note: "+ \(formatBytes(r[.containerDisk])) inside Docker's disk."
                + (userRun > 0 ? " \(plural(userRun, "item")) you run yourself." : "")
                + (unmeasured > 0 ? " \(unmeasured) not measured yet." : ""),
             link: action.map { ("Review cleanup", $0) })
    }
}

/// Return or a double-click opens the owner, like any macOS table.
struct OwnerRanking: View {
    let model: AppModel
    let snapshot: Snapshot
    let accounting: Accounting
    @State private var selection: Owner.ID?

    var body: some View {
        let top = Array(snapshot.owners.sorted { $0.onDisk > $1.onDisk }.prefix(12))
        let maxValue = Double(max(top.first?.onDisk ?? 1, 1))
        Table(top, selection: $selection) {
            TableColumn("Owner") { o in
                Label { Text(o.name) } icon: { RoundedRectangle(cornerRadius: 2).fill(o.kind.color).frame(width: 8, height: 8) }
            }
            TableColumn("Kind") { o in Text(o.kind.label).foregroundStyle(.secondary) }.width(130)
            TableColumn("On disk") { o in Text(formatBytes(o.onDisk)).monospacedDigit() }.width(80)
            TableColumn("") { o in
                let r = accounting.reclaimable(owner: o).byDestination.values.reduce(0, +)
                GeometryReader { g in
                    HStack(spacing: 1) {
                        Rectangle().fill(o.kind.color).frame(width: g.size.width * Double(r) / maxValue)
                        Rectangle().fill(o.kind.color.opacity(0.35)).frame(width: g.size.width * Double(max(0, o.onDisk - r)) / maxValue)
                    }
                }.frame(height: 10).accessibilityHidden(true)
            }
            TableColumn("Reclaimable") { o in ReclaimableText(label: accounting.reclaimableLabel(owner: o)) }.width(170)
        }
        .frame(height: CGFloat(top.count) * 28 + 32)
        .contextMenu(forSelectionType: Owner.ID.self) { _ in } primaryAction: { ids in
            if let id = ids.first { model.show(owner: id) }
        }
    }
}
