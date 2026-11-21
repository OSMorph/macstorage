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
                        Tile(title: { Text(s.isPartial ? "Not scanned or attributed yet" : "Not attributed yet") }, value: formatBytes(s.unattributed), unit: "on disk",
                             note: s.isPartial ? "Includes what this stopped scan didn't reach: \(s.unfinishedAreas.filter { $0 != "Folder sizes" }.joined(separator: ", ")) and anything outside your home folder."
                                : model.fullDiskAccess || model.demo ? "Mostly outside your home folder (/Applications, /Library, /private), which this scan didn't measure."
                                : "Folders macOS hides without Full Disk Access, plus places outside your home folder this scan didn't measure.",
                             link: ("See scan coverage", { model.section = .coverage }))
                    }
                    Text("Biggest owners").font(.headline)
                    OwnerRanking(model: model, snapshot: s, accounting: acc)
                    Text("In each bar, the solid part is what cleaning up gives back on your Mac (safe and probably-safe items, right away or via the Trash) and the faded part is the rest. Space freed inside Docker's disk isn't drawn: the disk file shrinks later. On disk counts a hard-linked file once within each folder measured; blocks shared between APFS clones count in each copy, and the shared part is noted per item.")
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
        // Scaled to the disk's capacity; the segments add up to it.
        let segments: [(String, Int64, Color)] = accounting.diskSegments.filter { $0.bytes > 0 || $0.kind != nil }.map { s in
            (s.id == "unattributed" && snapshot.isPartial ? "Not scanned or attributed yet" : s.label, s.bytes,
             s.kind?.color ?? (s.id == "free" ? .clear : s.id == "other" ? .secondary.opacity(0.2) : .secondary.opacity(0.4)))
        }
        let total = Double(max(snapshot.disk.total, segments.map(\.1).reduce(0, +)))
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
            // Wraps at narrow widths instead of clipping.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), alignment: .leading)], alignment: .leading, spacing: 6) {
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
        // Lead with the largest destination; the others follow, never added to it.
        let order = Destination.allCases.sorted { r[$0] > r[$1] }
        let phrase: [Destination: String] = [.mac: "right away", .trash: "after emptying the Trash", .containerDisk: "inside Docker's disk"]
        let bound = { (d: Destination) in r.boundPrefix(d) + formatBytes(r[d]) }
        let extras = (userRun > 0 ? " \(plural(userRun, "item")) you run yourself." : "") + (unmeasured > 0 ? " \(unmeasured) not measured yet." : "")
        if r.byDestination.values.allSatisfy({ $0 == 0 }) {
            Tile(title: { TierBadge(tier: tier) }, value: "Nothing", unit: "for the app to clean", note: "No item in this tier is left for a cleanup." + extras)
        } else {
            Tile(title: { TierBadge(tier: tier) }, value: bound(order[0]), unit: phrase[order[0]]!,
                 secondary: r[order[1]] > 0 ? "+ \(bound(order[1])) \(phrase[order[1]]!)" : nil,
                 note: (r[order[2]] > 0 ? "+ \(bound(order[2])) \(phrase[order[2]]!)." : "") + extras,
                 link: action.map { ("Review cleanup", $0) })
        }
    }
}

/// Return or a double-click opens the owner, like any macOS table.
struct OwnerRanking: View {
    let model: AppModel
    let snapshot: Snapshot
    let accounting: Accounting
    @State private var selection: Owner.ID?

    var body: some View {
        let top = Array(snapshot.owners.sorted { $0.hostOnDisk > $1.hostOnDisk }.prefix(12))
        let maxValue = Double(max(top.first?.hostOnDisk ?? 1, 1))
        Table(top, selection: $selection) {
            TableColumn("Owner") { o in
                Label { Text(o.name) } icon: { RoundedRectangle(cornerRadius: 2).fill(o.kind.color).frame(width: 8, height: 8) }
            }
            TableColumn("Kind") { o in Text(o.kind.label).foregroundStyle(.secondary) }.width(130)
            TableColumn("On disk") { o in MeasureText(measure: o.onDiskMeasure) }.width(80)
            TableColumn("") { o in
                let r = min(o.hostOnDisk, accounting.reclaimable(owner: o).onHost)
                GeometryReader { g in
                    HStack(spacing: 1) {
                        Rectangle().fill(o.kind.color).frame(width: g.size.width * Double(r) / maxValue)
                        Rectangle().fill(o.kind.color.opacity(0.35)).frame(width: g.size.width * Double(max(0, o.hostOnDisk - r)) / maxValue)
                    }
                }.frame(height: 10).accessibilityHidden(true)
            }
            TableColumn("Reclaimable") { o in ReclaimableText(label: accounting.reclaimableLabel(owner: o)) }.width(170)
        }
        .frame(height: CGFloat(top.count) * 26 + 32)
        .contextMenu(forSelectionType: Owner.ID.self) { _ in } primaryAction: { ids in
            if let id = ids.first { model.show(owner: id) }
        }
    }
}
