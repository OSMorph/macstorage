import Darwin
import StorageCore
@testable import StorageMac
import XCTest

/// Runs no tools: answers from a script, records every call.
final class FakeTools: ToolRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [(String) -> ToolOutput?]
    private(set) var calls: [String] = []

    init(_ answers: [(String) -> ToolOutput?] = []) { self.answers = answers }

    func isInstalled(_ tool: String) -> Bool { true }

    func run(_ tool: String, _ arguments: [String], timeout: Duration) async throws -> ToolOutput {
        let line = ([tool] + arguments).joined(separator: " ")
        return lock.withLock {
            calls.append(line)
            return answers.lazy.compactMap { $0(line) }.first ?? ToolOutput(status: 0, stdout: "")
        }
    }
}

final class FileSizesTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "macstorage-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testAClonesPrivateSizeIsZeroUntilItChanges() throws {
        let original = dir.appending(path: "a.bin").path, clone = dir.appending(path: "b.bin").path
        FileManager.default.createFile(atPath: original, contents: Data(repeating: 7, count: 4 << 20))
        XCTAssertEqual(clonefile(original, clone, 0), 0)
        let size = FileSizes.measure(dir.path)
        XCTAssertEqual(size.files, 2)
        XCTAssertGreaterThanOrEqual(size.allocated, 8 << 20, "allocated counts both copies in full")
        XCTAssertLessThan(size.privateBytes, 1 << 20, "neither copy owns its blocks yet")
        XCTAssertTrue(size.isComplete)
    }

    func testHardLinksCountOnce() throws {
        let a = dir.appending(path: "a").path
        FileManager.default.createFile(atPath: a, contents: Data(repeating: 1, count: 1 << 20))
        XCTAssertEqual(link(a, dir.appending(path: "b").path), 0)
        XCTAssertEqual(FileSizes.measure(dir.path).files, 1)
    }

    func testExcludedFoldersAreNeverEntered() throws {
        let secret = dir.appending(path: "Documents")
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: secret.appending(path: "x").path, contents: Data(repeating: 1, count: 100_000))
        let size = FileSizes.measure(dir.path, WalkOptions(excluding: [secret.path]))
        XCTAssertEqual(size.files, 0)
        XCTAssertTrue(FileSizes.children(of: dir.path, WalkOptions(excluding: [secret.path])).isEmpty)
    }

    func testGitCheckoutsCanBeSkipped() throws {
        let repo = dir.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo.appending(path: ".git"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: repo.appending(path: "big").path, contents: Data(repeating: 1, count: 100_000))
        XCTAssertEqual(FileSizes.measure(dir.path, WalkOptions(skipGitCheckouts: true)).files, 0)
    }
}

final class CleanupSafetyTests: XCTestCase {
    var home: URL!

    override func setUpWithError() throws {
        // A stand-in home folder inside the real one, so moves go to the real Trash.
        home = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "macstorage-test-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    func step(_ targets: [Target], action: Action = .moveToTrash, kind: ItemKind = .appCache) -> CleanupStep {
        let item = Item(id: "o/test", kind: kind, name: "Test", onDisk: .bytes(1), reclaimable: .bytes(1), tier: .safe, explanation: "",
                        action: action, targets: targets)
        return CleanupStep(item: item, ownerName: "O", approvedTargets: targets, expectedBytes: 1, destination: action.destination ?? .mac)
    }

    func file(_ name: String) -> String {
        let path = home.appending(path: name).path
        FileManager.default.createFile(atPath: path, contents: Data(repeating: 2, count: 4_000))
        return path
    }

    func executor(_ tools: FakeTools = FakeTools()) -> CleanupExecutor { CleanupExecutor(tools: tools, home: home.path) }

    func testNothingOutsideTheHomeFolderIsMoved() async {
        let result = await executor().perform(step([Target("/etc/hosts"), Target(home.path + "/../../etc/hosts")]), previewTime: .now)
        XCTAssertEqual(result.outcome, .failed(error: "/etc/hosts is outside your home folder. \(home.path)/../../etc/hosts is outside your home folder."))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/etc/hosts"))
    }

    func testASymlinkedParentFolderCantLeadOutside() async throws {
        let outside = FileManager.default.temporaryDirectory.appending(path: "outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        FileManager.default.createFile(atPath: outside.appending(path: "victim").path, contents: Data([1]))
        try FileManager.default.createSymbolicLink(atPath: home.appending(path: "link").path, withDestinationPath: outside.path)
        let result = await executor().perform(step([Target(home.appending(path: "link/victim").path)]), previewTime: .now)
        XCTAssertFalse(result.outcome.didRun)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appending(path: "victim").path))
    }

    func testAFileReplacedSinceTheScanIsLeftAlone() async throws {
        let path = file("cache.bin")
        let scanned = try XCTUnwrap(FileSizes.identity(path))
        try FileManager.default.removeItem(atPath: path)
        _ = file("cache.bin")   // a different file at the same path
        let result = await executor().perform(step([Target(path, identity: scanned)]), previewTime: .now)
        XCTAssertFalse(result.outcome.didRun)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testMovedEntriesCanBeDeletedFromTheTrashButNotSwappedOnes() async throws {
        let a = file("a.tmp"), b = file("b.tmp")
        let result = await executor().perform(step([Target(a, identity: FileSizes.identity(a)), Target(b, identity: FileSizes.identity(b))]), previewTime: .now)
        XCTAssertEqual(result.trashed.count, 2)
        XCTAssertTrue(result.trashed.allSatisfy { $0.identity != nil })
        // Swap the second landed entry for a different file at the same path.
        let swapped = result.trashed[1].landed
        try FileManager.default.removeItem(atPath: swapped)
        FileManager.default.createFile(atPath: swapped, contents: Data([9]))
        defer { try? FileManager.default.removeItem(atPath: swapped) }
        let (deleted, refused) = CleanupExecutor.deleteFromTrash(result.trashed)
        XCTAssertEqual(deleted.map(\.original), [a])
        XCTAssertEqual(refused, [b])
        XCTAssertTrue(FileManager.default.fileExists(atPath: swapped))
    }

    func testTrashDeletionRefusesAnythingOutsideTheTrash() {
        let path = file("keep.tmp")
        let entry = TrashEntry(original: path, landed: path, identity: FileSizes.identity(path), bytes: 1, picked: false)
        XCTAssertEqual(CleanupExecutor.deleteFromTrash([entry]).refused, [path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testAFailedBatchAfterEarlierOnesIsPartialAndKeepsWhatRan() async {
        let tools = FakeTools([{ $0.contains("t500") ? ToolOutput(status: 1, stdout: "", stderr: "error: path is alive") : nil }])
        let targets = (0..<700).map { Target("t\($0)") }
        let result = await executor(tools).perform(step(targets, action: .runOnTargets(Command("nix-store", ["--delete"]), .mac), kind: .nixDeadPaths), previewTime: .now)
        guard case .partial(_, let problems) = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(problems, ["Batch 2 of 2: error: path is alive"])
        XCTAssertEqual(result.executed.count, 1)
    }

    func testAFailureStopsTheRest() async {
        let tools = FakeTools([{ $0.hasPrefix("go") ? ToolOutput(status: 1, stdout: "", stderr: "boom") : nil }])
        let failing = step([Target("x")], action: .runOnTargets(Command("go", ["clean"]), .mac), kind: .nixDeadPaths)
        var later = step([Target("y")], action: .runOnTargets(Command("nix-store", ["--delete"]), .mac), kind: .nixDeadPaths)
        later.item.id = "o/later"
        var plan = CleanupPlan(snapshot: Demo.snapshot(), selected: [], picks: [:])
        plan.steps = [failing, later]
        let run = await executor(tools).run(plan, stop: StopSignal())
        XCTAssertEqual(run.steps[0].outcome, .failed(error: "boom"))
        XCTAssertEqual(run.steps[1].outcome, .notRun(reason: "Not started because an earlier step failed."))
        XCTAssertFalse(tools.calls.contains { $0.hasPrefix("nix-store") })
    }

    func testARecheckThatCantListSkipsTheStep() async {
        let tools = FakeTools([{ $0.contains("buildx du") ? ToolOutput(status: 1, stdout: "") : nil }])
        let action = Action.runAfterRecheck(Command("docker", ["--context", "c", "buildx", "prune", "--builder", "c", "-f"]), .containerDisk)
        let result = await executor(tools).perform(step([Target("r1")], action: action, kind: .dockerBuildCache), previewTime: .now)
        guard case .skipped = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertFalse(tools.calls.contains { $0.contains("prune") })
    }
}
