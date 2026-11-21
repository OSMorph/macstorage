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
        values = Destination.allCases.map { (plan.expectedText($0), $0.label, nil) }
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
                Text(step.expectedText).fontWeight(.semibold).monospacedDigit()
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
            if model.journalFailed {
                Label("The cleanup record couldn't be saved, so the app stopped before changing anything else.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Color.warningText)
            }
            List(Array(plan.steps.enumerated()), id: \.offset) { i, step in
                HStack {
                    OutcomeIcon(outcome: outcomes[i], running: i == current && outcomes[i] == nil)
                    Text("\(step.ownerName) · \(step.item.name)")
                    Spacer()
                    switch outcomes[i] {
                    case .skipped(let why)?: Text(why).font(.caption).foregroundStyle(Color.warningText).lineLimit(2)
                    case let o? where o.didRun: Text(o.measured.map(formatBytes) ?? "≈ \(formatBytes(step.expectedBytes))").monospacedDigit().foregroundStyle(.secondary)
                    case .failed?: Text("failed").foregroundStyle(Color.errorText)
                    default: Text(step.expectedText).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
            }
            HStack {
                Text("\(finished) of \(plural(plan.steps.count, "step")) finished").foregroundStyle(.secondary)
                Spacer()
                if model.stopping {
                    ProgressView().controlSize(.small)
                    Text(model.quitting ? "Quitting after this step, once the cleanup is recorded…" : "Stopping after this step…").foregroundStyle(.secondary)
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
    /// A done step that left some approved targets alone reads as partly done.
    var leftSome = false

    var body: some View {
        switch outcome {
        case .done? where leftSome: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).accessibilityLabel("Partly done: some items left alone")
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
            Text("Sizes are measured after each step where the tool allows it. Predictions cover only the steps that ran; skipped and not-run steps freed nothing.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.unsavedRuns[run.id] {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.warningText)
                    Button("Try again") { Task { await model.persist(run) } }
                }
            }
            if !inTrash.isEmpty { trashBox(inTrash) }
            ForEach(run.trashDeletions.indices, id: \.self) { i in
                let d = run.trashDeletions[i]
                Callout("Deleted \(plural(d.deleted.count, "item")) (\(d.deleted.bytesText)) from the Trash."
                        + (d.refused.isEmpty ? "" : " \(plural(d.refused.count, "item")) had been moved, replaced or restored, so the app left them alone."))
            }
            List(run.steps, id: \.step.id) { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        OutcomeIcon(outcome: r.outcome, leftSome: !r.leftAlone.isEmpty)
                        Text("\(r.step.ownerName) · \(r.step.item.name)")
                        Spacer()
                        Text(outcomeText(r)).monospacedDigit().foregroundStyle(.secondary)
                            .help(r.outcome.measured != nil ? r.step.item.kind.measurementNote.map { "Measured \($0), so other activity can affect it." } ?? "" : "")
                    }
                    switch r.outcome {
                    case .skipped(let why):
                        HStack {
                            Text(why + skipAdvice(r)).font(.caption).foregroundStyle(Color.warningText)
                            if case .clearFolder = r.step.item.action {
                                RefreshButton(model: model, itemID: r.step.item.id)
                            } else {
                                Button("View the approved list") { model.sheet = nil; model.show(owner: ownerID(r), item: r.step.item.id) }.buttonStyle(.link).font(.caption)
                            }
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
            let predicted = run.predicted(d)
            return predicted > 0 ? "predicted \(run.predictedText(d)) for the steps that ran" : nil
        }
        let deleted = run.trashDeletions.flatMap(\.deleted)
        return [
            (freedText(run, .mac), deleted.isEmpty ? "Freed on your Mac" : "Freed on your Mac, including \(deleted.bytesText) deleted from the Trash", detail(.mac)),
            (inTrash.bytesText, "Now in the Trash (\(plural(inTrash.count, "item"))), freed when you empty it", detail(.trash)),
            (freedText(run, .containerDisk), "Freed inside Docker's disk; the disk file shrinks later", detail(.containerDisk)),
        ]
    }

    @ViewBuilder
    private func trashBox(_ entries: [TrashEntry]) -> some View {
        let picked = entries.filter(\.picked), caches = entries.filter { !$0.picked }
        if confirmingDelete {
            let count = caches.count + (includePicked ? picked.count : 0)
            let chosen = caches + (includePicked ? picked : [])
            VStack(alignment: .leading, spacing: 8) {
                Text("Delete items from the Trash permanently? This can't be undone.").fontWeight(.semibold)
                if !picked.isEmpty {
                    Toggle(isOn: $includePicked) {
                        VStack(alignment: .leading) {
                            Text("Also delete my \(plural(picked.count, "picked file")) (\(picked.bytesText)). These are your own files, possibly the only copies:").fontWeight(.medium)
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 1) {
                                    ForEach(picked, id: \.landed) { Text("\($0.original) · \([$0].bytesText)").font(.system(.caption, design: .monospaced)) }
                                }
                            }
                            .frame(maxHeight: 90)
                        }
                    }.toggleStyle(.checkbox)
                }
                if !caches.isEmpty {
                    DisclosureGroup("\(plural(caches.count, "rebuildable cache item")) (\(caches.bytesText))") {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(caches, id: \.landed) { Text("\($0.original) · \([$0].bytesText)").font(.system(.caption, design: .monospaced)) }
                            }
                        }
                        .frame(maxHeight: 120)
                    }
                }
                HStack {
                    Button("Cancel") { confirmingDelete = false }.keyboardShortcut(.cancelAction)
                    Button(count == 0 ? "Nothing selected" : "Delete \(plural(count, "item")) (\(chosen.bytesText)) permanently", role: .destructive) {
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

    /// What happens to a skipped step next, by why it was skipped.
    private func skipAdvice(_ r: RunRecord.StepResult) -> String {
        switch r.step.item.action {
        case .clearFolder: " List it again to review what's there now."
        case .moveToTrash where r.leftAlone.isEmpty, .pickToTrash where r.leftAlone.isEmpty: " It stays ticked; run cleanup again when that's resolved."
        default: " It's unticked until you scan again."
        }
    }

    private var summary: String { run.summaryText }

    /// "16.2 GB measured · predicted 16.7 GB", or the prediction alone when it couldn't be measured.
    private func outcomeText(_ r: RunRecord.StepResult) -> String {
        let predicted = r.step.expectedText
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

/// What a run freed in a destination, never showing an unmeasured result as a measured
/// zero: "Not re-measured" when nothing could be measured, "≥ X" when only part could.
func freedText(_ run: RunRecord, _ d: Destination) -> String { run.freedText(d) }

/// Lists a skipped cache folder again so it can be reviewed and run without a full scan.
struct RefreshButton: View {
    let model: AppModel
    let itemID: String
    @State private var state: String?

    var body: some View {
        if let state {
            Text(state).font(.caption).foregroundStyle(.secondary)
        } else {
            Button("List it again and tick it") {
                state = "Listing…"
                Task { state = await model.refresh(itemID) ? "Listed again and ticked: review it in the next preview." : "Couldn't list it completely. Scan again." }
            }
            .buttonStyle(.link).font(.caption)
        }
    }
}
