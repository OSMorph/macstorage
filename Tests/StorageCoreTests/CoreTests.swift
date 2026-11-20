import XCTest
@testable import StorageCore

final class RulesTests: XCTestCase {
    func testReviewItemsNeverRunCommandsOrClaimSavings() {
        for kind in ItemKind.allCases {
            let item = Rules.item(Fact(kind, onDisk: .bytes(1_000)))
            guard item.tier == .review else { continue }
            XCTAssertFalse(item.action.isAutomatic, "\(kind) is Review but automatic")
            XCTAssertEqual(item.reclaimable, .unknown, "\(kind) is Review but claims savings")
            if case .runOnTargets = item.action { XCTFail("\(kind) runs a command") }
        }
    }

    func testIrreversibleDockerDeletesAreHandedToTheUser() {
        for kind in [ItemKind.dockerUnusedVolumes, .dockerStoppedContainers] {
            let item = Rules.item(Fact(kind, onDisk: .bytes(1), targets: [Target("a"), Target("b")]))
            guard case .userRunsCommand(let cmd, _) = item.action else { return XCTFail("\(kind) not handed over") }
            XCTAssertTrue(cmd.hasSuffix(" a b"), "command lists every target: \(cmd)")
        }
    }

    func testPnpmIsNotRunBecauseItsScopeIsUnknownInAdvance() {
        let item = Rules.item(Fact(.pnpmStore, onDisk: .bytes(2), reclaimable: .bytes(1)))
        XCTAssertFalse(item.isAutomaticCleanup)
        XCTAssertTrue(item.reclaimableIsUpperBound)
    }

    func testEveryAutomaticActionHasADestination() {
        for kind in ItemKind.allCases {
            let item = Rules.item(Fact(kind, onDisk: .bytes(1)))
            if item.action.isAutomatic { XCTAssertNotNil(item.action.destination, "\(kind)") }
        }
    }
}

final class CommandTests: XCTestCase {
    func testDisplayShowsTheTargetCountAndPreviewTime() {
        let c = Command("docker", ["builder", "prune", "--filter", "until=\(Command.previewTimeToken)"])
        XCTAssertEqual(c.display(targets: 737, unit: "cache record"), "docker builder prune --filter until=<time of this preview> <737 cache records: the list below>")
        XCTAssertEqual(Command("nix-store", ["--delete"]).display(targets: 1, unit: "store path"), "nix-store --delete <1 store path: the list below>")
    }

    func testResolvedArgumentsFillInThePreviewTime() {
        let c = Command("docker", ["--filter", "until=\(Command.previewTimeToken)"])
        let args = c.resolvedArguments(previewTime: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(args, ["--filter", "until=1970-01-01T00:00:00Z"])
    }
}

final class AccountingTests: XCTestCase {
    let snapshot = Demo.snapshot()

    func testTotalsAreSplitByDestination() {
        let safe = Accounting(snapshot).reclaimable(tier: .safe)
        XCTAssertGreaterThan(safe[.mac], 0)
        XCTAssertGreaterThan(safe[.trash], 0)
        XCTAssertEqual(safe[.containerDisk], Demo.gb(21.5))
    }

    func testUserRunItemsAreNotCounted() {
        let acc = Accounting(snapshot)
        XCTAssertTrue(acc.userRunItems(tier: .safe).contains { $0.id == "pnpmStore" })
        let safe = acc.reclaimable(tier: .safe)
        XCTAssertFalse(safe.includesUpperBound, "pnpm's upper bound must not leak into the app's totals")
    }

    func testCleanedItemsLeaveTheTotals() {
        let before = Accounting(snapshot).reclaimable(tier: .safe)[.mac]
        let after = Accounting(snapshot, cleaned: ["goModuleCache"]).reclaimable(tier: .safe)[.mac]
        XCTAssertEqual(before - after, Demo.gb(10.5))
        XCTAssertEqual(Accounting(snapshot, cleaned: ["goModuleCache", "goBuildCache"]).reclaimableLabel(owner: snapshot.owner("go")!), .cleaned)
    }

    func testReclaimableLabels() {
        let acc = Accounting(snapshot)
        XCTAssertEqual(acc.reclaimableLabel(owner: snapshot.owner("downloads")!), .unknown)
        XCTAssertEqual(acc.reclaimableLabel(owner: snapshot.owner("macos")!), .none)
        guard case .bytes(_, true, _) = acc.reclaimableLabel(owner: snapshot.owner("docker")!) else { return XCTFail("Docker should be inside its disk") }
    }

    func testUnattributedExcludesOwnVolumes() {
        let onData = snapshot.owners.filter { !$0.isOwnVolume }.map(\.onDisk).reduce(0, +)
        XCTAssertEqual(snapshot.unattributed, snapshot.disk.dataVolumeUsed - onData)
    }
}

final class CleanupPlanTests: XCTestCase {
    let snapshot = Demo.snapshot()

    func testOnlySelectedAutomaticItemsAndPickedFilesBecomeSteps() {
        let picks = ["downloads": [Target("~/Downloads/Docker.dmg", bytes: 600_000_000)]]
        let plan = CleanupPlan(snapshot: snapshot, selected: ["goBuildCache", "dockerUnusedVolumes", "pnpmStore"], picks: picks)
        XCTAssertEqual(plan.steps.map(\.id), ["goBuildCache", "downloads"], "volumes and pnpm are never automatic")
        XCTAssertEqual(plan.pickedSteps.count, 1)
        XCTAssertEqual(plan.expected(.trash), 600_000_000)
    }

    func testPicksOutsideTheItemAreIgnored() {
        let plan = CleanupPlan(snapshot: snapshot, selected: [], picks: ["downloads": [Target("/etc/passwd")]])
        XCTAssertTrue(plan.steps.isEmpty)
    }

    func testStepsAreOrderedByTierAndSkipCleanedItems() {
        let plan = CleanupPlan(snapshot: snapshot, selected: ["dockerUnusedImages", "nixDeadPaths", "goModuleCache"], picks: [:], cleaned: ["goModuleCache"])
        XCTAssertEqual(plan.steps.map(\.item.tier), [.safe, .probablySafe])
        XCTAssertFalse(plan.steps.contains { $0.id == "goModuleCache" })
    }
}

final class RunRecordTests: XCTestCase {
    func makeRun() -> RunRecord {
        let s = Demo.snapshot()
        let plan = CleanupPlan(snapshot: s, selected: ["goBuildCache", "dockerBuildCache"],
                               picks: ["downloads": [Target("~/Downloads/Docker.dmg", bytes: 600_000_000)]])
        let steps = plan.steps.map { step -> RunRecord.StepResult in
            switch step.id {
            case "goBuildCache": .init(step: step, outcome: .done(freedBytes: 3_000_000_000), executed: ["go clean -cache"])
            case "dockerBuildCache": .init(step: step, outcome: .skipped(reason: "The target list changed since the preview."), executed: [])
            default: .init(step: step, outcome: .notRun, executed: [])
            }
        }
        return RunRecord(started: Demo.scanDate, finished: Demo.scanDate, steps: steps)
    }

    func testFreedIsSplitAndSkipsCountNothing() {
        let run = makeRun()
        XCTAssertEqual(run.doneCount, 1)
        XCTAssertEqual(run.freed(.mac), 3_000_000_000)
        XCTAssertEqual(run.freed(.containerDisk), 0)
        XCTAssertTrue(run.movedToTrash.isEmpty, "the Downloads step didn't run")
    }

    func testReceiptLeadsWithOutcomeAndSeparatesPlannedFromExecuted() {
        let text = Receipt.text(makeRun())
        XCTAssertTrue(text.contains("DONE · Go · Build cache"))
        XCTAssertTrue(text.contains("SKIPPED · Docker Desktop · Build cache"))
        XCTAssertTrue(text.contains("NOT RUN · Downloads"))
        XCTAssertTrue(text.contains("Planned, not executed:\n    ~/Downloads/Docker.dmg"))
    }

    func testTrashDeletionIsItsOwnEvent() {
        var run = makeRun()
        run.trashDeletions.append(.init(date: Demo.scanDate, paths: ["~/a"], bytes: 5, includedPickedFiles: false))
        XCTAssertEqual(run.deletedFromTrash, 5)
        XCTAssertTrue(Receipt.text(run).contains("deleted 1 item (5 bytes) from the Trash permanently:\n    ~/a"))
    }
}

final class HistoryTests: XCTestCase {
    let history = Demo.history()

    func testNotesOnlyAppearForTheirInterval() {
        let recent = history.changes(from: 7, to: 8).first { $0.ownerID == "docker" }
        XCTAssertEqual(recent?.notes, ["New builds of 4 projects"])
        let early = history.changes(from: 0, to: 3).first { $0.ownerID == "docker" }
        XCTAssertEqual(early?.notes, [])
    }

    func testComparingAScanWithItselfIsEmpty() {
        XCTAssertTrue(history.changes(from: 4, to: 4).isEmpty)
    }

    func testForecastNeedsFourWeeksAndStatesItsBaseline() {
        XCTAssertNil(History(scans: Array(history.scans.prefix(3))).forecast())
        let f = history.forecast()
        XCTAssertNotNil(f)
        XCTAssertEqual(f?.basedOn.upperBound, Demo.scanDate)
    }
}

final class ParserTests: XCTestCase {
    func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testDockerSizes() {
        XCTAssertEqual(Parse.dockerSize("8.252GB"), 8_252_000_000)
        XCTAssertEqual(Parse.dockerSize("432kB"), 432_000)
        XCTAssertEqual(Parse.dockerSize("7.49GB (90%)"), 7_490_000_000)
        XCTAssertEqual(Parse.dockerSize("0B"), 0)
        XCTAssertNil(Parse.dockerSize("lots"))
    }

    func testDockerSystemDF() throws {
        let rows = Parse.dockerSystemDF(try fixture("docker-system-df.jsonl"))
        XCTAssertEqual(rows.map(\.type), ["Images", "Containers", "Local Volumes", "Build Cache"])
        XCTAssertEqual(rows[3].reclaimable, 21_450_000_000)
        XCTAssertEqual(rows[0].active, 21)
    }

    func testBrewCleanupDryRun() throws {
        let r = Parse.brewCleanup(try fixture("brew-cleanup-n.txt"))
        XCTAssertEqual(r.targets.map(\.id).first, "/opt/homebrew/Library/Homebrew/vendor/portable-ruby/3.3.4_1")
        XCTAssertEqual(r.targets.first?.bytes, 33_600_000)
        XCTAssertEqual(r.total, 240_500_000)
    }

    func testNixSizesAndPaths() {
        XCTAssertEqual(Parse.nixSizes("100\n200\n\n"), 300)
        XCTAssertEqual(Parse.paths("/nix/store/a\nfinding garbage\n/nix/store/b"), ["/nix/store/a", "/nix/store/b"])
    }
}

final class ByteFormatTests: XCTestCase {
    func testFormats() {
        XCTAssertEqual(ByteFormat.string(0), "0 bytes")
        XCTAssertEqual(ByteFormat.string(240_500_000), "241 MB")
        XCTAssertEqual(ByteFormat.string(16_740_000_000), "16.7 GB")
        XCTAssertEqual(ByteFormat.string(676_000_000_000), "676 GB")
    }
}
