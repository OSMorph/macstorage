import AppKit
import Foundation
import StorageCore

/// Lets the UI stop a cleanup between steps. The step in progress always finishes,
/// so its real outcome is recorded.
public final class StopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    public init() {}
    public func stop() { lock.withLock { stopped = true } }
    public var isStopped: Bool { lock.withLock { stopped } }
}

/// Runs an approved cleanup plan and records exactly what happened, target by target.
///
/// Guarantees:
/// - Commands run as argument arrays, only while what they act on is still what the user
///   reviewed: the same engine and image for each Docker tag, the same listing for
///   re-checked tools, the same folder with no new files for folder-clearing tools.
/// - Only files inside the home folder are moved to the Trash, and only if each is still
///   the object the scan saw (same device, inode and modification time). Symlinked parent
///   folders are resolved before the containment check.
/// - Every command the app starts is recorded, including one that fails; a step that
///   fails or only partly succeeds stops the run.
/// - Freed space is re-measured where it can be; otherwise the record says it wasn't.
///
/// Each check and the action after it are separate calls, so another process of the same
/// user could still change things in between. That process could delete the files anyway,
/// so this isn't treated as a boundary worth more machinery.
public struct CleanupExecutor: Sendable {
    let tools: any ToolRunning
    let home: String

    public init(tools: any ToolRunning, home: String = NSHomeDirectory()) {
        self.tools = tools
        self.home = home
    }

    /// Recorded for the step in progress whenever the run is journaled, in case the app
    /// quits before it finishes.
    public static let interrupted = "The app quit while this step was running, so its outcome wasn't recorded. Scan again to see what's left."

    public static let notJournaled = "The cleanup record couldn't be saved, so the app stopped before changing anything else."

    /// Runs the plan step by step. `journal` receives the record so far before each step
    /// (the step about to run marked as interrupted), so it can be saved in case the app
    /// quits. When it returns false (the record couldn't be saved), no further step starts.
    public func run(_ plan: CleanupPlan, stop: StopSignal, progress: @Sendable (Int, StepOutcome?) -> Void = { _, _ in },
                    journal: @Sendable (RunRecord) -> Bool = { _ in true }) async -> RunRecord {
        let id = UUID(), started = Date()
        var results: [RunRecord.StepResult] = []
        var haltReason: String?
        for (i, step) in plan.steps.enumerated() {
            if let reason = haltReason ?? (stop.isStopped ? "Cleanup was stopped before this step." : nil) {
                results.append(.init(step: step, outcome: .notRun(reason: reason)))
                continue
            }
            let pending = plan.steps[i...].enumerated().map { n, s in
                RunRecord.StepResult(step: s, outcome: n == 0 ? .failed(error: Self.interrupted) : .notRun(reason: "The app quit before this step started."))
            }
            guard journal(RunRecord(id: id, started: started, finished: Date(), steps: results + pending)) else {
                haltReason = Self.notJournaled
                results.append(.init(step: step, outcome: .notRun(reason: Self.notJournaled)))
                continue
            }
            progress(i, nil)
            let result = await perform(step, previewTime: plan.previewTime)
            results.append(result)
            progress(i, result.outcome)
            if result.outcome.stopsRun { haltReason = "Not started because an earlier step failed or only partly succeeded." }
        }
        return RunRecord(id: id, started: started, finished: Date(), steps: results)
    }

    func perform(_ step: CleanupStep, previewTime: Date) async -> RunRecord.StepResult {
        if let problem = await scopeProblem(step) { return .init(step: step, outcome: .skipped(reason: problem)) }
        switch step.item.action {
        case .runOnTargets(let command, _):
            let before = await usage(step)
            let result = await execute(step, batches(command, step.approvedTargets.map(\.id)), tool: command.tool)
            return await remeasured(result, before: before)
        case .runAfterRecheck(let command, _):
            guard let now = await currentTargets(step), now == Set(step.approvedTargets.map(\.id)) else {
                return .init(step: step, outcome: .skipped(reason: "The list changed since the preview (or couldn't be listed again)."))
            }
            let before = await usage(step)
            let result = await execute(step, [command.resolvedArguments(previewTime: previewTime)], tool: command.tool)
            return await remeasured(result, before: before)
        case .clearFolder(let command, let root, _):
            return await clearFolder(step, command, root: root)
        case .moveToTrash, .pickToTrash:
            if let app = step.item.appBundleID.flatMap(RunningApps.matching) {
                return .init(step: step, outcome: .skipped(reason: "\(app) is running. Quit it and run this step again."))
            }
            return await moveToTrash(step)
        default:
            return .init(step: step, outcome: .failed(error: "This item can't be cleaned by the app."))
        }
    }

    // MARK: Scope

    /// Why the step no longer acts on what the user reviewed, or nil if it still does.
    private func scopeProblem(_ step: CleanupStep) async -> String? {
        if case .dockerEngine(let engineID)? = step.item.scopeGuard {
            guard let context = Self.dockerContext(step.item),
                  let out = try? await tools.run("docker", context + ["info", "--format", "{{.ID}}"], timeout: .seconds(20)), out.succeeded,
                  out.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == engineID else {
                return "The Docker context no longer reaches the engine you reviewed, or the engine isn't running."
            }
        }
        if step.item.kind == .dockerUnusedImages, !(await imagesUnchanged(step)) {
            return "An image tag now points at a different image than the one you reviewed, or an image is gone."
        }
        return nil
    }

    /// True when every approved tag or ID still names the image the scan saw.
    private func imagesUnchanged(_ step: CleanupStep) async -> Bool {
        guard let context = Self.dockerContext(step.item) else { return false }
        for batch in stride(from: 0, to: step.approvedTargets.count, by: 500).map({ Array(step.approvedTargets[$0..<min($0 + 500, step.approvedTargets.count)]) }) {
            guard let out = try? await tools.run("docker", context + ["image", "inspect", "--format", "{{.Id}}"] + batch.map(\.id), timeout: .seconds(120)),
                  out.succeeded else { return false }
            let ids = out.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard ids == batch.map({ $0.fingerprint ?? "" }) else { return false }
        }
        return true
    }

    /// `--context <name>` from a Docker item's command.
    static func dockerContext(_ item: Item) -> [String]? {
        guard let args = command(of: item)?.arguments, args.first == "--context", args.count > 1 else { return nil }
        return Array(args.prefix(2))
    }

    /// Clears a tool's folder only if it's still the folder the scan saw, holding nothing
    /// the user didn't review.
    private func clearFolder(_ step: CleanupStep, _ command: Command, root: String) async -> RunRecord.StepResult {
        func skip(_ why: String) -> RunRecord.StepResult { .init(step: step, outcome: .skipped(reason: why)) }
        guard await currentRoot(step.item) == root else { return skip("The tool now points at a different folder than the one you reviewed.") }
        guard case .folder(let scanned)? = step.item.scopeGuard, let now = FileSizes.directoryIdentity(root), now.isSameObject(as: scanned) else {
            return skip("The folder was replaced since the scan.")
        }
        let real = FileSizes.realPath(root) ?? root
        let (current, before) = await offload { FileSizes.manifest(real) }
        guard before.isComplete else { return skip("The folder couldn't be listed completely again.") }
        // A new name, or a name now holding a different object, wasn't reviewed. An approved
        // file the tool rewrote in place (an index, a trim stamp) is still the one reviewed.
        let approved = Dictionary(step.approvedTargets.map { ($0.id, $0.identity) }, uniquingKeysWith: { a, _ in a })
        let unreviewed = current.filter { t in
            guard let seen = approved[t.id], let seen, let now = t.identity else { return true }
            return !now.isSameObject(as: seen)
        }.count
        guard unreviewed == 0 else {
            return skip("\(plural(unreviewed, "file")) appeared in the folder or were replaced after you reviewed it.")
        }
        var result = await execute(step, [command.arguments], tool: command.tool)
        let after = await offload { () -> Int64? in
            guard FileSizes.identity(real) != nil else { return 0 }   // the tool removed the folder itself
            let size = FileSizes.measure(real)
            return size.isComplete ? size.privateBytes : nil
        }
        result.outcome = Self.withMeasured(result.outcome, after.map { max(0, before.privateBytes - $0) })
        return result
    }

    // MARK: Commands

    private func batches(_ command: Command, _ ids: [String]) -> [[String]] {
        stride(from: 0, to: ids.count, by: 500).map { command.arguments + ids[$0..<min($0 + 500, ids.count)] }
    }

    /// Runs each invocation in turn and records every one that started, with its failure.
    /// A failure after earlier invocations succeeded is a partial result.
    private func execute(_ step: CleanupStep, _ invocations: [[String]], tool: String) async -> RunRecord.StepResult {
        var executed: [String] = []
        for (n, args) in invocations.enumerated() {
            let line = ([tool] + args).joined(separator: " ")
            let problem: String
            do {
                let out = try await tools.run(tool, args, timeout: .seconds(1_800))
                if out.status == 0, !out.timedOut { executed.append(line); continue }
                problem = out.timedOut ? "Timed out after 30 minutes and was stopped." : Self.describe(out)
                executed.append(line + "   [failed: \(problem)]")
            } catch {
                problem = error.localizedDescription   // never started
            }
            let label = invocations.count > 1 ? "Batch \(n + 1) of \(invocations.count): \(problem)" : problem
            return .init(step: step, outcome: n > 0 ? .partial(measured: nil, problems: [label]) : .failed(error: label), executed: executed)
        }
        return .init(step: step, outcome: .done(measured: nil), executed: executed)
    }

    /// The last few lines the tool wrote to stderr, or its exit status.
    static func describe(_ out: ToolOutput) -> String {
        let lines = out.stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(3)
        return lines.isEmpty ? "Exit status \(out.status)." : String(lines.joined(separator: " / ").prefix(400))
    }

    /// Fills in the measured bytes for a command step from usage before and after.
    private func remeasured(_ result: RunRecord.StepResult, before: Int64?) async -> RunRecord.StepResult {
        var result = result
        let after = before == nil ? nil : await usage(result.step)
        let freed = before.flatMap { b in after.map { max(0, b - $0) } }
        result.outcome = Self.withMeasured(result.outcome, freed)
        if case .failed(let error) = result.outcome, freed == nil, !result.executed.isEmpty, result.step.approvedTargets.count > 1 {
            result.outcome = .failed(error: error + " The tool may have removed some targets before it failed; scan again to see what's left.")
        }
        return result
    }

    /// The outcome with the re-measured bytes. A failed command that still freed space was
    /// partly done.
    static func withMeasured(_ outcome: StepOutcome, _ freed: Int64?) -> StepOutcome {
        switch outcome {
        case .done: .done(measured: freed)
        case .partial(_, let problems): .partial(measured: freed, problems: problems)
        case .failed(let error) where (freed ?? 0) > 0: .partial(measured: freed, problems: [error])
        default: outcome
        }
    }

    /// Space the step's targets occupy now, measured the way that suits the tool.
    private func usage(_ step: CleanupStep) async -> Int64? {
        switch step.item.kind {
        case .nixDeadPaths:
            return SystemProvider.volumeUsed("/nix")
        case .dockerBuildCache, .dockerUnusedImages:
            guard let context = Self.dockerContext(step.item),
                  let out = try? await tools.run("docker", context + ["system", "df", "--format", "{{json .}}"], timeout: .seconds(120)),
                  out.succeeded else { return nil }
            let type = step.item.kind == .dockerBuildCache ? "Build Cache" : "Images"
            return Parse.dockerSystemDF(out.stdout).first { $0.type == type }?.size
        case .homebrewOldVersions, .simulatorsUnavailable:
            // The approved targets' real size now (nil if any walk is incomplete).
            // Simulators are listed by UDID, each a folder in the item's folder.
            let folder = step.item.kind == .simulatorsUnavailable ? step.item.path : nil
            let paths = step.approvedTargets.map { t in folder.map { $0 + "/" + t.id } ?? expand(t.id) }
            return await offload { () -> Int64? in
                var total: Int64 = 0
                for path in paths where FileSizes.identity(path) != nil {
                    let size = FileSizes.measure(path)
                    guard size.isComplete else { return nil }
                    total += size.privateBytes
                }
                return total
            }
        default:
            return nil
        }
    }

    public static func command(of item: Item) -> Command? {
        switch item.action {
        case .runOnTargets(let c, _), .runAfterRecheck(let c, _), .clearFolder(let c, _, _): c
        default: nil
        }
    }

    // MARK: Trash

    /// Moves each approved path to the Trash, target by target. Targets that are no longer
    /// what the user approved are left alone and listed; that isn't a failure.
    private func moveToTrash(_ step: CleanupStep) async -> RunRecord.StepResult {
        var moved: [TrashEntry] = [], problems: [String] = [], leftAlone: [String] = []
        var allMeasured = true
        let realHome = FileSizes.realPath(home) ?? home
        for target in step.approvedTargets {
            let path = expand(target.id)
            guard FileSizes.resolvingAncestors(path).hasPrefix(realHome + "/") else {
                leftAlone.append("\(target.id): outside your home folder.")
                continue
            }
            guard let identity = FileSizes.identity(path) else {
                leftAlone.append("\(target.id): already gone.")
                continue
            }
            guard let expected = target.identity,
                  FileSizes.isDirectory(path) ? identity.isSameObject(as: expected) : identity == expected else {
                leftAlone.append("\(target.id): replaced or changed since the scan.")
                continue
            }
            if step.item.kind == .gitBuildOutput,
               let why = await GitProvider.ineligibility(tools, checkout: (path as NSString).deletingLastPathComponent) {
                leftAlone.append("\(target.id): \(why)")
                continue
            }
            let size = await offload { FileSizes.measure(path) }
            // An incomplete walk can't give an exact size: use the scan's figure and say so.
            if !size.isComplete { allMeasured = false }
            let bytes = size.isComplete ? size.privateBytes : target.bytes ?? size.privateBytes
            do {
                var landed: NSURL?
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &landed)
                let landedPath = (landed as URL?)?.path ?? ""
                moved.append(TrashEntry(original: target.id, landed: landedPath, identity: FileSizes.identity(landedPath),
                                        bytes: bytes, picked: step.item.tier == .review))
            } catch {
                problems.append("\(target.id): \(error.localizedDescription)")
            }
        }
        let measured: Int64? = allMeasured ? moved.map(\.bytes).reduce(0, +) : nil
        // When nothing moved, nothing irreversible happened: skipped, so later steps still run.
        let outcome: StepOutcome = if moved.isEmpty {
            .skipped(reason: problems.isEmpty ? "Nothing on the approved list was still as you reviewed it."
                     : "Nothing could be moved to the Trash: \(problems.joined(separator: " "))")
        } else if problems.isEmpty {
            .done(measured: measured)
        } else {
            .partial(measured: measured, problems: problems)
        }
        return .init(step: step, outcome: outcome, trashed: moved, leftAlone: leftAlone)
    }

    /// Permanently deletes entries a run put in the Trash. Each must still be inside the
    /// Trash (with symlinked parents resolved) and still be the same object; anything else
    /// is refused and returned as such.
    public static func deleteFromTrash(_ entries: [TrashEntry]) -> (deleted: [TrashEntry], refused: [String]) {
        let trashURL = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let trashPath = (trashURL ?? URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")).path
        let trash = FileSizes.realPath(trashPath) ?? trashPath
        var deleted: [TrashEntry] = [], refused: [String] = []
        for entry in entries {
            // Same rule as moving: a folder is the same object even if Finder added a .DS_Store.
            guard FileSizes.resolvingAncestors(entry.landed).hasPrefix(trash + "/"),
                  let identity = FileSizes.identity(entry.landed), let expected = entry.identity,
                  FileSizes.isDirectory(entry.landed) ? identity.isSameObject(as: expected) : identity == expected,
                  (try? FileManager.default.removeItem(atPath: entry.landed)) != nil else {
                refused.append(entry.original)
                continue
            }
            deleted.append(entry)
        }
        return (deleted, refused)
    }

    // MARK: Re-checks

    private func expand(_ path: String) -> String { path.hasPrefix("~") ? home + path.dropFirst() : path }

    /// Lists a re-checked step's targets again, the same way the scan did. nil when the
    /// listing failed: a failed re-check never counts as "unchanged".
    private func currentTargets(_ step: CleanupStep) async -> Set<String>? {
        switch step.item.kind {
        case .dockerBuildCache:
            guard let context = Self.dockerContext(step.item), let args = Self.command(of: step.item)?.arguments,
                  let i = args.firstIndex(of: "--builder"), args.indices.contains(i + 1),
                  let out = try? await tools.run("docker", context + ["buildx", "du", "--builder", args[i + 1], "--verbose"], timeout: .seconds(120)),
                  out.succeeded else { return nil }
            return Set(Parse.buildxRecords(out.stdout).filter(\.reclaimable).map(\.id))
        case .homebrewOldVersions:
            guard let out = try? await tools.run("brew", ["cleanup", "-n"], timeout: .seconds(300)), out.succeeded else { return nil }
            let listing = Parse.brewCleanup(out.stdout)
            guard listing.unrecognized.isEmpty else { return nil }   // it would do more than the list shows
            return Set(listing.targets.map { $0.id.hasPrefix(home) ? "~" + $0.id.dropFirst(home.count) : $0.id })
        default:
            return nil
        }
    }

    /// Asks the tool where its cache is now, to confirm a clear-folder step still targets the reviewed folder.
    private func currentRoot(_ item: Item) async -> String? {
        let query: (String, [String])? = switch item.kind {
        case .goModuleCache: ("go", ["env", "GOMODCACHE"])
        case .goBuildCache: ("go", ["env", "GOCACHE"])
        case .npmCache: ("npm", ["config", "get", "cache"])   // `npm cache clean` empties its _cacache folder
        case .uvCache: ("uv", ["cache", "dir"])
        case .pipCache: ("pip3", ["cache", "dir"])
        default: nil
        }
        guard let query, let out = try? await tools.run(query.0, query.1), out.succeeded,
              let reported = out.stdout.split(separator: "\n").first.map({ $0.trimmingCharacters(in: .whitespaces) }) else { return nil }
        return reported + (LanguageCachesProvider.clearedSubfolder[item.kind].map { "/" + $0 } ?? "")
    }
}

/// Finds a running app that a cache belongs to. A cache folder is named after the app's
/// bundle ID ("com.example.App") or after the app or its vendor ("Google", "JetBrains").
public enum RunningApps {
    /// The name of a running app the cache `key` belongs to, if any.
    public static func matching(_ key: String) -> String? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular || $0.activationPolicy == .accessory }
        return apps.first { matches(key, bundleID: $0.bundleIdentifier, name: $0.localizedName) }.map { $0.localizedName ?? key }
    }

    static func matches(_ key: String, bundleID: String?, name: String?) -> Bool {
        let key = key.lowercased()
        guard let bundleID = bundleID?.lowercased() else { return false }
        if key.contains(".") { return bundleID == key || bundleID.hasPrefix(key + ".") }
        // A plain folder name: the app's name, or one component of its bundle ID.
        return name?.lowercased() == key || bundleID.split(separator: ".").contains { $0 == key }
    }
}
