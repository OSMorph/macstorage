import StorageCore
import SwiftUI

struct CleanupSheet: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.sheet {
        case .preview(let plan): PreviewPhase(model: model, plan: plan)
        case .running(let plan, let current, let outcomes): RunningPhase(model: model, plan: plan, current: current, outcomes: outcomes)
        case .results(let run): ResultsPhase(model: model, run: run)
        case nil: EmptyView()
        }
    }
}

struct Totals: View {
    let mac: Int64, trash: Int64, docker: Int64

    var body: some View {
        HStack(spacing: 10) {
            ForEach([(mac, Destination.mac.label), (trash, Destination.trash.label), (docker, Destination.containerDisk.label)], id: \.1) { value, label in
                SizeBox(value: Text(formatBytes(value)), caption: label)
            }
        }
    }
}

struct PreviewPhase: View {
    let model: AppModel
    let plan: CleanupPlan
    @State private var confirmedPicks = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Review \(plural(plan.steps.count, "cleanup step"))").font(.title3.weight(.semibold))
                Totals(mac: plan.expected(.mac), trash: plan.expected(.trash), docker: plan.expected(.containerDisk))
            }
            .padding(20)
            Divider()
            List {
                ForEach(Tier.allCases.filter { t in plan.steps.contains { $0.item.tier == t } }, id: \.self) { tier in
                    SwiftUI.Section {
                        ForEach(plan.steps.filter { $0.item.tier == tier }) { StepPreview(step: $0) }
                    } header: {
                        HStack { TierBadge(tier: tier); Text(plural(plan.steps.filter { $0.item.tier == tier }.count, "step")).foregroundStyle(.secondary) }
                    }
                }
                if !plan.pickedSteps.isEmpty {
                    Toggle(isOn: $confirmedPicks) {
                        Text("I've checked the \(plural(plan.pickedSteps.map(\.approvedTargets.count).reduce(0, +), "file")) I picked myself (\(plan.pickedSteps.map(\.ownerName).joined(separator: ", "))). They are my own files and go to the Trash.")
                    }
                    .toggleStyle(.checkbox)
                }
            }
            Divider()
            HStack {
                Text("Before each step the app checks its list again. If anything changed, it skips that step and tells you.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !plan.pickedSteps.isEmpty, !confirmedPicks {
                    Text("Tick the confirmation for your picked files to enable Run.").font(.caption).foregroundStyle(.orange)
                }
                Button("Cancel", role: .cancel) { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Run \(plural(plan.steps.count, "step"))") { model.run(plan) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!plan.pickedSteps.isEmpty && !confirmedPicks)
            }
            .padding(16)
        }
    }
}

struct StepPreview: View {
    let step: CleanupStep
    @State private var showList = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(step.ownerName) · \(step.item.name)")
                Spacer()
                Text((step.item.reclaimableIsUpperBound ? "≤ " : "") + formatBytes(step.expectedBytes)).fontWeight(.semibold).monospacedDigit()
            }
            Text(commandLine).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .padding(6).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            if case .clearFolder(_, let root, _) = step.item.action { Text("Resolved: \(root)").font(.caption).foregroundStyle(.secondary) }
            ForEach(warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            if !step.approvedTargets.isEmpty {
                DisclosureGroup("Show exactly what this removes (\(plural(step.approvedTargets.count, step.item.targetUnit)))", isExpanded: $showList) {
                    TargetList(targets: step.approvedTargets, unit: step.item.targetUnit)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private var commandLine: String {
        switch step.item.action {
        case .runOnTargets(let c, _), .runAfterRecheck(let c, _): c.display(targets: step.approvedTargets.count, unit: step.item.targetUnit)
        case .clearFolder(let c, _, _): c.display()
        default: "Move \(plural(step.approvedTargets.count, step.item.targetUnit)) to the Trash"
        }
    }

    private var warnings: [String] {
        switch step.destination {
        case .containerDisk: ["Frees space inside Docker's disk. The disk file on your Mac shrinks when Docker trims it, not right away."]
        case .trash: ["Goes to the Trash. The space comes back when you empty it; the results offer to delete just these items."]
        case .mac: []
        }
    }
}

struct RunningPhase: View {
    let model: AppModel
    let plan: CleanupPlan
    let current: Int
    let outcomes: [StepOutcome?]
    @FocusState private var stopFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cleaning up: step \(current + 1) of \(plan.steps.count)").font(.title3.weight(.semibold))
            Text("Steps run one at a time. Stopping lets the current step finish with its real outcome.").foregroundStyle(.secondary)
            List(Array(plan.steps.enumerated()), id: \.offset) { i, step in
                HStack {
                    OutcomeIcon(outcome: outcomes[i], running: i == current && outcomes[i] == nil)
                    Text("\(step.ownerName) · \(step.item.name)")
                    Spacer()
                    if case .skipped(let why)? = outcomes[i] { Text(why).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                }
            }
            HStack {
                Text("\(outcomes.compactMap { $0 }.count) of \(plan.steps.count) done").foregroundStyle(.secondary)
                Spacer()
                Button("Stop after this step", action: model.stopRun).keyboardShortcut(.cancelAction).focused($stopFocused)
            }
        }
        .padding(20)
        .onAppear { stopFocused = true }
    }
}

struct OutcomeIcon: View {
    let outcome: StepOutcome?
    var running = false

    var body: some View {
        switch outcome {
        case .done?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
        case .skipped?: Image(systemName: "arrow.uturn.right.circle").foregroundStyle(.orange).accessibilityLabel("Skipped")
        case .failed?: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).accessibilityLabel("Failed")
        case .notRun?: Image(systemName: "minus.circle").foregroundStyle(.secondary).accessibilityLabel("Not run")
        case nil: running ? AnyView(ProgressView().controlSize(.small)) : AnyView(Image(systemName: "circle").foregroundStyle(.tertiary))
        }
    }
}

struct ResultsPhase: View {
    let model: AppModel
    let run: RunRecord
    @State private var confirmingDelete = false
    @State private var includePicked = false
    @State private var receiptURL: URL?

    var body: some View {
        let moved = run.movedToTrash
        let picked = moved.filter(\.picked), caches = moved.filter { !$0.picked }
        VStack(alignment: .leading, spacing: 12) {
            Text("Cleanup finished").font(.title3.weight(.semibold))
            Text(summary).foregroundStyle(.secondary)
            Totals(mac: run.freedOnMac, trash: run.stillInTrash, docker: run.freed(.containerDisk))
            if !moved.isEmpty, run.trashDeletions.isEmpty {
                trashBox(picked: picked, caches: caches)
            } else if let d = run.trashDeletions.last {
                Callout("Deleted \(plural(d.paths.count, "item")) (\(formatBytes(d.bytes))) from the Trash.\(d.includedPickedFiles ? "" : picked.isEmpty ? "" : " Your picked files are still in the Trash.")")
            }
            List(run.steps, id: \.step.id) { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack { OutcomeIcon(outcome: r.outcome); Text("\(r.step.ownerName) · \(r.step.item.name)"); Spacer(); Text(outcomeText(r.outcome)).foregroundStyle(.secondary) }
                    if case .skipped(let why) = r.outcome {
                        HStack {
                            Text(why).font(.caption).foregroundStyle(.orange)
                            Button("Review the new list") { model.sheet = nil; model.show(owner: ownerID(r), item: r.step.item.id) }.buttonStyle(.link).font(.caption)
                        }
                    } else if case .notRun = r.outcome {
                        Text("Not run: cleanup was stopped before this step. Nothing was changed.").font(.caption).foregroundStyle(.secondary)
                    } else if case .failed(let e) = r.outcome {
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            HStack {
                if let receiptURL {
                    Label("Saved to \(receiptURL.path(percentEncoded: false))", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
                    Button("Show in Finder") { revealInFinder(receiptURL.path) }.buttonStyle(.link).font(.caption)
                } else {
                    Button("History → Cleanups") { model.sheet = nil; model.section = .history; model.openRunID = run.id }.buttonStyle(.link)
                }
                Spacer()
                Button("Save receipt…") { receiptURL = model.saveReceipt(run) }.disabled(model.demo)
                Button("Done") { model.sheet = nil }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func trashBox(picked: [(path: String, bytes: Int64?, picked: Bool)], caches: [(path: String, bytes: Int64?, picked: Bool)]) -> some View {
        if confirmingDelete {
            let count = caches.count + (includePicked ? picked.count : 0)
            VStack(alignment: .leading, spacing: 8) {
                Text("Delete items from the Trash permanently? This can't be undone.").fontWeight(.semibold)
                if !picked.isEmpty {
                    Toggle(isOn: $includePicked) {
                        VStack(alignment: .leading) {
                            Text("Also delete my \(plural(picked.count, "picked file")). These are your own files, possibly the only copies:").fontWeight(.medium)
                            ForEach(picked, id: \.path) { Text("\($0.path) · \($0.bytes.map(formatBytes) ?? "")").font(.system(.caption, design: .monospaced)) }
                        }
                    }.toggleStyle(.checkbox)
                }
                if !caches.isEmpty {
                    DisclosureGroup("\(plural(caches.count, "rebuildable cache item"))") {
                        TargetList(targets: caches.map { Target($0.path, bytes: $0.bytes) }, unit: "item")
                    }
                }
                HStack {
                    Button("Cancel") { confirmingDelete = false }.keyboardShortcut(.cancelAction)
                    Button("Delete \(plural(count, "item")) permanently", role: .destructive) { model.deleteFromTrash(run, includePicked: includePicked) }
                        .disabled(count == 0)
                }
            }
            .padding(10).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.red.opacity(0.5)))
        } else {
            Callout("This cleanup moved \(plural(picked.count + caches.count, "item")) to the Trash. They stay there until you empty it.") {
                Button("Delete just these from the Trash…") { confirmingDelete = true }.buttonStyle(.link)
            }
        }
    }

    private var summary: String {
        let skipped = run.steps.filter { if case .skipped = $0.outcome { true } else { false } }.count
        let notRun = run.steps.filter { $0.outcome == .notRun }.count
        return "\(run.doneCount) of \(plural(run.steps.count, "step")) done" + (skipped > 0 ? ", \(skipped) skipped" : "") + (notRun > 0 ? ", \(notRun) not run" : "") + "."
    }

    private func outcomeText(_ o: StepOutcome) -> String {
        switch o {
        case .done(let b): formatBytes(b)
        case .skipped: "skipped"
        case .notRun: "not run"
        case .failed: "failed"
        }
    }

    private func ownerID(_ r: RunRecord.StepResult) -> String {
        model.snapshot?.owners.first { $0.items.contains { $0.id == r.step.item.id } }?.id ?? ""
    }
}
