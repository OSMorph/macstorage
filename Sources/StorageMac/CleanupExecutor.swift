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

/// Runs an approved cleanup plan and records exactly what happened.
public struct CleanupExecutor: Sendable {
    let shell: Shell
    let home: String

    public init(shell: Shell, home: String = NSHomeDirectory()) {
        self.shell = shell
        self.home = home
    }

    public func run(_ plan: CleanupPlan, stop: StopSignal, progress: @Sendable (Int, StepOutcome?) -> Void = { _, _ in }) async -> RunRecord {
        let started = Date()
        var results: [RunRecord.StepResult] = []
        for (i, step) in plan.steps.enumerated() {
            if stop.isStopped {
                results.append(.init(step: step, outcome: .notRun))
                continue
            }
            progress(i, nil)
            let result = await perform(step, previewTime: plan.previewTime)
            results.append(result)
            progress(i, result.outcome)
        }
        return RunRecord(started: started, finished: Date(), steps: results)
    }

    func perform(_ step: CleanupStep, previewTime: Date) async -> RunRecord.StepResult {
        switch step.item.action {
        case .runOnTargets(let command, _):
            return await runOnTargets(step, command)
        case .runAfterRecheck(let command, _):
            guard await currentTargets(step) == Set(step.approvedTargets.map(\.id)) else {
                return .init(step: step, outcome: .skipped(reason: "The list changed since the preview."))
            }
            return await execute(step, [command.resolvedArguments(previewTime: previewTime)], tool: command.tool)
        case .clearFolder(let command, let root, _):
            guard await currentRoot(step.item) == root else {
                return .init(step: step, outcome: .skipped(reason: "The tool now points at a different folder than the one you reviewed."))
            }
            return await execute(step, [command.arguments], tool: command.tool)
        case .moveToTrash, .pickToTrash:
            return moveToTrash(step)
        default:
            return .init(step: step, outcome: .failed(error: "This item can't be cleaned by the app."))
        }
    }

    /// Passes the approved targets as arguments, in batches. The tool refuses anything that
    /// became in use since the preview (Nix live paths, images a container now uses).
    private func runOnTargets(_ step: CleanupStep, _ command: Command) async -> RunRecord.StepResult {
        let ids = step.approvedTargets.map(\.id)
        let batches = stride(from: 0, to: ids.count, by: 500).map { command.arguments + ids[$0..<min($0 + 500, ids.count)] }
        return await execute(step, batches, tool: command.tool)
    }

    private func execute(_ step: CleanupStep, _ invocations: [[String]], tool: String) async -> RunRecord.StepResult {
        var executed: [String] = []
        for args in invocations {
            executed.append(([tool] + args).joined(separator: " "))
            do {
                let out = try await shell.run(tool, args, timeout: .seconds(1_800))
                guard out.succeeded else {
                    let reason = out.timedOut ? "Timed out." : out.stderr.split(separator: "\n").last.map(String.init) ?? "Exit status \(out.status)."
                    return .init(step: step, outcome: .failed(error: reason), executed: executed)
                }
            } catch {
                return .init(step: step, outcome: .failed(error: error.localizedDescription), executed: executed)
            }
        }
        return .init(step: step, outcome: .done(freedBytes: step.expectedBytes), executed: executed)
    }

    /// Moves each approved path to the Trash. Only paths inside the home folder are touched;
    /// anything already gone is skipped.
    private func moveToTrash(_ step: CleanupStep) -> RunRecord.StepResult {
        var moved: [String] = [], locations: [String] = [], freed: Int64 = 0, problems: [String] = []
        for target in step.approvedTargets {
            let path = target.id.hasPrefix("~") ? home + target.id.dropFirst() : target.id
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.path.hasPrefix(home + "/"), url.path != home else { problems.append("\(path) is outside your home folder"); continue }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                var landed: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
                moved.append(target.id)
                if let landed = landed as URL? { locations.append(landed.path) }
                freed += target.bytes ?? 0
            } catch {
                problems.append("\(target.id): \(error.localizedDescription)")
            }
        }
        if moved.isEmpty, let first = problems.first { return .init(step: step, outcome: .failed(error: first)) }
        return .init(step: step, outcome: .done(freedBytes: freed), executed: moved, trashLocations: locations)
    }

    /// Permanently deletes entries a run put in the Trash. Refuses anything not in the Trash.
    public static func deleteFromTrash(_ locations: [String]) -> [String] {
        let trash = (try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false))?.path ?? NSHomeDirectory() + "/.Trash"
        return locations.filter { path in
            guard URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(trash + "/") else { return false }
            return (try? FileManager.default.removeItem(atPath: path)) != nil
        }
    }

    // MARK: Re-checks

    /// Lists a re-checked step's targets again, the same way the scan did.
    private func currentTargets(_ step: CleanupStep) async -> Set<String>? {
        switch step.item.action {
        case .runAfterRecheck(let command, _) where command.tool == "docker":
            let context = Array(command.arguments.prefix { $0 != "builder" })
            let out = try? await shell.run("docker", context + ["buildx", "du", "--verbose"], timeout: .seconds(120))
            return out.map { Set($0.stdout.split(separator: "\n").filter { $0.hasPrefix("ID:") }.map { $0.dropFirst(3).trimmingCharacters(in: .whitespaces) }) }
        case .runAfterRecheck(let command, _) where command.tool == "brew":
            let out = try? await shell.run("brew", ["cleanup", "-n"], timeout: .seconds(300))
            return out.map { Set(Parse.brewCleanup($0.stdout).targets.map { $0.id.replacingOccurrences(of: home, with: "~", options: .anchored) }) }
        default:
            return nil
        }
    }

    /// Asks the tool where its cache is now, to confirm a clear-folder step still targets the reviewed folder.
    private func currentRoot(_ item: Item) async -> String? {
        let query: (String, [String])? = switch item.id {
        case "goModuleCache": ("go", ["env", "GOMODCACHE"])
        case "goBuildCache": ("go", ["env", "GOCACHE"])
        case "npmCache": ("npm", ["config", "get", "cache"])
        case "uvCache": ("uv", ["cache", "dir"])
        case "pipCache": ("pip3", ["cache", "dir"])
        default: nil
        }
        guard let query, let out = try? await shell.run(query.0, query.1), out.succeeded else { return nil }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
