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

    func testAFolderLevelListsFoldersAndFilesWithTheirOwners() throws {
        let fm = FileManager.default
        let sub = dir.appending(path: "Projects"), protected = dir.appending(path: "Private"), empty = dir.appending(path: "Empty")
        for d in [sub, protected, empty] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        fm.createFile(atPath: sub.appending(path: "big.bin").path, contents: Data(repeating: 1, count: 1 << 20))
        fm.createFile(atPath: protected.appending(path: "secret.bin").path, contents: Data(repeating: 2, count: 1 << 20))
        fm.createFile(atPath: dir.appending(path: "notes.txt").path, contents: Data(repeating: 3, count: 64 << 10))
        try fm.createSymbolicLink(atPath: dir.appending(path: "link").path, withDestinationPath: sub.path)
        let item = Rules.item(Fact(.appLogs, onDisk: .bytes(1 << 20), targets: [], path: sub.path))
        let owners = [Owner(id: "logs", name: "Logs", kind: .system, location: "", items: [item])]
        let options = WalkOptions(excluding: [protected.path])

        XCTAssertEqual(Set(try XCTUnwrap(FolderAttribution.names(in: dir.path))), ["Projects", "Private", "Empty", "notes.txt", "link"])
        let folder = try XCTUnwrap(FolderAttribution.entry("Projects", in: dir.path, owners: owners, options))
        XCTAssertEqual(folder.isFolder, true)
        XCTAssertGreaterThanOrEqual(folder.bytes ?? 0, 1 << 20)
        XCTAssertEqual(folder.owners.map(\.ownerID), ["logs"])
        XCTAssertEqual(folder.kind, .system)
        let held = try XCTUnwrap(FolderAttribution.entry("big.bin", in: sub.path, owners: owners, options))
        XCTAssertEqual(held.owners.map(\.ownerID), ["logs"], "inside an owner's folder, the owner claims it")
        XCTAssertEqual(held.owners.first?.bytes, held.bytes)
        let broad = Owner(id: "broad", name: "Broad", kind: .apps, location: "", items: [Rules.item(Fact(.appCache, onDisk: .bytes(1 << 30), targets: [], path: dir.path))])
        let nested = try XCTUnwrap(FolderAttribution.entry("big.bin", in: sub.path, owners: [broad] + owners, options))
        XCTAssertEqual(nested.owners.map(\.ownerID), ["logs"], "the closest folder's owner, not the biggest")
        let file = try XCTUnwrap(FolderAttribution.entry("notes.txt", in: dir.path, owners: owners, options))
        XCTAssertEqual(file.isFolder, false, "a file can't be opened")
        XCTAssertEqual(file.kind, .personalFiles)
        let guarded = try XCTUnwrap(FolderAttribution.entry("Private", in: dir.path, owners: owners, options))
        XCTAssertNil(guarded.bytes, "a protected folder is listed without being read")
        XCTAssertNil(FolderAttribution.entry("Empty", in: dir.path, owners: owners, options), "nothing that takes no space")
        XCTAssertNil(FolderAttribution.entry("link", in: dir.path, owners: owners, options), "a symlink isn't followed")
        XCTAssertNil(FolderAttribution.names(in: dir.appending(path: "missing").path))

        // A folder that can't be read is kept, not dropped as empty.
        let locked = dir.appending(path: "Locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        fm.createFile(atPath: locked.appending(path: "x.bin").path, contents: Data(repeating: 4, count: 1 << 20))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let unreadable = try XCTUnwrap(FolderAttribution.entry("Locked", in: dir.path, owners: owners, options))
        XCTAssertTrue(unreadable.isPartial)
    }

    func testAFolderIsOnlyOpenedWhenItsRealAndAllowed() throws {
        let fm = FileManager.default
        let home = dir.appending(path: "home"), outside = dir.appending(path: "elsewhere/inner")
        for d in [home.appending(path: "Projects/app"), home.appending(path: "Downloads/zips"), outside] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        fm.createFile(atPath: home.appending(path: "notes.txt").path, contents: Data())
        try fm.createSymbolicLink(atPath: home.appending(path: "link").path, withDestinationPath: dir.appending(path: "elsewhere").path)
        let protected: Set<String> = [home.appending(path: "Downloads").path]
        func refusal(_ sub: String) -> FolderAttribution.Refusal? {
            FolderAttribution.refusal(home.path + "/" + sub, home: home.path, protected: protected)
        }
        XCTAssertNil(refusal("Projects"))
        XCTAssertNil(refusal("Projects/app"))
        XCTAssertEqual(refusal("notes.txt"), .notAFolder)
        XCTAssertEqual(refusal("link"), .notAFolder, "a link itself isn't a folder")
        XCTAssertEqual(refusal("link/inner"), .throughLink, "nothing is read through a link above it")
        XCTAssertEqual(refusal("Downloads"), .needsFullDiskAccess)
        XCTAssertEqual(refusal("Downloads/zips"), .needsFullDiskAccess, "inside a protected folder too")
        XCTAssertNil(FolderAttribution.refusal(home.path + "/Downloads", home: home.path, protected: []), "with Full Disk Access")
    }

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
        XCTAssertEqual(FileSizes.children(of: dir.path, WalkOptions(excluding: [secret.path]))?.isEmpty, true)
    }

    func testGitCheckoutsCanBeSkipped() throws {
        let repo = dir.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo.appending(path: ".git"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: repo.appending(path: "big").path, contents: Data(repeating: 1, count: 100_000))
        XCTAssertEqual(FileSizes.measure(dir.path, WalkOptions(skipGitCheckouts: true)).files, 0)
    }
}

func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

final class Journal: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [RunRecord] = []
    func add(_ r: RunRecord) { lock.withLock { stored.append(r) } }
    var records: [RunRecord] { lock.withLock { stored } }
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
        XCTAssertEqual(result.outcome, .skipped(reason: "Nothing on the approved list was still as you reviewed it."))
        XCTAssertEqual(result.leftAlone, ["/etc/hosts: outside your home folder.", "\(home.path)/../../etc/hosts: outside your home folder."])
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/etc/hosts"))
    }

    func testAChangedTargetIsLeftAloneWithoutStoppingTheStep() async throws {
        let kept = file("kept.log"), changed = file("changed.log")
        let scanned = try XCTUnwrap(FileSizes.identity(changed))
        FileManager.default.createFile(atPath: changed, contents: Data(repeating: 3, count: 9_000))   // rewritten since the scan
        let result = await executor().perform(step([Target(kept, identity: FileSizes.identity(kept)), Target(changed, identity: scanned)]), previewTime: .now)
        defer { result.trashed.forEach { try? FileManager.default.removeItem(atPath: $0.landed) } }
        XCTAssertTrue(result.outcome.isDone)
        XCTAssertFalse(result.outcome.stopsRun)
        XCTAssertEqual(result.trashed.map(\.original), [kept])
        XCTAssertEqual(result.leftAlone, ["\(changed): replaced or changed since the scan."])
    }

    func testAFolderThatGainedAnEntryIsStillTheSameFolder() async throws {
        let folder = home.appending(path: "DiagnosticReports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scanned = try XCTUnwrap(FileSizes.identity(folder.path))
        try await Task.sleep(for: .milliseconds(20))
        FileManager.default.createFile(atPath: folder.appending(path: "new.crash").path, contents: Data([1]))
        let result = await executor().perform(step([Target(folder.path, identity: scanned)]), previewTime: .now)
        defer { result.trashed.forEach { try? FileManager.default.removeItem(atPath: $0.landed) } }
        XCTAssertEqual(result.trashed.count, 1)
    }

    func testATargetWithoutAScanIdentityIsNotMoved() async {
        let path = file("unknown.bin")
        let result = await executor().perform(step([Target(path)]), previewTime: .now)
        XCTAssertTrue(result.trashed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testBuildOutputIsLeftAloneWhenItsCheckoutHasNewWork() async throws {
        let checkout = home.appending(path: "repo")
        try FileManager.default.createDirectory(at: checkout.appending(path: ".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: checkout.appending(path: "node_modules"), withIntermediateDirectories: true)
        let out = checkout.appending(path: "node_modules").path
        let tools = FakeTools([{ $0.contains("status") ? ToolOutput(status: 0, stdout: "## main...origin/main\n M index.js\n") : nil }])
        let result = await executor(tools).perform(step([Target(out, identity: FileSizes.identity(out))], kind: .gitBuildOutput), previewTime: .now)
        XCTAssertTrue(result.trashed.isEmpty)
        XCTAssertEqual(result.leftAlone, ["\(out): its checkout now has uncommitted or unpushed work."])
        XCTAssertTrue(FileManager.default.fileExists(atPath: out))
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

    func testATrashedFolderFinderTouchedCanStillBeDeleted() async throws {
        let folder = home.appending(path: "DerivedData-x")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = await executor().perform(step([Target(folder.path, identity: FileSizes.identity(folder.path))]), previewTime: .now)
        let entry = try XCTUnwrap(result.trashed.first)
        try await Task.sleep(for: .milliseconds(20))
        FileManager.default.createFile(atPath: entry.landed + "/.DS_Store", contents: Data([1]))
        XCTAssertEqual(CleanupExecutor.deleteFromTrash([entry]).deleted.count, 1)
    }

    func testPermanentDeletionReportsWhatTheFolderHoldsNow() async throws {
        let folder = home.appending(path: "Archive-x")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = await executor().perform(step([Target(folder.path, identity: FileSizes.identity(folder.path))]), previewTime: .now)
        var entry = try XCTUnwrap(result.trashed.first)
        entry.isEstimate = true   // as if the walk before the move had been incomplete
        FileManager.default.createFile(atPath: entry.landed + "/added", contents: Data(repeating: 1, count: 40_000))
        let deleted = try XCTUnwrap(CleanupExecutor.deleteFromTrash([entry]).deleted.first)
        XCTAssertGreaterThanOrEqual(deleted.bytes, 40_000)
        XCTAssertFalse(deleted.isEstimate)
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
        XCTAssertEqual(result.executed.count, 2, "the failed invocation is recorded too")
        XCTAssertTrue(result.executed[1].hasSuffix("[failed: error: path is alive]"))
    }

    func testAFailedFirstInvocationIsStillRecordedAsRun() async {
        let tools = FakeTools([{ $0.hasPrefix("nix-store") ? ToolOutput(status: 1, stdout: "", stderr: "error: cannot delete path 'b' since it is still alive") : nil }])
        let result = await executor(tools).perform(step([Target("a"), Target("b")], action: .runOnTargets(Command("nix-store", ["--delete"]), .mac), kind: .nixDeadPaths), previewTime: .now)
        guard case .failed(let error) = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertTrue(error.contains("may have removed some targets"))
        XCTAssertEqual(result.executed, ["nix-store --delete a b   [failed: error: cannot delete path 'b' since it is still alive]"])
    }

    func testTheRunIsJournaledBeforeEachStep() async {
        let journal = Journal()
        var plan = CleanupPlan(snapshot: Demo.snapshot(), selected: [], picks: [:])
        plan.steps = [step([Target("x")], action: .runOnTargets(Command("nix-store", ["--delete"]), .mac), kind: .nixDeadPaths)]
        _ = await executor().run(plan, stop: StopSignal(), journal: { journal.add($0); return true })
        XCTAssertEqual(journal.records.first?.steps.first?.outcome, .failed(error: CleanupExecutor.interrupted))
    }

    func testNothingRunsWhenTheRecordCantBeSaved() async {
        let tools = FakeTools()
        var plan = CleanupPlan(snapshot: Demo.snapshot(), selected: [], picks: [:])
        plan.steps = [step([Target("x")], action: .runOnTargets(Command("nix-store", ["--delete"]), .mac), kind: .nixDeadPaths)]
        let run = await executor(tools).run(plan, stop: StopSignal(), journal: { _ in false })
        XCTAssertEqual(run.steps[0].outcome, .notRun(reason: CleanupExecutor.notJournaled))
        XCTAssertTrue(tools.calls.isEmpty)
    }

    // MARK: Docker binding

    func dockerImagesStep(_ targets: [Target]) -> CleanupStep {
        // The action as the rules build it.
        var s = step(targets, action: Rules.item(Fact(.dockerUnusedImages, onDisk: .bytes(1), targets: targets, root: "c")).action, kind: .dockerUnusedImages)
        s.item.scopeGuard = .dockerEngine(id: "ENGINE1")
        return s
    }

    func dockerTools(engine: String, images: String) -> FakeTools {
        FakeTools([
            { $0.contains(" info ") ? ToolOutput(status: 0, stdout: engine + "\n") : nil },
            { $0.contains("image inspect") ? ToolOutput(status: 0, stdout: images) : nil },
        ])
    }

    func testARetaggedImageIsNotRemoved() async {
        let tools = dockerTools(engine: "ENGINE1", images: "sha256:new\n")
        let result = await executor(tools).perform(dockerImagesStep([Target("app:latest", fingerprint: "sha256:old")]), previewTime: .now)
        guard case .skipped = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertFalse(tools.calls.contains { $0.contains("image rm") })
    }

    func testAContextPointingAtAnotherEngineIsRefused() async {
        let tools = dockerTools(engine: "ENGINE2", images: "sha256:old\n")
        let result = await executor(tools).perform(dockerImagesStep([Target("app:latest", fingerprint: "sha256:old")]), previewTime: .now)
        guard case .skipped = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertFalse(tools.calls.contains { $0.contains("image rm") })
    }

    func testUnchangedImagesAreRemovedByTheApprovedRefs() async {
        let tools = dockerTools(engine: "ENGINE1", images: "sha256:a\nsha256:b\n")
        let result = await executor(tools).perform(dockerImagesStep([Target("app:1", fingerprint: "sha256:a"), Target("app:2", fingerprint: "sha256:b")]), previewTime: .now)
        XCTAssertTrue(result.outcome.isDone)
        XCTAssertTrue(tools.calls.contains("docker --context c image rm --no-prune app:1 app:2"), "\(tools.calls)")
    }

    func testImageRefsCarryTheirImageID() {
        let refs = DockerProvider.imageRefs([["Repository": "app", "Tag": "1", "ID": "sha256:a", "Size": "1GB"],
                                             ["Repository": "<none>", "Tag": "<none>", "ID": "sha256:b", "Size": "2GB"]])
        XCTAssertEqual(refs.map(\.id), ["app:1", "sha256:b"])
        XCTAssertEqual(refs.map(\.fingerprint), ["sha256:a", "sha256:b"])
    }

    // MARK: Podman

    func podmanImagesStep(_ targets: [Target]) -> CleanupStep {
        var s = step(targets, action: Rules.item(Fact(.podmanUnusedImages, onDisk: .bytes(1), targets: targets, root: "dev")).action, kind: .podmanUnusedImages)
        s.item.scopeGuard = .podmanConnection(uri: "ssh://core@127.0.0.1:50000/run/user/501/podman/podman.sock", machine: "dev")
        return s
    }

    func podmanTools(uri: String, images: String) -> FakeTools {
        FakeTools([
            { $0.contains("connection list") ? ToolOutput(status: 0, stdout: #"[{"Name":"dev","URI":"\#(uri)","IsMachine":true}]"#) : nil },
            { $0.contains("machine list") ? ToolOutput(status: 0, stdout: #"[{"Name":"dev","Running":true,"VMType":"libkrun","Port":50000,"RemoteUsername":"core"}]"#) : nil },
            { $0.contains(" info ") ? ToolOutput(status: 0, stdout: "localhost\n") : nil },
            { $0.contains("image inspect") ? ToolOutput(status: 0, stdout: images) : nil },
        ])
    }

    func testPodmanImagesAreRemovedThroughTheirConnection() async {
        let tools = podmanTools(uri: "ssh://core@127.0.0.1:50000/run/user/501/podman/podman.sock", images: "aaa\n")
        let result = await executor(tools).perform(podmanImagesStep([Target("localhost/app:1", fingerprint: "aaa")]), previewTime: .now)
        XCTAssertTrue(result.outcome.isDone, "\(result.outcome)")
        XCTAssertTrue(tools.calls.contains("podman --connection dev image rm --no-prune localhost/app:1"), "\(tools.calls)")
    }

    func testAPodmanConnectionPointingElsewhereIsRefused() async {
        let tools = podmanTools(uri: "ssh://core@127.0.0.1:60000/run/user/501/podman/podman.sock", images: "aaa\n")
        let result = await executor(tools).perform(podmanImagesStep([Target("localhost/app:1", fingerprint: "aaa")]), previewTime: .now)
        guard case .skipped = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertFalse(tools.calls.contains { $0.contains("image rm") })
    }

    func testARetaggedPodmanImageIsNotRemoved() async {
        let tools = podmanTools(uri: "ssh://core@127.0.0.1:50000/run/user/501/podman/podman.sock", images: "bbb\n")
        let result = await executor(tools).perform(podmanImagesStep([Target("localhost/app:1", fingerprint: "aaa")]), previewTime: .now)
        guard case .skipped = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertFalse(tools.calls.contains { $0.contains("image rm") })
    }

    func testAPodmanMachineIsMeasuredThroughItsConnection() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "podman-home-\(UUID().uuidString)")
        let machines = home.appending(path: ".local/share/containers/podman/machine/applehv")
        try FileManager.default.createDirectory(at: machines, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        FileManager.default.createFile(atPath: machines.appending(path: "dev-arm64.raw").path, contents: Data(repeating: 1, count: 1 << 20))
        FileManager.default.createFile(atPath: machines.appending(path: "dev-2-arm64.raw").path, contents: Data(repeating: 1, count: 2 << 20))
        let tools = FakeTools([
            { $0.hasSuffix("machine list --all-providers --format json") ? ToolOutput(status: 0, stdout: #"[{"Name":"dev*","Running":true,"VMType":"applehv"},{"Name":"dev-2","Running":false,"VMType":"applehv"}]"#) : nil },
            { $0.contains("connection list") ? ToolOutput(status: 0, stdout: #"[{"Name":"dev","URI":"ssh://core@127.0.0.1:50000/run/user/501/podman/podman.sock","IsMachine":true},{"Name":"dev-root","URI":"ssh://root@127.0.0.1:50000/run/podman/podman.sock","IsMachine":true},{"Name":"dev-2","URI":"ssh://core@127.0.0.1:50001/run/user/501/podman/podman.sock","IsMachine":true}]"#) : nil },
            { $0.hasPrefix("podman --connection dev system df") ? ToolOutput(status: 0, stdout: #"{"Type":"Images","TotalCount":3,"Active":1,"RawSize":3000,"RawReclaimable":2000}"#) : nil },
            { $0.hasPrefix("podman --connection dev images") ? ToolOutput(status: 0, stdout: [
                #"{"repository":"localhost/app","tag":"1","Id":"aaa","Size":1000,"Containers":0}"#,
                #"{"repository":"localhost/app","tag":"latest","Id":"aaa","Size":1000,"Containers":0}"#,
                #"{"repository":"<none>","tag":"<none>","Id":"bbb","Size":1500,"Containers":0}"#,
                #"{"repository":"docker.io/library/db","tag":"16","Id":"ccc","Size":500,"Containers":1}"#,
            ].joined(separator: "\n")) : nil },
            { $0.hasPrefix("podman --connection dev ps") ? ToolOutput(status: 0, stdout: "web\trunning\nold-job\texited\n") : nil },
            { $0.hasPrefix("podman --connection dev volume") ? ToolOutput(status: 0, stdout: "scratch\n") : nil },
            // The rootful store is empty: nothing from it is shown.
            { $0.hasPrefix("podman --connection dev-root system df") ? ToolOutput(status: 0, stdout: #"{"Type":"Images","TotalCount":0,"Active":0,"RawSize":0,"RawReclaimable":0}"#) : nil },
        ])
        let result = await PodmanProvider().scan(ScanContext(tools: tools, home: home.path, fullDiskAccess: true))
        let running = try XCTUnwrap(result.owners.first { $0.id == "podman:dev" })
        XCTAssertEqual(running.name, "Podman (dev)")
        XCTAssertEqual(running.location, "~/.local/share/containers/podman/machine/applehv")
        XCTAssertGreaterThanOrEqual(running.hostBytes ?? 0, 1 << 20, "its own disk, not dev-2's")
        XCTAssertLessThan(running.hostBytes ?? 0, 2 << 20)
        let images = try XCTUnwrap(running.items.first { $0.kind == .podmanUnusedImages })
        XCTAssertEqual(images.targets.map(\.id), ["localhost/app:1", "localhost/app:latest", "bbb"])
        XCTAssertEqual(images.targets.map(\.fingerprint), ["aaa", "aaa", "bbb"])
        XCTAssertEqual(images.reclaimable, .bytes(2000), "capped at what Podman says is reclaimable")
        XCTAssertEqual(images.scopeGuard, .podmanConnection(uri: "ssh://core@127.0.0.1:50000/run/user/501/podman/podman.sock", machine: "dev"))
        XCTAssertEqual(running.items.first { $0.kind == .podmanStoppedContainers }?.targets.map(\.id), ["old-job"])
        XCTAssertEqual(running.items.first { $0.kind == .podmanUnusedVolumes }?.targets.map(\.id), ["scratch"])
        XCTAssertFalse(running.items.contains { $0.name.contains("rootful") })
        let stopped = try XCTUnwrap(result.owners.first { $0.id == "podman:dev-2" })
        XCTAssertEqual(stopped.items.map(\.kind), [.podmanVMDisk])
        XCTAssertFalse(tools.calls.contains { $0.contains("dev-2 ") && !$0.contains("connection list") }, "a stopped machine is never asked")
        XCTAssertFalse(tools.calls.contains { $0.contains("machine start") })
    }

    func testAConnectionMustLeadToItsOwnMachine() {
        let machine = ["Name": "dev", "Port": "50000", "RemoteUsername": "core"]
        let rootless = ["URI": "ssh://core@127.0.0.1:50000/run/user/501/podman/podman.sock", "IsMachine": "true"]
        XCTAssertNotNil(PodmanProvider.machineURI(rootless, of: machine, rootful: false))
        XCTAssertNil(PodmanProvider.machineURI(["URI": "ssh://core@127.0.0.1:50999/run/user/501/podman/podman.sock"], of: machine, rootful: false), "another local VM")
        XCTAssertNil(PodmanProvider.machineURI(rootless, of: machine, rootful: true), "the rootful connection logs in as root")
        XCTAssertNotNil(PodmanProvider.machineURI(["URI": "ssh://root@localhost:50000/run/podman/podman.sock"], of: machine, rootful: true))
        XCTAssertEqual(PodmanProvider.destination("ssh://core@localhost:50000/run/x.sock"), PodmanProvider.destination("ssh://core@127.0.0.1:50000/run/x.sock"))
    }

    func testOlderPodmanShowsOtherProvidersDisksAsFiles() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "podman-home-\(UUID().uuidString)")
        let machine = home.appending(path: ".local/share/containers/podman/machine")
        for type in ["applehv", "qemu"] { try FileManager.default.createDirectory(at: machine.appending(path: type), withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: home) }
        FileManager.default.createFile(atPath: machine.appending(path: "applehv/dev-arm64.raw").path, contents: Data(repeating: 1, count: 1 << 20))
        FileManager.default.createFile(atPath: machine.appending(path: "qemu/old_fedora-coreos-39.qcow2").path, contents: Data(repeating: 1, count: 1 << 20))
        let tools = FakeTools([
            { $0.contains("--all-providers") ? ToolOutput(status: 125, stdout: "", stderr: "unknown flag") : nil },
            { $0.contains("machine list") ? ToolOutput(status: 0, stdout: #"[{"Name":"dev","Running":false,"VMType":"applehv"}]"#) : nil },
        ])
        let result = await PodmanProvider().scan(ScanContext(tools: tools, home: home.path, fullDiskAccess: true))
        XCTAssertEqual(Set(result.owners.map(\.name)), ["Podman (dev)", "Podman machine disk (qemu)"])
        XCTAssertTrue(result.coverage.contains { $0.area == "Podman (other providers)" })
    }

    func testOnlyConnectionsToAMachineOnThisMacAreAsked() {
        XCTAssertNotNil(PodmanProvider.localMachineURI(["URI": "ssh://core@127.0.0.1:50000/run/user/501/podman/podman.sock", "IsMachine": "true"]))
        XCTAssertNotNil(PodmanProvider.localMachineURI(["URI": "unix:///var/folders/x/podman/dev-api.sock"]), "podman 4 has no IsMachine")
        XCTAssertNil(PodmanProvider.localMachineURI(["URI": "ssh://core@build.example.com:22/run/podman/podman.sock", "IsMachine": "false"]))
        XCTAssertNil(PodmanProvider.localMachineURI(["URI": "ssh://core@build.example.com:22/run/podman/podman.sock"]), "same name, another host")
        XCTAssertNil(PodmanProvider.localMachineURI(["URI": "ssh://core@127.0.0.1:50000/run/podman.sock", "IsMachine": "false"]))
    }

    func testARootfulConnectionAliasingTheRootlessOneIsAskedOnce() async throws {
        let uri = "ssh://core@127.0.0.1:50000/run/user/501/podman/podman.sock"
        let tools = FakeTools([
            { $0.contains("machine list") ? ToolOutput(status: 0, stdout: #"[{"Name":"dev","Running":true,"VMType":"applehv"}]"#) : nil },
            { $0.contains("connection list") ? ToolOutput(status: 0, stdout: #"[{"Name":"dev","URI":"\#(uri)","IsMachine":true},{"Name":"dev-root","URI":"\#(uri)","IsMachine":true}]"#) : nil },
            { $0.contains(" system df") ? ToolOutput(status: 0, stdout: #"{"Type":"Images","TotalCount":1,"Active":0,"RawSize":100,"RawReclaimable":100}"#) : nil },
        ])
        _ = await PodmanProvider().scan(ScanContext(tools: tools, home: NSTemporaryDirectory(), fullDiskAccess: true))
        XCTAssertFalse(tools.calls.contains { $0.contains("--connection dev-root") }, "the same store isn't counted twice")
    }

    /// A running machine "dev" with one disk file, answering through `answers`.
    func podmanMachine(_ answers: [(String) -> ToolOutput?], listAllProviders: Bool = true, connectionsFirst: Bool = false) async throws -> (ProviderResult, FakeTools) {
        let home = FileManager.default.temporaryDirectory.appending(path: "podman-home-\(UUID().uuidString)")
        let folder = home.appending(path: ".local/share/containers/podman/machine/libkrun")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        FileManager.default.createFile(atPath: folder.appending(path: "dev-arm64.raw").path, contents: Data(repeating: 1, count: 1 << 20))
        let machines = #"[{"Name":"dev","Running":true,"VMType":"libkrun"}]"#
        let tools = FakeTools((connectionsFirst ? answers : []) + [
            { $0.contains("machine list --all-providers") ? (listAllProviders ? ToolOutput(status: 0, stdout: machines) : ToolOutput(status: 125, stdout: "", stderr: "unknown flag")) : nil },
            { $0.contains("machine list --format") ? ToolOutput(status: 0, stdout: machines) : nil },
            { $0.contains("connection list") ? ToolOutput(status: 0, stdout: #"[{"Name":"dev","URI":"ssh://core@127.0.0.1:50000/run/user/501/podman/podman.sock","IsMachine":true},{"Name":"dev-root","URI":"ssh://root@127.0.0.1:50000/run/podman/podman.sock","IsMachine":true}]"#) : nil },
        ] + (connectionsFirst ? [] : answers))
        return (await PodmanProvider().scan(ScanContext(tools: tools, home: home.path, fullDiskAccess: true)), tools)
    }

    func testOlderPodmanIsListedWithoutAllProviders() async throws {
        let (result, tools) = try await podmanMachine([], listAllProviders: false)
        XCTAssertTrue(tools.calls.contains("podman machine list --format json"))
        XCTAssertNotNil(result.owners.first { $0.id == "podman:dev" })
    }

    func testARootfulStoreWithSomethingInItIsShown() async throws {
        let (result, _) = try await podmanMachine([
            { $0.hasPrefix("podman --connection dev-root volume") ? ToolOutput(status: 0, stdout: "rootdata\n") : nil },
        ])
        let volumes = result.owners.first?.items.filter { $0.kind == .podmanUnusedVolumes } ?? []
        XCTAssertEqual(volumes.map(\.name).sorted(), ["Volumes no container uses", "Volumes no container uses (rootful)"], "a 0-byte volume still counts")
        XCTAssertEqual(volumes.first { $0.name.hasSuffix("(rootful)") }?.targets.map(\.id), ["rootdata"])
    }

    func testAMachineThatDoesntAnswerShowsOnlyItsDisk() async throws {
        let (result, _) = try await podmanMachine([{ $0.contains(" system df") ? ToolOutput(status: 125, stdout: "", stderr: "connection refused") : nil }])
        let owner = try XCTUnwrap(result.owners.first)
        XCTAssertEqual(owner.items.map(\.kind), [.podmanVMDisk], "not the whole disk as VM overhead")
        XCTAssertTrue(owner.items.first?.path?.hasSuffix("/dev-arm64.raw") == true, "its own disk file")
        let coverage = try XCTUnwrap(result.coverage.first)
        XCTAssertEqual(coverage.status, .failed)
        XCTAssertTrue(coverage.detail.contains("didn't answer"), coverage.detail)
    }

    func testARunningMachineWithoutALocalConnectionShowsOnlyItsDisk() async throws {
        let (result, tools) = try await podmanMachine([
            { $0.contains("connection list") ? ToolOutput(status: 0, stdout: #"[{"Name":"dev","URI":"ssh://core@build.example.com:22/run/podman/podman.sock"}]"#) : nil },
        ], connectionsFirst: true)
        XCTAssertEqual(result.owners.first?.items.map(\.kind), [.podmanVMDisk])
        XCTAssertEqual(result.coverage.first?.detail, "Running, but Podman has no connection to it on this Mac. Only its VM disk file was measured.")
        XCTAssertFalse(tools.calls.contains { $0.contains("--connection") }, "a remote host is never asked")
    }

    func testAStoreThatDidntAnswerIsntCountedAsOverhead() async throws {
        let (result, _) = try await podmanMachine([
            { $0.hasPrefix("podman --connection dev system df") ? ToolOutput(status: 125, stdout: "", stderr: "timeout") : nil },
            { $0.hasPrefix("podman --connection dev-root volume") ? ToolOutput(status: 0, stdout: "rootdata\n") : nil },
        ])
        let kinds = result.owners.first?.items.map(\.kind) ?? []
        XCTAssertTrue(kinds.contains(.podmanUnusedVolumes), "the rootful store answered")
        XCTAssertFalse(kinds.contains(.dockerDiskSlack), "the rootless store's size is unknown, so nothing is called overhead")
    }

    func testStoppedContainersLeaveOutRunningPausedAndPodInfra() async throws {
        let (result, _) = try await podmanMachine([
            { $0.hasPrefix("podman --connection dev ps") ? ToolOutput(status: 0, stdout: "web\trunning\tfalse\njob\texited\tfalse\nnew\tcreated\tfalse\nhold\tpaused\tfalse\npod-infra\tcreated\ttrue\n") : nil },
        ])
        let stopped = result.owners.first?.items.first { $0.kind == .podmanStoppedContainers && !$0.name.contains("rootful") }
        XCTAssertEqual(stopped?.targets.map(\.id), ["job", "new"])
    }

    func testPodmanDiskNamesMatchTheirMachine() {
        XCTAssertTrue(PodmanProvider.isDisk("podman-machine-default-arm64.raw", of: "podman-machine-default"))
        XCTAssertTrue(PodmanProvider.isDisk("podman-machine-default_fedora-coreos-40-qemu.x86_64.qcow2", of: "podman-machine-default"))
        XCTAssertFalse(PodmanProvider.isDisk("podman-machine-default-arm64.json", of: "podman-machine-default"))
        XCTAssertFalse(PodmanProvider.isDisk("dev-2-arm64.raw", of: "dev", others: ["dev", "dev-2"]))
    }

    func testADockerContextIsMeasuredWhenTheVersionCheckFails() async {
        let tools = FakeTools([
            { $0.contains("context ls") ? ToolOutput(status: 0, stdout: #"{"Name":"c","DockerEndpoint":"unix:///tmp/d.sock"}"#) : nil },
            { $0.contains(" info ") ? ToolOutput(status: 0, stdout: "ID1\tDocker engine\n") : nil },
            { $0.contains(" version ") ? ToolOutput(status: 1, stdout: "", stderr: "boom") : nil },
        ])
        let result = await DockerProvider().scan(ScanContext(tools: tools, home: NSTemporaryDirectory(), fullDiskAccess: true))
        XCTAssertEqual(result.owners.map(\.id), ["docker:c"])
        let podmanLike = FakeTools([
            { $0.contains("context ls") ? ToolOutput(status: 0, stdout: #"{"Name":"c","DockerEndpoint":"unix:///var/run/docker.sock"}"#) : nil },
            { $0.contains(" info ") ? ToolOutput(status: 0, stdout: "ID1\tFedora CoreOS 41\n") : nil },
            { $0.contains(" version ") ? ToolOutput(status: 1, stdout: "", stderr: "boom") : nil },
        ])
        let fedora = await DockerProvider().scan(ScanContext(tools: podmanLike, home: NSTemporaryDirectory(), fullDiskAccess: true))
        XCTAssertEqual(fedora.owners.count, 1, "only a positive answer hands an engine to Podman")
        XCTAssertTrue(fedora.coverage.contains { $0.detail.contains("overlap") }, "the possible overlap is said")
    }

    func testADockerContextThatReachesPodmanIsLeftToPodman() async {
        let tools = FakeTools([
            { $0.contains("context ls") ? ToolOutput(status: 0, stdout: #"{"Name":"default","DockerEndpoint":"unix:///var/run/docker.sock"}"#) : nil },
            { $0.contains(" info ") ? ToolOutput(status: 0, stdout: "ID1\tfedora\n") : nil },
            { $0.contains(" version ") ? ToolOutput(status: 0, stdout: "Podman Engine;\n") : nil },
        ])
        let result = await DockerProvider().scan(ScanContext(tools: tools, home: NSTemporaryDirectory(), fullDiskAccess: true))
        XCTAssertTrue(result.owners.isEmpty, "not counted twice")
        XCTAssertTrue(result.coverage.contains { $0.detail.contains("Podman") })
    }

    // MARK: Folder binding

    func cacheStep(_ folder: URL) throws -> CleanupStep {
        let (targets, _) = FileSizes.manifest(FileSizes.realPath(folder.path)!)
        var s = step(targets, action: .clearFolder(Command("go", ["clean", "-cache"]), root: folder.path, .mac), kind: .goBuildCache)
        s.item.scopeGuard = .folder(try XCTUnwrap(FileSizes.directoryIdentity(folder.path)))
        return s
    }

    func cacheFolder() throws -> URL {
        let folder = home.appending(path: "go-build")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appending(path: "a").path, contents: Data(repeating: 1, count: 8_000))
        return folder
    }

    func goTools(_ folder: URL, clearing: Bool = false) -> FakeTools {
        FakeTools([
            { $0 == "go env GOCACHE" ? ToolOutput(status: 0, stdout: folder.path + "\n") : nil },
            { line in
                guard line == "go clean -cache" else { return nil }
                if clearing { try? FileManager.default.removeItem(at: folder) }
                return ToolOutput(status: 0, stdout: "")
            },
        ])
    }

    func testAFileAddedAfterThePreviewSkipsTheClear() async throws {
        let folder = try cacheFolder()
        let s = try cacheStep(folder)
        FileManager.default.createFile(atPath: folder.appending(path: "unreviewed").path, contents: Data([1]))
        let tools = goTools(folder)
        let result = await executor(tools).perform(s, previewTime: .now)
        guard case .skipped(let why) = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertTrue(why.contains("1 file appeared"))
        XCTAssertFalse(tools.calls.contains("go clean -cache"))
    }

    func testAFileRewrittenInPlaceDoesntSkipTheClear() async throws {
        let folder = try cacheFolder()
        let s = try cacheStep(folder)
        let handle = try FileHandle(forWritingTo: folder.appending(path: "a"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([9]))   // same file, new contents (like an index or trim stamp)
        try handle.close()
        let result = await executor(goTools(folder, clearing: true)).perform(s, previewTime: .now)
        XCTAssertTrue(result.outcome.isDone, "\(result.outcome)")
    }

    func testTheNpmStepChecksTheFolderNpmCleans() async throws {
        let cache = home.appending(path: "npm-cache"), cacache = cache.appending(path: "_cacache")
        try FileManager.default.createDirectory(at: cacache, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cacache.appending(path: "index").path, contents: Data(repeating: 1, count: 4_000))
        let (targets, _) = FileSizes.manifest(FileSizes.realPath(cacache.path)!)
        var s = step(targets, action: .clearFolder(Command("npm", ["cache", "clean", "--force"]), root: cacache.path, .mac), kind: .npmCache)
        s.item.scopeGuard = .folder(try XCTUnwrap(FileSizes.directoryIdentity(cacache.path)))
        // npm reports the cache folder; it cleans _cacache inside it. A log next to it isn't in scope.
        FileManager.default.createFile(atPath: cache.appending(path: "debug.log").path, contents: Data([1]))
        let tools = FakeTools([{ $0 == "npm config get cache" ? ToolOutput(status: 0, stdout: cache.path + "\n") : nil }])
        let result = await executor(tools).perform(s, previewTime: .now)
        XCTAssertTrue(result.outcome.isDone, "\(result.outcome)")
        XCTAssertTrue(tools.calls.contains("npm cache clean --force"))
    }

    func testAFileReplacedWithANewOneSkipsTheClear() async throws {
        let folder = try cacheFolder()
        let s = try cacheStep(folder)
        try FileManager.default.removeItem(at: folder.appending(path: "a"))
        FileManager.default.createFile(atPath: folder.appending(path: "a").path, contents: Data([2]))   // same name, new object
        let tools = goTools(folder)
        let result = await executor(tools).perform(s, previewTime: .now)
        guard case .skipped = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertFalse(tools.calls.contains("go clean -cache"))
    }

    func testASkippedCacheCanBeListedAgainAndThenRuns() async throws {
        let folder = try cacheFolder()
        let s = try cacheStep(folder)
        FileManager.default.createFile(atPath: folder.appending(path: "new").path, contents: Data([1]))
        let ctx = ScanContext(tools: FakeTools(), home: home.path, fullDiskAccess: true)
        let fresh = try await XCTUnwrapAsync(await LanguageCachesProvider.refreshed(s.item, ctx))
        XCTAssertEqual(fresh.id, s.item.id)
        XCTAssertTrue(fresh.targets.contains { $0.id.hasSuffix("/new") })
        let again = CleanupStep(item: fresh, ownerName: "O", approvedTargets: fresh.targets, expectedBytes: 1, destination: .mac)
        let result = await executor(goTools(folder, clearing: true)).perform(again, previewTime: .now)
        XCTAssertTrue(result.outcome.isDone, "\(result.outcome)")
    }

    func testAReplacedFolderSkipsTheClear() async throws {
        let folder = try cacheFolder()
        let s = try cacheStep(folder)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tools = goTools(folder)
        let result = await executor(tools).perform(s, previewTime: .now)
        XCTAssertEqual(result.outcome, .skipped(reason: "The folder was replaced since the scan."))
        XCTAssertFalse(tools.calls.contains("go clean -cache"))
    }

    func testAnUnchangedFolderIsClearedAndMeasured() async throws {
        let folder = try cacheFolder()
        let s = try cacheStep(folder)
        let result = await executor(goTools(folder, clearing: true)).perform(s, previewTime: .now)
        guard case .done(let measured?) = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertGreaterThan(measured, 0)
    }

    func testASymlinkAddedAfterThePreviewSkipsTheClear() async throws {
        let folder = try cacheFolder()
        let s = try cacheStep(folder)
        try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "link").path, withDestinationPath: "/etc")
        let tools = goTools(folder)
        let result = await executor(tools).perform(s, previewTime: .now)
        guard case .skipped = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertFalse(tools.calls.contains("go clean -cache"))
    }

    func testTheManifestListsEveryNameAndFolder() throws {
        let folder = try cacheFolder()
        try FileManager.default.createDirectory(at: folder.appending(path: "sub"), withIntermediateDirectories: true)
        XCTAssertEqual(link(folder.appending(path: "a").path, folder.appending(path: "sub/a2").path), 0)
        let names = Set(FileSizes.manifest(folder.path).targets.map { ($0.id as NSString).lastPathComponent })
        XCTAssertEqual(names, ["a", "sub", "a2"])
    }

    func testAHomebrewDryRunThatWouldDoMoreSkipsTheStep() async {
        let tools = FakeTools([{ $0 == "brew cleanup -n" ? ToolOutput(status: 0, stdout: "Would remove: /opt/homebrew/Cellar/a/1 (1MB)\nWould prune 3 symbolic links\n") : nil }])
        let s = step([Target("/opt/homebrew/Cellar/a/1")], action: .runAfterRecheck(Command("brew", ["cleanup"]), .mac), kind: .homebrewOldVersions)
        let result = await executor(tools).perform(s, previewTime: .now)
        guard case .skipped = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertFalse(tools.calls.contains("brew cleanup"))
    }

    // MARK: Measurement

    func testSimulatorsAreMeasuredByTheirFolders() async throws {
        let devices = home.appending(path: "Devices")
        try FileManager.default.createDirectory(at: devices.appending(path: "UDID-1"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: devices.appending(path: "UDID-1/data.img").path, contents: Data(repeating: 1, count: 50_000))
        var s = step([Target("UDID-1", bytes: 5_000)], action: .runOnTargets(Command("xcrun", ["simctl", "delete"]), .mac), kind: .simulatorsUnavailable)
        s.item.path = devices.path
        let tools = FakeTools([{ line in
            guard line == "xcrun simctl delete UDID-1" else { return nil }
            try? FileManager.default.removeItem(at: devices.appending(path: "UDID-1"))
            return ToolOutput(status: 0, stdout: "")
        }])
        let result = await executor(tools).perform(s, previewTime: .now)
        guard case .done(let measured?) = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertGreaterThanOrEqual(measured, 50_000, "measured from the folder, not the scan's 5,000 bytes")
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
        XCTAssertEqual(run.steps[1].outcome, .notRun(reason: "Not started because an earlier step failed or only partly succeeded."))
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

final class VolumeTests: XCTestCase {
    /// On this Mac: each volume reports its own used space, so together they fit in the
    /// container's (statfs reported the whole container for each one).
    func testVolumesFitInTheDisksUsedSpace() async throws {
        let disk = SystemProvider.diskUsage()
        let data = try XCTUnwrap(SystemProvider.volumeUsed("/System/Volumes/Data"))
        XCTAssertGreaterThan(data, 0)
        // Measured moments apart: allow for files the runner writes in between.
        XCTAssertEqual(Double(try XCTUnwrap(disk.dataVolumeUsed)), Double(min(data, disk.used)), accuracy: 1e9)
        let result = await SystemProvider().scan(ScanContext(tools: FakeTools(), home: NSTemporaryDirectory(), fullDiskAccess: true))
        let macos = try XCTUnwrap(result.owners.first { $0.id == "macos" })
        XCTAssertEqual(result.coverage.first?.status, .measured, result.coverage.first?.detail ?? "")
        let system = try XCTUnwrap(macos.items.first { $0.name == "System volume" }?.onDisk.bytes)
        XCTAssertGreaterThan(system, 1_000_000_000)
        XCTAssertLessThan(macos.onDisk + data, disk.used + disk.total / 50, "the volumes overlap: some report the container")
    }

    func testAFolderIsntAVolume() {
        XCTAssertTrue(SystemProvider.isMountPoint("/"))
        XCTAssertFalse(SystemProvider.isMountPoint(NSTemporaryDirectory()))
        XCTAssertNil(SystemProvider.volumeUsed("/System/Volumes/Data/private"))
    }
}

final class FolderMeasurementsTests: XCTestCase {
    var home: URL!
    let names = (1...10).map { "entry\($0)" }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "macstorage-home-\(UUID().uuidString)")
        for d in ["A", "B", "Downloads"] { try FileManager.default.createDirectory(at: home.appending(path: d), withIntermediateDirectories: true) }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    /// Lists `names` everywhere (after `listDelay`) and measures each entry in `delay`,
    /// stopping early when asked. Counts the reads.
    final class Disk: @unchecked Sendable {
        let lock = NSLock()
        var reads: [String] = []
        let names: [String], delay: TimeInterval, listDelay: TimeInterval
        init(names: [String], delay: TimeInterval = 0.002, listDelay: TimeInterval = 0) {
            self.names = names
            self.delay = delay
            self.listDelay = listDelay
        }

        var unlistable = false

        @MainActor func measurements(home: String, flush: Duration = .milliseconds(20)) -> FolderMeasurements {
            FolderMeasurements(home: home, list: { folder in
                self.lock.withLock { self.reads.append(folder) }
                Thread.sleep(forTimeInterval: self.listDelay)
                return self.unlistable ? nil : self.names
            }, measure: { name, _, _, options in
                let end = Date().addingTimeInterval(self.delay)
                while Date() < end { if options.stop?.isStopped == true { return nil }; Thread.sleep(forTimeInterval: 0.001) }
                return FolderEntry(name: name, bytes: 1_000, kind: .personalFiles, isFolder: false)
            }, flushInterval: flush)
        }
    }

    @MainActor func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(60)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor func testALevelIsListedAndMeasured() async throws {
        let m = Disk(names: names).measurements(home: home.path)
        m.open("~/A", owners: [], protected: [])
        try await waitUntil { m.levels["~/A"]?.isMeasuring == false }
        XCTAssertEqual(m.levels["~/A"]?.entries.map(\.name).sorted(), names.sorted())
        XCTAssertEqual(m.levels["~/A"]?.measured, 10)
        XCTAssertNil(m.measuring)
    }

    @MainActor func testLeavingPausesAndReturningResumesWithoutDuplicates() async throws {
        let m = Disk(names: names, delay: 0.03).measurements(home: home.path)
        m.open("~/A", owners: [], protected: [])
        try await waitUntil { (m.levels["~/A"]?.measured ?? 0) >= 3 }
        m.open("~/B", owners: [], protected: [])
        let paused = try XCTUnwrap(m.levels["~/A"])
        XCTAssertFalse(paused.pending.isEmpty, "the rest of A waits")
        XCTAssertGreaterThanOrEqual(paused.entries.count, 3, "what A measured is kept")
        try await waitUntil { m.levels["~/B"]?.isMeasuring == false }
        m.open("~/A", owners: [], protected: [])
        try await waitUntil { m.levels["~/A"]?.isMeasuring == false }
        XCTAssertEqual(m.levels["~/A"]?.entries.map(\.name).sorted(), names.sorted(), "each entry once")
    }

    @MainActor func testForgottenLevelsDontComeBack() async throws {
        let m = Disk(names: names, delay: 0.03).measurements(home: home.path)
        m.open("~/A", owners: [], protected: [])
        try await waitUntil { (m.levels["~/A"]?.measured ?? 0) >= 1 }
        m.forget()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(m.levels.isEmpty, "late results of a forgotten level are dropped")
        XCTAssertNil(m.measuring)
    }

    @MainActor func testALevelLeftWhileListingIsDropped() async throws {
        let m = Disk(names: names, listDelay: 0.2).measurements(home: home.path)
        m.open("~/A", owners: [], protected: [])
        m.open("~/B", owners: [], protected: [])
        XCTAssertNil(m.levels["~/A"])
        try await waitUntil { m.levels["~/B"]?.isMeasuring == false }
        XCTAssertNil(m.levels["~/A"], "its listing arriving late doesn't bring it back")
    }

    @MainActor func testAFolderReplacedByALinkMidLevelStopsThere() async throws {
        let fm = FileManager.default
        let m = Disk(names: names, delay: 0.03).measurements(home: home.path)
        m.open("~/A", owners: [], protected: [])
        try await waitUntil { (m.levels["~/A"]?.measured ?? 0) >= 2 }
        try fm.moveItem(at: home.appending(path: "A"), to: home.appending(path: "A-moved"))
        try fm.createSymbolicLink(atPath: home.appending(path: "A").path, withDestinationPath: home.appending(path: "B").path)
        try await waitUntil { m.levels["~/A"]?.problem != nil }
        XCTAssertEqual(m.levels["~/A"]?.problem, .notAFolder)
        XCTAssertNil(m.measuring)
    }

    func testMergedEntriesStayLargestFirst() {
        func e(_ n: String, _ b: Int64?) -> FolderEntry { FolderEntry(name: n, bytes: b, kind: .apps) }
        let merged = FolderMeasurements.merge([e("a", 9), e("b", 5), e("c", nil)], [e("d", 7), e("e", 1)])
        XCTAssertEqual(merged.map(\.name), ["a", "d", "b", "e", "c"])
    }

    @MainActor func testReturningWithinAFlushRecordsEachEntryOnce() async throws {
        // The paused run's last batch arrives after the resumed run has started.
        let m = Disk(names: names, delay: 0.02).measurements(home: home.path, flush: .milliseconds(300))
        m.open("~/A", owners: [], protected: [])
        try await Task.sleep(for: .milliseconds(100))
        m.open("~/B", owners: [], protected: [])
        m.open("~/A", owners: [], protected: [])
        try await waitUntil { m.levels["~/A"]?.isMeasuring == false }
        XCTAssertEqual(m.levels["~/A"]?.entries.map(\.name).sorted(), names.sorted())
    }

    @MainActor func testAFolderThatCantBeListedSaysSo() async throws {
        let disk = Disk(names: names)
        disk.unlistable = true
        let m = disk.measurements(home: home.path)
        m.open("~/A", owners: [], protected: [])
        try await waitUntil { m.levels["~/A"]?.problem != nil }
        XCTAssertEqual(m.levels["~/A"]?.problem, .unreadable)
        XCTAssertNil(m.measuring)
    }

    @MainActor func testAnEntryMeasuredWhileItsFolderWasReplacedIsDiscarded() async throws {
        let a = home.appending(path: "A"), moved = home.appending(path: "A-moved"), elsewhere = home.appending(path: "B").path
        // The swap happens during the second entry's walk.
        let m = FolderMeasurements(home: home.path, list: { _ in ["one", "two", "three"] }, measure: { name, _, _, _ in
            if name == "two" {
                try? FileManager.default.moveItem(at: a, to: moved)
                try? FileManager.default.createSymbolicLink(atPath: a.path, withDestinationPath: elsewhere)
            }
            return FolderEntry(name: name, bytes: 1_000, kind: .personalFiles, isFolder: false)
        }, flushInterval: .milliseconds(10))
        m.open("~/A", owners: [], protected: [])
        try await waitUntil { m.levels["~/A"]?.problem != nil }
        XCTAssertEqual(m.levels["~/A"]?.problem, .notAFolder)
        XCTAssertTrue(m.levels["~/A"]?.entries.isEmpty ?? true, "nothing measured through the link is shown")
    }

    @MainActor func testALargeFolderIsMeasuredCompletely() async throws {
        // Real files: 20,000 entries listed, measured, merged and counted.
        let big = home.appending(path: "A")
        for i in 0..<20_000 { FileManager.default.createFile(atPath: big.appending(path: "f\(i)").path, contents: Data([1])) }
        let m = FolderMeasurements(home: home.path, flushInterval: .milliseconds(250))
        let started = Date()
        m.open("~/A", owners: [], protected: [])
        try await waitUntil { m.levels["~/A"]?.isMeasuring == false }
        XCTAssertEqual(m.levels["~/A"]?.entries.count, 20_000)
        XCTAssertEqual(m.levels["~/A"]?.measured, 20_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 60)
    }

    @MainActor func testARefusedFolderIsNeverRead() async throws {
        let disk = Disk(names: names)
        let m = disk.measurements(home: home.path)
        m.open("~/Downloads", owners: [], protected: [home.appending(path: "Downloads").path])
        m.open("~/missing", owners: [], protected: [])
        XCTAssertEqual(m.levels["~/Downloads"]?.problem, .needsFullDiskAccess)
        XCTAssertEqual(m.levels["~/missing"]?.problem, .notAFolder)
        XCTAssertTrue(disk.lock.withLock { disk.reads.isEmpty })
    }
}

final class ScannerTests: XCTestCase {
    struct Slow: Provider {
        let area = "Slow"
        func scan(_ ctx: ScanContext) async -> ProviderResult {
            while !ctx.stop.isStopped { try? await Task.sleep(for: .milliseconds(20)) }
            return ProviderResult()
        }
    }

    struct Quick: Provider {
        let area = "Quick"
        func scan(_ ctx: ScanContext) async -> ProviderResult {
            let fact = Fact(.appLogs, onDisk: .bytes(1_000), targets: [])
            return ProviderResult(owners: [Owner(id: "quick", name: "Quick", kind: .system, location: "", items: [Rules.item(fact)])],
                                  coverage: [CoverageEntry(area: area, status: .measured, detail: "")])
        }
    }

    final class Seen: @unchecked Sendable {
        let lock = NSLock()
        var progress: [ScanProgress] = []
    }

    func testAStoppedScanKeepsWhatFinishedAndMarksTheRest() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "scan-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let context = ScanContext(tools: FakeTools(), home: home.path, fullDiskAccess: true)
        let seen = Seen()
        let scan = Task { await Scanner(providers: [Quick(), Slow()]).scan(context) { p in seen.lock.withLock { seen.progress.append(p) } } }
        try await Task.sleep(for: .milliseconds(300))
        let partial = try XCTUnwrap(seen.lock.withLock { seen.progress.last }).partialSnapshot()
        XCTAssertEqual(partial.owners.map(\.id), ["quick"], "results appear as each area finishes")
        XCTAssertTrue(partial.isPartial)
        context.stop.stop()
        let result = await scan.value
        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(Set(result.unfinishedAreas), ["Folder sizes"])
    }
}

final class HistoryStoreTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "macstorage-store-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func bigRun() -> RunRecord {
        let targets = (0..<300).map { Target("/cache/file-\($0)", bytes: 1) }
        let item = Item(id: "o/big", kind: .goBuildCache, name: "Big", onDisk: .bytes(300), reclaimable: .bytes(300), tier: .safe,
                        explanation: "", targets: targets)
        let step = CleanupStep(item: item, ownerName: "O", approvedTargets: targets, expectedBytes: 300, destination: .mac)
        let executed = (0..<10).map { "tool --delete batch-\($0)" }
        return RunRecord(started: Date(timeIntervalSince1970: 1_800_000_000), finished: Date(timeIntervalSince1970: 1_800_000_100),
                         steps: [.init(step: step, outcome: .done(measured: 300), executed: executed)])
    }

    func testHistoryKeepsACompactCopyAndTheRunFileKeepsEverything() throws {
        let store = HistoryStore(folder: folder)
        let run = bigRun()
        let receipt = try XCTUnwrap(try store.save(run))
        let compact = try XCTUnwrap(store.loadHistory().runs.first)
        XCTAssertTrue(compact.isCompact)
        XCTAssertEqual(compact.steps[0].step.approvedTargets.count, 200)
        XCTAssertTrue(compact.steps[0].step.item.targets.isEmpty)
        XCTAssertEqual(compact.steps[0].executed.count, 4)
        let full = try XCTUnwrap(store.fullRun(run.id))
        XCTAssertFalse(full.isCompact)
        XCTAssertEqual(full.steps[0].step.approvedTargets, run.steps[0].step.approvedTargets)
        XCTAssertEqual(full.steps[0].executed, run.steps[0].executed)
        XCTAssertTrue(try String(contentsOf: receipt, encoding: .utf8).contains("/cache/file-299"))
    }

    func testAReceiptIsNeverRewrittenFromTheCompactCopy() throws {
        let store = HistoryStore(folder: folder)
        let run = bigRun()
        let written = try XCTUnwrap(try store.save(run))
        let compact = try XCTUnwrap(store.loadHistory().runs.first)
        XCTAssertEqual(try store.receipt(compact), written)
        XCTAssertTrue(try String(contentsOf: written, encoding: .utf8).contains("/cache/file-299"))
    }

    func testAJournaledRunThatNeverFinishedIsRecovered() throws {
        let store = HistoryStore(folder: folder)
        let run = bigRun()
        try store.journal(run)
        XCTAssertTrue(store.loadHistory().runs.isEmpty, "the journal doesn't touch history")
        XCTAssertEqual(store.recoverJournaledRuns().map(\.id), [run.id])
        XCTAssertEqual(store.loadHistory().runs.map(\.id), [run.id])
        XCTAssertTrue(store.recoverJournaledRuns().isEmpty)
    }

    func testHistoryCatchesUpWithANewerFullRecord() throws {
        let store = HistoryStore(folder: folder)
        var run = bigRun()
        try store.save(run)
        Thread.sleep(forTimeInterval: 0.05)
        run.trashDeletions.append(.init(date: .now, deleted: [], refused: ["/gone"]))
        try store.journal(run)   // the full record moved on; History still has the old copy
        XCTAssertEqual(store.loadHistory().runs.first?.trashDeletions.count, 0)
        XCTAssertEqual(store.recoverJournaledRuns().map(\.id), [run.id])
        XCTAssertEqual(store.loadHistory().runs.first?.trashDeletions.count, 1)
        XCTAssertTrue(store.recoverJournaledRuns().isEmpty, "nothing left to reconcile")
    }

    func testAnUnrelatedSaveDoesntHideAnOutOfDateCopy() throws {
        let store = HistoryStore(folder: folder)
        var run = bigRun()
        try store.save(run)
        run.trashDeletions.append(.init(date: .now, deleted: [], refused: ["/gone"]))
        try store.journal(run)                       // A's full record moves on
        Thread.sleep(forTimeInterval: 0.05)
        try store.save(Demo.snapshot())              // then something else rewrites history.json
        XCTAssertEqual(store.recoverJournaledRuns().map(\.id), [run.id])
        XCTAssertEqual(store.loadHistory().runs.first?.trashDeletions.count, 1)
    }

    func testAStaleReceiptIsWrittenAgainFromTheFullRecord() throws {
        let store = HistoryStore(folder: folder)
        var run = bigRun()
        let first = try XCTUnwrap(try store.save(run))
        Thread.sleep(forTimeInterval: 0.05)
        run.trashDeletions.append(.init(date: .now, deleted: [], refused: ["/gone"]))
        try store.save(run, receipt: false)   // the record moved on, the receipt didn't
        XCTAssertEqual(try store.receipt(run), first)
        XCTAssertTrue(try String(contentsOf: first, encoding: .utf8).contains("/gone"))
    }

    func testSavingACompactCopyNeverTruncatesTheFullRecord() throws {
        let store = HistoryStore(folder: folder)
        let run = bigRun()
        try store.save(run)
        var compact = try XCTUnwrap(store.loadHistory().runs.first)
        compact.trashDeletions.append(.init(date: .now, deleted: [], refused: ["/gone"]))
        try store.save(compact)   // e.g. a retry or a Trash deletion from History after a relaunch
        let full = try XCTUnwrap(store.fullRun(run.id))
        XCTAssertEqual(full.steps[0].step.approvedTargets.count, 300)
        XCTAssertEqual(full.steps[0].executed.count, 10)
        XCTAssertEqual(full.trashDeletions.count, 1)
    }

    func testAnUnreadableHistoryThatCantBeSetAsideIsNotOverwritten() throws {
        let store = HistoryStore(folder: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let history = folder.appending(path: "history.json")
        try Data("not json".utf8).write(to: history)
        try FileManager.default.createDirectory(at: folder.appending(path: "Runs"), withIntermediateDirectories: true)
        chmod(folder.path, 0o555)   // Runs stays writable; history.json can't be moved aside or replaced
        defer { chmod(folder.path, 0o755) }
        let run = bigRun()
        XCTAssertThrowsError(try store.save(run)) { XCTAssertTrue($0 is HistoryStore.StoreError, "\($0)") }
        XCTAssertNotNil(store.fullRun(run.id), "the full record was written; only the history step refused")
        XCTAssertEqual(try String(contentsOf: history, encoding: .utf8), "not json")
    }

    func testALaterTrashDeletionUpdatesTheFullRecord() throws {
        let store = HistoryStore(folder: folder)
        var run = bigRun()
        try store.save(run)
        run.trashDeletions.append(.init(date: .now, deleted: [], refused: ["/gone"]))
        try store.save(run)
        XCTAssertEqual(store.fullRun(run.id)?.trashDeletions.count, 1)
        XCTAssertEqual(store.loadHistory().runs.count, 1)
    }

    func testAnUnreadableHistoryIsMovedAsideNotOverwritten() throws {
        let store = HistoryStore(folder: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appending(path: "history.json"))
        XCTAssertEqual(store.loadHistory(), History())
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("history-unreadable-") }
        XCTAssertEqual(aside.count, 1)
    }
}

final class ShellTests: XCTestCase {
    func testOutputBeyondTheCapIsReportedAsTruncated() async throws {
        let out = try await Shell.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "head -c 20000000 /dev/zero"], environment: [:], timeout: .seconds(30))
        XCTAssertTrue(out.truncated)
        XCTAssertFalse(out.succeeded)
        XCTAssertLessThanOrEqual(out.stdout.utf8.count, Shell.maxOutputBytes)
    }

    func testATimeoutStopsTheProcess() async throws {
        let started = ContinuousClock.now
        let out = try await Shell.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], environment: [:], timeout: .milliseconds(300))
        XCTAssertTrue(out.timedOut)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
    }
}

final class RunningAppsTests: XCTestCase {
    func testCachesMatchByBundleIDNameOrVendor() {
        XCTAssertTrue(RunningApps.matches("com.tinyspeck.slackmacgap", bundleID: "com.tinyspeck.slackmacgap", name: "Slack"))
        XCTAssertTrue(RunningApps.matches("Google", bundleID: "com.google.Chrome", name: "Google Chrome"))
        XCTAssertTrue(RunningApps.matches("JetBrains", bundleID: "com.jetbrains.intellij", name: "IntelliJ IDEA"))
        XCTAssertTrue(RunningApps.matches("Slack", bundleID: "com.tinyspeck.slackmacgap", name: "Slack"))
        XCTAssertFalse(RunningApps.matches("ms-playwright", bundleID: "com.google.Chrome", name: "Google Chrome"))
        XCTAssertFalse(RunningApps.matches("com.google", bundleID: "com.googlex.app", name: "X"))
    }
}

final class ProviderTests: XCTestCase {
    func testBuildOutputWithTrackedFilesIsntOffered() async throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "repo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: repo) }
        for name in [".git", "dist", "node_modules"] {
            try FileManager.default.createDirectory(at: repo.appending(path: name), withIntermediateDirectories: true)
        }
        let tools = FakeTools([
            { $0.contains("status") ? ToolOutput(status: 0, stdout: "## main...origin/main\n") : nil },
            { $0.hasSuffix("ls-files -- dist") ? ToolOutput(status: 0, stdout: "dist/app.js\n") : nil },
        ])
        let checkout = await GitProvider().inspect(ScanContext(tools: tools, home: repo.path, fullDiskAccess: true), repo.path, isWorktree: false)
        XCTAssertEqual(checkout.buildOutput.map { ($0.target.id as NSString).lastPathComponent }, ["node_modules"], "a committed dist/ is source")
    }

    func testAFailedDockerListingLeavesItsItemOutAndSaysSo() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "docker-home-\(UUID().uuidString)")
        let tools = FakeTools([
            { $0.contains("context ls") ? ToolOutput(status: 0, stdout: #"{"Name":"c","DockerEndpoint":"unix:///tmp/d.sock"}"#) : nil },
            { $0.contains(" info ") ? ToolOutput(status: 0, stdout: "ENGINE1\tDocker engine\n") : nil },
            { $0.contains("system df") ? ToolOutput(status: 0, stdout: #"{"Type":"Images","TotalCount":"1","Active":"0","Size":"1GB","Reclaimable":"1GB (100%)"}"#) : nil },
            { $0.contains(" images ") ? ToolOutput(status: 1, stdout: "", stderr: "boom") : nil },
        ])
        let result = await DockerProvider().scan(ScanContext(tools: tools, home: home.path, fullDiskAccess: true))
        let kinds = result.owners.flatMap(\.items).map(\.kind)
        XCTAssertFalse(kinds.contains(.dockerUnusedImages), "no empty list presented as nothing to clean")
        XCTAssertTrue(result.coverage.contains { $0.status == .failed })
        XCTAssertTrue(result.owners.first?.hostSizeUnknown == true)
    }

    func testDeviceSupportSortsByOSVersion() {
        XCTAssertEqual(XcodeProvider.osVersion("/x/iOS DeviceSupport/iPhone15,2 17.10 (21C62)"), "17.10")
        XCTAssertEqual(["17.2", "17.10", "16.4"].sorted { $0.compare($1, options: .numeric) == .orderedDescending }, ["17.10", "17.2", "16.4"])
    }

    func testAppKeysStripTeamIDs() {
        XCTAssertEqual(LibraryProvider.appKey("HUAZ8B5R3S.dev.orbstack"), "dev.orbstack")
        XCTAssertEqual(LibraryProvider.appKey("group.com.docker"), "com.docker")
    }
}
