import Darwin
import StorageCore
@testable import StorageMac
import XCTest

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
    }

    func testHardLinksCountOnce() throws {
        let a = dir.appending(path: "a").path
        FileManager.default.createFile(atPath: a, contents: Data(repeating: 1, count: 1 << 20))
        XCTAssertEqual(link(a, dir.appending(path: "b").path), 0)
        XCTAssertEqual(FileSizes.measure(dir.path).files, 1)
    }
}

final class CleanupSafetyTests: XCTestCase {
    func step(_ paths: [String]) -> CleanupStep {
        let item = Item(id: "test", name: "Test", onDisk: .bytes(1), reclaimable: .bytes(1), tier: .safe, explanation: "",
                        action: .moveToTrash, targets: paths.map { Target($0) })
        return CleanupPlan(snapshot: Snapshot(date: .now, scanDuration: 0, disk: DiskUsage(total: 1, free: 1, purgeable: 0, dataVolumeUsed: 1),
                                              owners: [Owner(id: "o", name: "O", kind: .system, location: "", items: [item])], coverage: []),
                           selected: ["test"], picks: [:]).steps[0]
    }

    func testNothingOutsideTheHomeFolderIsMovedToTheTrash() async {
        let executor = CleanupExecutor(shell: Shell(tools: ToolLocator(searchPath: [], commandLineToolsInstalled: false)), home: "/nonexistent-home")
        let result = await executor.perform(step(["/etc/hosts", "/nonexistent-home/../etc/hosts"]), previewTime: .now)
        XCTAssertEqual(result.outcome, .failed(error: "/etc/hosts is outside your home folder"))
        XCTAssertTrue(result.executed.isEmpty)
    }

    func testTrashDeletionRefusesAnythingOutsideTheTrash() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "keep-\(UUID().uuidString)").path
        FileManager.default.createFile(atPath: file, contents: Data([1]))
        defer { try? FileManager.default.removeItem(atPath: file) }
        XCTAssertTrue(CleanupExecutor.deleteFromTrash([file, NSHomeDirectory() + "/.Trash/../Documents"]).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file))
    }

    func testMovedFilesCanBeDeletedFromTheTrashAgain() async throws {
        let home = NSHomeDirectory()
        let file = home + "/macstorage-test-\(UUID().uuidString).tmp"
        FileManager.default.createFile(atPath: file, contents: Data(repeating: 2, count: 1_000))
        let executor = CleanupExecutor(shell: Shell(tools: ToolLocator(searchPath: [], commandLineToolsInstalled: false)), home: home)
        let result = await executor.perform(step([file]), previewTime: .now)
        XCTAssertTrue(result.outcome.didRun)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
        XCTAssertEqual(CleanupExecutor.deleteFromTrash(result.trashLocations), result.trashLocations)
    }
}
