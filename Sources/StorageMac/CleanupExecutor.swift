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
/// - Commands run as argument arrays on the approved targets, or after re-checking scope.
/// - Only files inside the home folder are moved to the Trash, and only if each is still
///   the object the scan saw (same device, inode and modification time). Symlinked parent
///   folders are resolved before the containment check.
/// - A step that fails or only partly succeeds stops the run.
/// - Freed space is re-measured where it can be; otherwise the record says it wasn't.
///
/// The check and the move are separate system calls, so a file swapped in between by
/// another process of the same user could still be moved. That process could delete it
/// anyway, so this isn't treated as a boundary worth more machinery.
public struct CleanupExecutor: Sendable {
    let tools: any ToolRunning
    let home: String

    public init(tools: any ToolRunning, home: String = NSHomeDirectory()) {
        self.tools = tools
        self.home = home
    }

    public func run(_ plan: CleanupPlan, stop: StopSignal, progress: @Sendable (Int, StepOutcome?) -> Void = { _, _ in }) async -> RunRecord {
        let started = Date()
        var results: [RunRecord.StepResult] = []
        var haltReason: String?
        for (i, step) in plan.steps.enumerated() {
            if let reason = haltReason ?? (stop.isStopped ? "Cleanup was stopped before this step." : nil) {
                results.append(.init(step: step, outcome: .notRun(reason: reason)))
                continue
            }
            progress(i, nil)
            let result = await perform(step, previewTime: plan.previewTime)
            results.append(result)
            progress(i, result.outcome)
            if result.outcome.stopsRun { haltReason = "Not started because an earlier step failed." }
        }
        return RunRecord(started: started, finished: Date(), steps: results)
    }

    func perform(_ step: CleanupStep, previewTime: Date) async -> RunRecord.StepResult {
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
            guard await currentRoot(step.item) == root else {
                return .init(step: step, outcome: .skipped(reason: "The tool now points at a different folder than the one you reviewed."))
            }
            let before = FileSizes.measure(root).privateBytes
            var result = await execute(step, [command.arguments], tool: command.tool)
            if case .done = result.outcome { result.outcome = .done(measured: max(0, before - FileSizes.measure(root).privateBytes)) }
            return result
        case .moveToTrash, .pickToTrash:
            if let bundleID = step.item.appBundleID, !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                return .init(step: step, outcome: .skipped(reason: "The app is running. Quit it and run this step again."))
            }
            return moveToTrash(step)
        default:
            return .init(step: step, outcome: .failed(error: "This item can't be cleaned by the app."))
        }
    }

    // MARK: Commands

    private func batches(_ command: Command, _ ids: [String]) -> [[String]] {
        stride(from: 0, to: ids.count, by: 500).map { command.arguments + ids[$0..<min($0 + 500, ids.count)] }
    }

    /// Runs each invocation in turn. A failure after earlier invocations succeeded is a
    /// partial result, and the invocations that ran stay in the record.
    private func execute(_ step: CleanupStep, _ invocations: [[String]], tool: String) async -> RunRecord.StepResult {
        var executed: [String] = []
        for (n, args) in invocations.enumerated() {
            let problem: String?
            do {
                let out = try await tools.run(tool, args, timeout: .seconds(1_800))
                problem = out.status == 0 && !out.timedOut ? nil
                    : out.timedOut ? "Timed out." : out.stderr.split(separator: "\n").last.map(String.init) ?? "Exit status \(out.status)."
            } catch {
                problem = error.localizedDescription
            }
            guard let problem else { executed.append(([tool] + args).joined(separator: " ")); continue }
            let label = invocations.count > 1 ? "Batch \(n + 1) of \(invocations.count): \(problem)" : problem
            return .init(step: step, outcome: executed.isEmpty ? .failed(error: label) : .partial(measured: nil, problems: [label]), executed: executed)
        }
        return .init(step: step, outcome: .done(measured: nil), executed: executed)
    }

    /// Fills in the measured bytes for a command step from usage before and after.
    private func remeasured(_ result: RunRecord.StepResult, before: Int64?) async -> RunRecord.StepResult {
        guard let before, let after = await usage(result.step) else { return result }
        var result = result
        let freed = max(0, before - after)
        switch result.outcome {
        case .done: result.outcome = .done(measured: freed)
        case .partial(_, let problems): result.outcome = .partial(measured: freed, problems: problems)
        default: break
        }
        return result
    }

    /// Space the step's targets occupy now, measured the way that suits the tool.
    private func usage(_ step: CleanupStep) async -> Int64? {
        switch step.item.kind {
        case .nixDeadPaths:
            return SystemProvider.volumeUsed("/nix")
        case .dockerBuildCache, .dockerUnusedImages:
            guard let context = Self.command(of: step.item)?.arguments.prefix(2),
                  let out = try? await tools.run("docker", Array(context) + ["system", "df", "--format", "{{json .}}"], timeout: .seconds(120)),
                  out.succeeded else { return nil }
            let type = step.item.kind == .dockerBuildCache ? "Build Cache" : "Images"
            return Parse.dockerSystemDF(out.stdout).first { $0.type == type }?.size
        case .homebrewOldVersions, .simulatorsUnavailable:
            // What's still there of the approved targets.
            return step.approvedTargets.reduce(Int64(0)) { sum, t in
                FileManager.default.fileExists(atPath: expand(t.id)) ? sum + (t.bytes ?? 0) : sum
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

    /// Moves each approved path to the Trash, target by target.
    private func moveToTrash(_ step: CleanupStep) -> RunRecord.StepResult {
        var moved: [TrashEntry] = [], problems: [String] = []
        let realHome = FileSizes.realPath(home) ?? home
        for target in step.approvedTargets {
            let path = expand(target.id)
            guard FileSizes.resolvingAncestors(path).hasPrefix(realHome + "/") else {
                problems.append("\(target.id) is outside your home folder.")
                continue
            }
            guard let identity = FileSizes.identity(path) else { continue }   // already gone
            if let expected = target.identity, expected != identity {
                problems.append("\(target.id) changed since the scan, so it was left alone.")
                continue
            }
            let bytes = FileSizes.measure(path).privateBytes
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
        let measured = moved.map(\.bytes).reduce(0, +)
        let outcome: StepOutcome = problems.isEmpty ? .done(measured: measured)
            : moved.isEmpty ? .failed(error: problems.joined(separator: " ")) : .partial(measured: measured, problems: problems)
        return .init(step: step, outcome: outcome, trashed: moved)
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
            guard FileSizes.resolvingAncestors(entry.landed).hasPrefix(trash + "/"),
                  let identity = FileSizes.identity(entry.landed), identity == entry.identity,
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
            guard let args = Self.command(of: step.item)?.arguments, let i = args.firstIndex(of: "--builder"), args.indices.contains(i + 1),
                  let out = try? await tools.run("docker", Array(args.prefix(2)) + ["buildx", "du", "--builder", args[i + 1], "--verbose"], timeout: .seconds(120)),
                  out.succeeded else { return nil }
            return Set(Parse.buildxRecords(out.stdout).filter(\.reclaimable).map(\.id))
        case .homebrewOldVersions:
            guard let out = try? await tools.run("brew", ["cleanup", "-n"], timeout: .seconds(300)), out.succeeded else { return nil }
            return Set(Parse.brewCleanup(out.stdout).targets.map { $0.id.hasPrefix(home) ? "~" + $0.id.dropFirst(home.count) : $0.id })
        default:
            return nil
        }
    }

    /// Asks the tool where its cache is now, to confirm a clear-folder step still targets the reviewed folder.
    private func currentRoot(_ item: Item) async -> String? {
        let query: (String, [String])? = switch item.kind {
        case .goModuleCache: ("go", ["env", "GOMODCACHE"])
        case .goBuildCache: ("go", ["env", "GOCACHE"])
        case .npmCache: ("npm", ["config", "get", "cache"])
        case .uvCache: ("uv", ["cache", "dir"])
        case .pipCache: ("pip3", ["cache", "dir"])
        default: nil
        }
        guard let query, let out = try? await tools.run(query.0, query.1), out.succeeded else { return nil }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
