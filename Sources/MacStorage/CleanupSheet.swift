import StorageCore
import SwiftUI

struct CleanupSheet: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.sheet {
            case .preview(let plan): PreviewPhase(model: model, plan: plan)
            case .running(let plan, let current, let outcomes): RunningPhase(model: model, plan: plan, current: current, outcomes: outcomes)
            case .results(let run): ResultsPhase(model: model, run: run)
            case nil: EmptyView()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Three figures side by side, one per destination: never added together.
struct Totals: View {
    let values: [(value: String, caption: String, detail: String?)]

    /// Before a run: what each destination is expected to get back.
    init(plan: CleanupPlan) {
        values = Destination.allCases.map { (formatBytes(plan.expected($0), upperBound: plan.isUpperBound($0)), $0.label, nil) }
    }

    init(_ values: [(value: String, caption: String, detail: String?)]) { self.values = values }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(values, id: \.caption) { v in
                VStack(alignment: .leading, spacing: 2) {
                    Text(v.value).font(.title3.weight(.semibold)).monospacedDigit()
                    Text(v.caption).font(.caption).foregroundStyle(.secondary)
                    if let detail = v.detail { Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
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
                Totals(plan: plan)
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
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                // The confirmation sits next to Run, where it's needed.
                if !plan.pickedSteps.isEmpty {
                    Toggle(isOn: $confirmedPicks) {
                        Text("I've checked the \(plural(plan.pickedSteps.map(\.approvedTargets.count).reduce(0, +), "file")) I picked myself (\(plan.pickedSteps.map(\.ownerName).joined(separator: ", "))). They are my own files and go to the Trash.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(.checkbox)
                }
                HStack {
                    Text("Before each step the app checks its list again. If anything changed, it skips that step and tells you.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .cancel) { model.sheet = nil }.keyboardShortcut(.cancelAction)
                    Button("Run \(plural(plan.steps.count, "step"))") { model.run(plan) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!plan.pickedSteps.isEmpty && !confirmedPicks)
                        .help(!plan.pickedSteps.isEmpty && !confirmedPicks ? "Tick the confirmation for your picked files first." : "")
                }
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
                Text(formatBytes(step.expectedBytes, upperBound: step.item.reclaimableIsUpperBound)).fontWeight(.semibold).monospacedDigit()
            }
            Text(commandLine).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .padding(6).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            if case .clearFolder(_, let root, _) = step.item.action { Text("Resolved: \(root)").font(.caption).foregroundStyle(.secondary) }
            ForEach(warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.warningText) }
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
        case .runOnTargets(let c, _): c.display(targets: step.approvedTargets.count, unit: step.item.targetUnit)
        case .runAfterRecheck(let c, _): c.display() + "\n# only if a fresh listing matches the \(plural(step.approvedTargets.count, step.item.targetUnit)) below"
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
        let finished = outcomes.compactMap { $0 }.count
        VStack(alignment: .leading, spacing: 12) {
            Text("Cleaning up: step \(min(current + 1, plan.steps.count)) of \(plan.steps.count)").font(.title3.weight(.semibold))
            Text("Steps run one at a time. Stopping lets the current step finish with its real outcome.").foregroundStyle(.secondary)
            List(Array(plan.steps.enumerated()), id: \.offset) { i, step in
                HStack {
                    OutcomeIcon(outcome: outcomes[i], running: i == current && outcomes[i] == nil)
                    Text("\(step.ownerName) · \(step.item.name)")
                    Spacer()
                    switch outcomes[i] {
                    case .skipped(let why)?: Text(why).font(.caption).foregroundStyle(Color.warningText).lineLimit(2)
                    case let o? where o.didRun: Text(o.measured.map(formatBytes) ?? "≈ \(formatBytes(step.expectedBytes))").monospacedDigit().foregroundStyle(.secondary)
                    case .failed?: Text("failed").foregroundStyle(Color.errorText)
                    default: Text(formatBytes(step.expectedBytes, upperBound: step.item.reclaimableIsUpperBound)).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
            }
            HStack {
                Text("\(finished) of \(plural(plan.steps.count, "step")) finished").foregroundStyle(.secondary)
                Spacer()
                if model.stopping {
                    ProgressView().controlSize(.small)
                    Text("Stopping after this step…").foregroundStyle(.secondary)
                } else {
                    Button("Stop after this step", action: model.stopRun).keyboardShortcut(.cancelAction).focused($stopFocused)
                }
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
        case .partial?: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).accessibilityLabel("Partly done")
        case .skipped?: Image(systemName: "arrow.uturn.right.circle").foregroundStyle(.orange).accessibilityLabel("Skipped")
        case .failed?: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).accessibilityLabel("Failed")
        case .notRun?: Image(systemName: "minus.circle").foregroundStyle(.secondary).accessibilityLabel("Not run")
        case nil: running ? AnyView(ProgressView().controlSize(.small).accessibilityLabel("Running")) : AnyView(Image(systemName: "circle").foregroundStyle(.tertiary).accessibilityLabel("Waiting"))
        }
    }
}

struct ResultsPhase: View {
    let model: AppModel
    let run: RunRecord
    @State private var confirmingDelete = false
    @State private var includePicked = false
    @State private var receiptURL: URL?
    @State private var receiptError: String?
    @State private var deleting = false
    @State private var confirmingClose = false

    var body: some View {
        let inTrash = run.stillInTrash
        VStack(alignment: .leading, spacing: 12) {
            Text("Cleanup finished").font(.title3.weight(.semibold))
            Text(summary).foregroundStyle(.secondary)
            Totals(totals(inTrash))
            Text("Sizes are measured after each step where the tool allows it; “predicted” marks the rest.").font(.caption).foregroundStyle(.secondary)
            if let error = model.unsavedRuns[run.id] {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.warningText)
                    Button("Try again") { Task { await model.persist(run) } }
                }
            }
            if !inTrash.isEmpty { trashBox(inTrash) }
            ForEach(run.trashDeletions.indices, id: \.self) { i in
                let d = run.trashDeletions[i]
                Callout("Deleted \(plural(d.deleted.count, "item")) (\(formatBytes(d.bytes))) from the Trash."
                        + (d.refused.isEmpty ? "" : " \(plural(d.refused.count, "item")) had been moved, replaced or restored, so the app left them alone."))
            }
            List(run.steps, id: \.step.id) { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        OutcomeIcon(outcome: r.outcome)
                        Text("\(r.step.ownerName) · \(r.step.item.name)")
                        Spacer()
                        Text(outcomeText(r)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    switch r.outcome {
                    case .skipped(let why):
                        HStack {
                            Text(why + " It's unticked until you scan again.").font(.caption).foregroundStyle(Color.warningText)
                            Button("View the approved list") { model.sheet = nil; model.show(owner: ownerID(r), item: r.step.item.id) }.buttonStyle(.link).font(.caption)
                        }
                    case .partial(_, let problems):
                        ForEach(problems, id: \.self) { Text($0).font(.caption).foregroundStyle(Color.warningText) }
                    case .notRun(let why):
                        Text(why + " Nothing was changed.").font(.caption).foregroundStyle(.secondary)
                    case .failed(let e):
                        Text(e).font(.caption).foregroundStyle(Color.errorText)
                    case .done:
                        EmptyView()
                    }
                    if !r.leftAlone.isEmpty {
                        DisclosureGroup("\(plural(r.leftAlone.count, "item")) left alone") {
                            ForEach(r.leftAlone, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        }
                        .font(.caption)
                    }
                }
            }
            HStack {
                if let receiptURL {
                    Label("Saved to \(receiptURL.path(percentEncoded: false))", systemImage: "checkmark").font(.caption).foregroundStyle(Color.successText)
                    Button("Show in Finder") { revealInFinder(receiptURL.path) }.buttonStyle(.link).font(.caption)
                } else if let receiptError {
                    Label("The receipt couldn't be saved: \(receiptError)", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Color.warningText)
                } else {
                    Button("Open in History") { model.sheet = nil; model.section = .history; model.openRunID = run.id }.buttonStyle(.link)
                }
                Spacer()
                Button("Show receipt file") {
                    Task {
                        switch await model.receipt(run) {
                        case .success(let url): receiptURL = url; receiptError = nil
                        case .failure(let error): receiptError = error.localizedDescription
                        }
                    }
                }
                .disabled(model.demo).help(model.demo ? "Demo mode doesn't write files." : "Every cleanup's receipt is saved automatically.")
                Button("Done") { if model.unsavedRuns[run.id] != nil { confirmingClose = true } else { model.sheet = nil } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .confirmationDialog("This cleanup's record isn't saved", isPresented: $confirmingClose) {
            Button("Try saving again") { Task { await model.persist(run) } }
            Button("Close without saving", role: .destructive) { model.sheet = nil }
        } message: {
            Text("It stays in History until you quit, but won't be there after a relaunch.")
        }
    }

    /// After the run: what each destination got, measured where possible, next to the prediction.
    private func totals(_ inTrash: [TrashEntry]) -> [(value: String, caption: String, detail: String?)] {
        func detail(_ d: Destination) -> String? {
            let predicted = run.predicted(d), unmeasured = run.unmeasured(d)
            guard predicted > 0 else { return nil }
            return "predicted \(formatBytes(predicted))" + (unmeasured > 0 ? "; \(formatBytes(unmeasured)) of it not re-measured" : "")
        }
        let inTrashBytes = inTrash.map(\.bytes).reduce(0, +)
        return [
            (formatBytes(run.freedOnMac), run.deletedFromTrash > 0 ? "Freed on your Mac, including \(formatBytes(run.deletedFromTrash)) deleted from the Trash" : "Freed on your Mac", detail(.mac)),
            (formatBytes(inTrashBytes), "Now in the Trash (\(plural(inTrash.count, "item"))), freed when you empty it", detail(.trash)),
            (formatBytes(run.freed(.containerDisk)), "Freed inside Docker's disk; the disk file shrinks later", detail(.containerDisk)),
        ]
    }

    @ViewBuilder
    private func trashBox(_ entries: [TrashEntry]) -> some View {
        let picked = entries.filter(\.picked), caches = entries.filter { !$0.picked }
        if confirmingDelete {
            let count = caches.count + (includePicked ? picked.count : 0)
            let bytes = caches.map(\.bytes).reduce(0, +) + (includePicked ? picked.map(\.bytes).reduce(0, +) : 0)
            VStack(alignment: .leading, spacing: 8) {
                Text("Delete items from the Trash permanently? This can't be undone.").fontWeight(.semibold)
                if !picked.isEmpty {
                    Toggle(isOn: $includePicked) {
                        VStack(alignment: .leading) {
                            Text("Also delete my \(plural(picked.count, "picked file")) (\(formatBytes(picked.map(\.bytes).reduce(0, +)))). These are your own files, possibly the only copies:").fontWeight(.medium)
                            ForEach(picked, id: \.landed) { Text("\($0.original) · \(formatBytes($0.bytes))").font(.system(.caption, design: .monospaced)) }
                        }
                    }.toggleStyle(.checkbox)
                }
                if !caches.isEmpty {
                    DisclosureGroup("\(plural(caches.count, "rebuildable cache item")) (\(formatBytes(caches.map(\.bytes).reduce(0, +))))") {
                        TargetList(targets: caches.map { Target($0.original, bytes: $0.bytes) }, unit: "item")
                    }
                }
                HStack {
                    Button("Cancel") { confirmingDelete = false }.keyboardShortcut(.cancelAction)
                    Button(count == 0 ? "Nothing selected" : "Delete \(plural(count, "item")) (\(formatBytes(bytes))) permanently", role: .destructive) {
                        deleting = true
                        Task { await model.deleteFromTrash(run, includePicked: includePicked); deleting = false; confirmingDelete = false }
                    }
                    .disabled(count == 0 || deleting)
                    if deleting { ProgressView().controlSize(.small) }
                }
            }
            .padding(10).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.red.opacity(0.5)))
        } else {
            Callout("\(plural(entries.count, "item")) from this cleanup \(entries.count == 1 ? "is" : "are") in the Trash. They stay there until you empty it.") {
                Button("Delete just these from the Trash…") { confirmingDelete = true }.buttonStyle(.link)
            }
        }
    }

    private var summary: String {
        let skipped = run.steps.filter { if case .skipped = $0.outcome { true } else { false } }.count
        let notRun = run.steps.filter { if case .notRun = $0.outcome { true } else { false } }.count
        let failed = run.steps.filter { if case .failed = $0.outcome { true } else { false } }.count
        return run.progressText + (skipped > 0 ? ", \(skipped) skipped" : "")
            + (failed > 0 ? ", \(failed) failed" : "") + (notRun > 0 ? ", \(notRun) not run" : "") + "."
    }

    /// "16.2 GB measured · predicted 16.7 GB", or the prediction alone when it couldn't be measured.
    private func outcomeText(_ r: RunRecord.StepResult) -> String {
        let predicted = formatBytes(r.step.expectedBytes, upperBound: r.step.item.reclaimableIsUpperBound)
        switch r.outcome {
        case .done(let m), .partial(let m, _): return m.map { "\(formatBytes($0)) measured · predicted \(predicted)" } ?? "\(predicted) predicted, not re-measured"
        case .skipped: return "skipped"
        case .notRun: return "not run"
        case .failed: return "failed"
        }
    }

    private func ownerID(_ r: RunRecord.StepResult) -> String {
        model.snapshot?.owners.first { $0.items.contains { $0.id == r.step.item.id } }?.id ?? ""
    }
}
