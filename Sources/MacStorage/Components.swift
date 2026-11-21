import AppKit
import StorageCore
import SwiftUI
import UniformTypeIdentifiers

extension OwnerKind {
    var color: Color {
        switch self {
        case .developerTools: Color(red: 0.16, green: 0.47, blue: 0.84)
        case .apps: Color(red: 0.92, green: 0.41, blue: 0.20)
        case .personalFiles: Color(red: 0.11, green: 0.69, blue: 0.48)
        case .system: Color.gray
        }
    }
}

extension Tier {
    var symbol: String {
        switch self {
        case .safe: "checkmark.circle.fill"
        case .probablySafe: "checkmark.circle"
        case .review: "exclamationmark.triangle.fill"
        case .leaveAlone: "lock.fill"
        case .notRemovable: "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .safe: .green
        case .probablySafe: .teal
        case .review: .orange
        case .leaveAlone, .notRemovable: .secondary
        }
    }
}

/// A tier is always shown with its icon and its name, never by color alone. The tint is
/// on the icon; the text stays at full contrast.
struct TierBadge: View {
    let tier: Tier

    var body: some View {
        Label { Text(tier.label).foregroundStyle(.primary) } icon: { Image(systemName: tier.symbol).foregroundStyle(tier.tint) }
            .font(.caption)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(.quaternary))
    }
}

extension Color {
    /// Warning text that stays readable on light backgrounds (orange alone is about 2.5:1).
    static let warningText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .systemOrange : NSColor(srgbRed: 0.62, green: 0.29, blue: 0, alpha: 1)
    })
    /// Error text, same reasoning.
    static let errorText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .systemRed : NSColor(srgbRed: 0.70, green: 0.10, blue: 0.10, alpha: 1)
    })
    /// Success text, same reasoning.
    static let successText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .systemGreen : NSColor(srgbRed: 0.10, green: 0.45, blue: 0.18, alpha: 1)
    })
}


func formatBytes(_ b: Int64) -> String { ByteFormat.string(b) }

extension Destination {
    /// Short tag next to a number, so destinations stay distinguishable without adding them up.
    var shortLabel: String {
        switch self {
        case .mac: "now"
        case .trash: "via Trash"
        case .containerDisk: "in Docker's disk"
        }
    }
}

/// "Full in about 10 months", or days when it's closer than a month.
func forecastText(_ f: Forecast) -> String {
    f.daysUntilFull < 45 ? "Full in about \(plural(max(1, Int(f.daysUntilFull)), "day")) at this rate"
        : "Full in about \(plural(Int((f.daysUntilFull / 30).rounded()), "month")) at this rate"
}

/// A size that may be unknown: never collapses to a dash.
struct MeasureText: View {
    let measure: Measure
    var unknown = "Unknown"

    var body: some View {
        switch measure {
        case .bytes(let b): Text(formatBytes(b)).monospacedDigit()
        case .atLeast(let b): Text("≥ " + formatBytes(b)).monospacedDigit().help("At least: the scan stopped early or some folders couldn't be read.")
        case .notMeasured: Text("Not measured").foregroundStyle(.secondary)
        case .unknown: Text(unknown).foregroundStyle(.secondary)
        }
    }
}

struct ReclaimableText: View {
    let label: ReclaimableLabel

    var body: some View {
        switch label {
        case .bytes(let r):
            // Never added together: each destination is its own figure.
            HStack(spacing: 6) {
                ForEach(Destination.allCases.filter { r[$0] > 0 }, id: \.self) { d in
                    HStack(spacing: 2) {
                        Text(r.boundPrefix(d) + formatBytes(r[d])).monospacedDigit()
                        Text(d.shortLabel).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        case .unknown: Text("Unknown").foregroundStyle(.secondary)
        case .cleaned: Text("Cleaned since this scan").foregroundStyle(.secondary)
        case .partlyCleaned: Text("Partly cleaned since this scan").foregroundStyle(.secondary)
        case .none: Text("0 bytes").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Treemap

struct TreemapNode: Identifiable {
    var id: String
    var label: String
    var value: Double
    var reclaimable: Double
    var color: Color
    /// How many entries the cell stands for (more than one for a "smaller" cell).
    var count = 1
}

/// A squarified treemap. Cells are buttons with their own accessibility labels; slivers
/// too small to label or click are folded into one "smaller" cell.
struct Treemap: View {
    let nodes: [TreemapNode]
    var selected: String?
    let onSelect: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            let cells = Self.layout(Self.fold(nodes, area: geo.size.width * geo.size.height), in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                ForEach(cells, id: \.node.id) { cell in
                    Group {
                        if cell.node.id == Self.smallerID {
                            // Not a control: the small entries are in the table below.
                            CellView(node: cell.node, size: cell.rect.size, isSelected: false)
                                .help("\(cell.node.label): each is listed in the table below.")
                                .accessibilityLabel("\(cell.node.label), \(formatBytes(Int64(cell.node.value))) together, listed in the table below")
                        } else {
                            Button { onSelect(cell.node.id) } label: {
                                CellView(node: cell.node, size: cell.rect.size, isSelected: cell.node.id == selected)
                            }
                            .buttonStyle(.plain)
                            .help("\(cell.node.label): \(formatBytes(Int64(cell.node.value)))")
                            .accessibilityLabel("\(cell.node.label), \(formatBytes(Int64(cell.node.value)))" + (cell.node.reclaimable > 0 ? ", \(formatBytes(Int64(cell.node.reclaimable))) reclaimable on your Mac" : ""))
                            .accessibilityAddTraits(cell.node.id == selected ? .isSelected : [])
                        }
                    }
                    .frame(width: max(0, cell.rect.width - 2), height: max(0, cell.rect.height - 2))
                    .offset(x: cell.rect.minX + 1, y: cell.rect.minY + 1)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Treemap. The table below has the same data.")
    }

    static let smallerID = "__smaller"

    /// Folds nodes that would be smaller than about 40×40 points into one cell.
    static func fold(_ nodes: [TreemapNode], area: Double) -> [TreemapNode] {
        let live = nodes.filter { $0.value > 0 }
        let total = live.map(\.value).reduce(0, +)
        guard total > 0, area > 0 else { return [] }
        // One pass each way: a folder can have a hundred thousand entries.
        let threshold = total * 1_600 / area
        // A "smaller" cell passed in joins the folded one, so there's only ever one.
        let isSmall = { (n: TreemapNode) in n.value < threshold || n.id == smallerID }
        let small = live.filter(isSmall)
        guard small.count > 1 else { return live }
        let count = small.map(\.count).reduce(0, +)
        return live.filter { !isSmall($0) }
            + [TreemapNode(id: smallerID, label: "\(count.formatted()) smaller", value: small.map(\.value).reduce(0, +), reclaimable: 0, color: .gray, count: count)]
    }

    /// Squarified layout (Bruls, Huizing, van Wijk).
    static func layout(_ nodes: [TreemapNode], in rect: CGRect) -> [(node: TreemapNode, rect: CGRect)] {
        let total = nodes.map(\.value).reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return [] }
        let scale = rect.width * rect.height / total
        var items = nodes.sorted { $0.value > $1.value }.map { ($0, $0.value * scale) }
        var out: [(TreemapNode, CGRect)] = []
        var free = rect, row: [(TreemapNode, Double)] = []

        func worst(_ r: [(TreemapNode, Double)], _ side: Double) -> Double {
            guard !r.isEmpty else { return .infinity }
            let s = r.map(\.1).reduce(0, +), mx = r.map(\.1).max()!, mn = r.map(\.1).min()!
            return max(side * side * mx / (s * s), s * s / (side * side * mn))
        }
        func place(_ r: [(TreemapNode, Double)]) {
            let s = r.map(\.1).reduce(0, +)
            if free.width >= free.height {
                let w = s / free.height
                var y = free.minY
                for (n, a) in r { out.append((n, CGRect(x: free.minX, y: y, width: w, height: a / w))); y += a / w }
                free = CGRect(x: free.minX + w, y: free.minY, width: free.width - w, height: free.height)
            } else {
                let h = s / free.width
                var x = free.minX
                for (n, a) in r { out.append((n, CGRect(x: x, y: free.minY, width: a / h, height: h))); x += a / h }
                free = CGRect(x: free.minX, y: free.minY + h, width: free.width, height: free.height - h)
            }
        }
        while !items.isEmpty {
            let side = min(free.width, free.height)
            if row.isEmpty || worst(row + [items[0]], side) <= worst(row, side) { row.append(items.removeFirst()) } else { place(row); row = [] }
        }
        if !row.isEmpty { place(row) }
        return out
    }

    struct CellView: View {
        let node: TreemapNode
        let size: CGSize
        let isSelected: Bool

        var body: some View {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).fill(node.color)
                if node.reclaimable > 0 {
                    // Hatched band for the reclaimable share, anchored to the bottom.
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Hatch().fill(.white.opacity(0.45)).frame(height: size.height * min(1, node.reclaimable / node.value))
                    }.clipShape(RoundedRectangle(cornerRadius: 4))
                }
                if size.width > 74, size.height > 40 {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(node.label).fontWeight(.semibold).lineLimit(1)
                        Text(formatBytes(Int64(node.value))).font(.caption).monospacedDigit()
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                    .padding(5)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isSelected ? Color.primary : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
    }

    struct Hatch: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            var x = -rect.height
            while x < rect.width {
                p.move(to: CGPoint(x: x, y: rect.maxY)); p.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                p.addLine(to: CGPoint(x: x + rect.height + 3, y: rect.minY)); p.addLine(to: CGPoint(x: x + 3, y: rect.maxY))
                x += 7
            }
            return p
        }
    }
}

// MARK: - Target list

/// Exactly what a step removes: filterable, shown in full on request, exportable.
struct TargetList: View {
    let targets: [Target]
    let unit: String
    @State private var filter = ""
    @State private var showAll = false
    @State private var exportError: String?

    private var matches: [Target] { filter.isEmpty ? targets : targets.filter { $0.id.localizedCaseInsensitiveContains(filter) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Filter \(plural(targets.count, unit))", text: $filter).textFieldStyle(.roundedBorder)
            let shown = showAll ? matches : Array(matches.prefix(300))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(shown, id: \.id) { t in
                        HStack {
                            Text(t.id).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                                .help(t.id)
                                .contextMenu {
                                    Button("Copy Path") { copyToPasteboard(t.id) }
                                    Button("Reveal in Finder") { revealInFinder(t.id) }
                                }
                            Spacer()
                            if let b = t.bytes { Text(formatBytes(b)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                        }
                    }
                    if matches.isEmpty { Text("Nothing matches “\(filter)”.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .frame(maxHeight: 160)
            HStack(spacing: 12) {
                if matches.count > shown.count {
                    Button("Show all \(plural(matches.count, filter.isEmpty ? unit : "match", filter.isEmpty ? nil : "matches"))") { showAll = true }.buttonStyle(.link)
                }
                Button("Export list…") { export() }.buttonStyle(.link)
                Text("Export always writes all \(plural(targets.count, unit)).").font(.caption).foregroundStyle(.secondary)
            }.font(.caption)
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .alert("The list couldn't be exported", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "macstorage-\(unit.replacingOccurrences(of: " ", with: "-"))s.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try targets.map { [$0.id, $0.bytes.map(formatBytes) ?? ""].joined(separator: "\t") }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = error.localizedDescription
        }
    }
}

func revealInFinder(_ path: String?) {
    guard let path else { return }
    let expanded = path.hasPrefix("~") ? NSHomeDirectory() + path.dropFirst() : path
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
