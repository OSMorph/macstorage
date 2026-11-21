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

final class CompletenessTests: XCTestCase {
    func testAnIncompleteListHandsFolderClearingToTheUser() {
        var f = Fact(.goModuleCache, onDisk: .atLeast(10), targets: [Target("a")], root: "/r")
        f.targetsComplete = false
        let item = Rules.item(f)
        XCTAssertFalse(item.isAutomaticCleanup)
        XCTAssertFalse(item.targetsComplete)
        XCTAssertEqual(item.onDisk.bytes, 10)
        XCTAssertFalse(item.onDisk.isExact)
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
        XCTAssertTrue(acc.userRunItems(tier: .safe).contains { $0.id == "node/pnpmStore" })
        let safe = acc.reclaimable(tier: .safe)
        XCTAssertFalse(safe.includesUpperBound, "pnpm's upper bound must not leak into the app's totals")
    }

    func testCleanedItemsLeaveTheTotals() {
        let before = Accounting(snapshot).reclaimable(tier: .safe)[.mac]
        let after = Accounting(snapshot, cleaned: ["go/goModuleCache"]).reclaimable(tier: .safe)[.mac]
        XCTAssertEqual(before - after, Demo.gb(10.5))
        XCTAssertEqual(Accounting(snapshot, cleaned: ["go/goModuleCache", "go/goBuildCache"]).reclaimableLabel(owner: snapshot.owner("go")!), .cleaned)
    }

    func testReclaimableLabels() {
        let acc = Accounting(snapshot)
        XCTAssertEqual(acc.reclaimableLabel(owner: snapshot.owner("downloads")!), .unknown)
        XCTAssertEqual(acc.reclaimableLabel(owner: snapshot.owner("macos")!), .none)
        guard case .bytes(let r) = acc.reclaimableLabel(owner: snapshot.owner("docker")!), r[.containerDisk] > 0, r[.mac] == 0 else {
            return XCTFail("Docker's savings are inside its disk and never added to the Mac's")
        }
    }

    func testContainerEngineCountsItsVMDiskNotItsContents() {
        XCTAssertEqual(snapshot.owner("docker")?.onDisk, Demo.gb(50.1))
    }

    func testItemIDsAreUniqueAcrossOwners() {
        let a = Owner(id: "docker-a", name: "A", kind: .developerTools, location: "", items: [Rules.item(Fact(.dockerBuildCache, onDisk: .bytes(1)))])
        let b = Owner(id: "docker-b", name: "B", kind: .developerTools, location: "", items: [Rules.item(Fact(.dockerBuildCache, onDisk: .bytes(1)))])
        XCTAssertNotEqual(a.items[0].id, b.items[0].id)
        let ids = Demo.snapshot().owners.flatMap(\.items).map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testDuplicateOwnerIDsDontCrashHistory() {
        var s = snapshot
        s.owners.append(s.owners[0])
        XCTAssertEqual(ScanSummary(s).owners[s.owners[0].id], s.owners[0].onDisk * 2)
    }

    func testDiskSegmentsAddUpToTheDisk() {
        let s = Demo.snapshot()
        let segments = Accounting(s).diskSegments
        XCTAssertEqual(segments.map(\.bytes).reduce(0, +), s.disk.total)
        XCTAssertGreaterThan(segments.first { $0.id == "other" }!.bytes, 0, "space outside the Data volume is shown, not dropped")
    }

    func testAnEngineWhoseVMDiskWasntFoundIsntCountedOnTheMac() {
        var s = Demo.snapshot()
        let before = s.unattributed
        let i = s.owners.firstIndex { $0.id == "docker" }!
        let docker = s.owners[i]
        s.owners[i] = Owner(id: "docker", name: docker.name, kind: docker.kind, location: "", hostSizeUnknown: true, items: docker.items)
        XCTAssertEqual(s.owners[i].hostOnDisk, 0)
        XCTAssertEqual(s.owners[i].onDiskMeasure, .unknown)
        XCTAssertGreaterThan(s.unattributed, before, "its space is unattributed, not guessed from what's inside the VM")
        XCTAssertEqual(Accounting(s).diskSegments.map(\.bytes).reduce(0, +), s.disk.total)
    }

    func testOnHostLeavesOutDockersDisk() {
        var r = Reclaimable()
        r.byDestination = [.mac: 1, .trash: 2, .containerDisk: 4]
        XCTAssertEqual(r.onHost, 3)
    }

    func testUnattributedExcludesOwnVolumes() {
        let onData = snapshot.owners.filter { !$0.isOwnVolume }.map(\.onDisk).reduce(0, +)
        XCTAssertEqual(snapshot.unattributed, snapshot.disk.dataVolumeUsed - onData)
    }
}

final class CleanupPlanTests: XCTestCase {
    let snapshot = Demo.snapshot()

    func testOnlySelectedAutomaticItemsAndPickedFilesBecomeSteps() {
        let picks = ["downloads/downloads": [Target("~/Downloads/Docker.dmg", bytes: 600_000_000)]]
        let plan = CleanupPlan(snapshot: snapshot, selected: ["go/goBuildCache", "docker/dockerUnusedVolumes", "node/pnpmStore"], picks: picks)
        XCTAssertEqual(plan.steps.map(\.id), ["go/goBuildCache", "downloads/downloads"], "volumes and pnpm are never automatic")
        XCTAssertEqual(plan.pickedSteps.count, 1)
        XCTAssertEqual(plan.expected(.trash), 600_000_000)
    }

    func testPicksOutsideTheItemAreIgnored() {
        let plan = CleanupPlan(snapshot: snapshot, selected: [], picks: ["downloads/downloads": [Target("/etc/passwd")]])
        XCTAssertTrue(plan.steps.isEmpty)
    }

    func testStepsAreOrderedByTierAndSkipCleanedItems() {
        let plan = CleanupPlan(snapshot: snapshot, selected: ["docker/dockerUnusedImages", "nix/nixDeadPaths", "go/goModuleCache"], picks: [:], cleaned: ["go/goModuleCache"])
        XCTAssertEqual(plan.steps.map(\.item.tier), [.safe, .probablySafe])
        XCTAssertFalse(plan.steps.contains { $0.id == "go/goModuleCache" })
    }
}

final class RunRecordTests: XCTestCase {
    func makeRun() -> RunRecord {
        let s = Demo.snapshot()
        let plan = CleanupPlan(snapshot: s, selected: ["go/goBuildCache", "docker/dockerBuildCache"],
                               picks: ["downloads/downloads": [Target("~/Downloads/Docker.dmg")]])
        let steps = plan.steps.map { step -> RunRecord.StepResult in
            switch step.id {
            case "go/goBuildCache": .init(step: step, outcome: .done(measured: 2_900_000_000), executed: ["go clean -cache"])
            case "docker/dockerBuildCache": .init(step: step, outcome: .skipped(reason: "The list changed since the preview."))
            default: .init(step: step, outcome: .notRun(reason: "Cleanup was stopped before this step."))
            }
        }
        return RunRecord(started: Demo.scanDate, finished: Demo.scanDate, steps: steps)
    }

    func index(_ run: RunRecord, _ id: String) -> Int { run.steps.firstIndex { $0.step.id == id }! }

    func testFreedIsMeasuredAndSplitAndSkipsCountNothing() {
        let run = makeRun()
        XCTAssertEqual(run.doneCount, 1)
        XCTAssertEqual(run.freed(.mac), 2_900_000_000, "the re-measured figure, not the 3.0 GB prediction")
        XCTAssertEqual(run.freed(.containerDisk), 0)
        XCTAssertTrue(run.trashed.isEmpty, "the Downloads step didn't run")
    }

    func testUnmeasuredStepsAreReportedAsPredictions() {
        var run = makeRun()
        run.steps[index(run, "go/goBuildCache")].outcome = .done(measured: nil)
        XCTAssertEqual(run.freed(.mac), 0)
        XCTAssertEqual(run.unmeasured(.mac), Demo.gb(3))
        XCTAssertTrue(Receipt.text(run).contains("predicted 3.0 GB, not re-measured"))
    }

    func testReceiptLeadsWithOutcomeAndSeparatesPlannedFromExecuted() {
        let text = Receipt.text(makeRun())
        XCTAssertTrue(text.contains("DONE · Go · Build cache · 2.9 GB freed, measured"))
        XCTAssertTrue(text.contains("SKIPPED · Docker Desktop · Build cache"))
        XCTAssertTrue(text.contains("NOT RUN · Downloads · Downloads folder · Cleanup was stopped before this step."))
        XCTAssertTrue(text.contains("Planned, not executed:\n    ~/Downloads/Docker.dmg"))
    }

    func testPartialStepsKeepTheirProblemsAndStopTheRun() {
        XCTAssertTrue(StepOutcome.partial(measured: 1, problems: ["x"]).stopsRun)
        XCTAssertTrue(StepOutcome.failed(error: "x").stopsRun)
        XCTAssertFalse(StepOutcome.skipped(reason: "x").stopsRun)
        var run = makeRun()
        run.steps[index(run, "go/goBuildCache")].outcome = .partial(measured: 5, problems: ["batch 2 of 3: path is alive"])
        XCTAssertTrue(Receipt.text(run).contains("PARTLY DONE · Go · Build cache"))
        XCTAssertTrue(Receipt.text(run).contains("Problem: batch 2 of 3: path is alive"))
        XCTAssertTrue(Receipt.text(run).contains("Commands run:\n    go clean -cache"))
    }

    func testLeftAloneTargetsAreListedAndDontCountAsPlanned() {
        var run = makeRun()
        let i = index(run, "downloads/downloads")
        run.steps[i] = .init(step: run.steps[i].step, outcome: .skipped(reason: "Nothing on the approved list was still as you reviewed it."),
                             leftAlone: ["~/Downloads/Docker.dmg: replaced or changed since the scan."])
        let text = Receipt.text(run)
        XCTAssertTrue(text.contains("Left alone:\n    ~/Downloads/Docker.dmg: replaced or changed since the scan."))
        XCTAssertFalse(text.contains("Planned, not executed:\n    ~/Downloads/Docker.dmg"))
    }

    func testAFailedCommandIsListedAsRun() {
        var run = makeRun()
        let i = index(run, "go/goBuildCache")
        run.steps[i] = .init(step: run.steps[i].step, outcome: .failed(error: "boom"), executed: ["go clean -cache   [failed: boom]"])
        XCTAssertTrue(Receipt.text(run).contains("FAILED · Go · Build cache · boom\n  Commands run:\n    go clean -cache   [failed: boom]"))
    }

    func testCleanupStateSeparatesDonePartialAndPicks() {
        var run = makeRun()
        let picked = index(run, "downloads/downloads")
        run.steps[picked] = .init(step: run.steps[picked].step, outcome: .done(measured: 1),
                                  trashed: [TrashEntry(original: "~/Downloads/Docker.dmg", landed: "/t/Docker.dmg", identity: nil, bytes: 1, picked: true)])
        var partial = run.steps[index(run, "go/goBuildCache")]
        partial.step.item.id = "go/other"
        partial.outcome = .partial(measured: 1, problems: ["x"])
        run.steps.append(partial)
        let state = CleanupState(runs: [run], after: run.started.addingTimeInterval(-1))
        XCTAssertEqual(state.cleaned.keys.sorted(), ["go/goBuildCache"])
        XCTAssertEqual(state.partlyCleaned.keys.sorted(), ["go/other"], "a partial step isn't marked cleaned")
        XCTAssertEqual(state.removedPicks["downloads/downloads"], ["~/Downloads/Docker.dmg"])
        XCTAssertEqual(state.skipped, ["docker/dockerBuildCache"], "a skipped step stays unticked until a new scan, across relaunches")
        var leftSome = run
        leftSome.steps[index(run, "go/goBuildCache")].leftAlone = ["~/x: replaced or changed since the scan."]
        XCTAssertEqual(CleanupState(runs: [leftSome], after: .distantPast).partlyCleaned["go/goBuildCache"], run.id,
                       "done with targets left alone isn't fully cleaned")
        XCTAssertTrue(CleanupState(runs: [run], after: run.started).cleaned.isEmpty, "runs before the snapshot don't count")
        XCTAssertEqual(run.progressText, "2 of 4 steps done, 1 partly done")
    }

    func testAStepWithItemsLeftAloneIsPartlyDoneEverywhere() {
        var run = makeRun()
        let i = index(run, "go/goBuildCache")
        run.steps[i].leftAlone = ["~/x: replaced or changed since the scan."]
        XCTAssertEqual(run.summaryText, "0 of 3 steps done, 1 partly done, 1 skipped, 1 not run.")
        XCTAssertTrue(Receipt.text(run).contains("PARTLY DONE (some left alone) · Go · Build cache"))
    }

    func testATrashStepSkippedForARunningAppStaysTicked() {
        var run = makeRun()
        let i = index(run, "downloads/downloads")
        run.steps[i].outcome = .skipped(reason: "Slack is running.")
        XCTAssertFalse(CleanupState(runs: [run], after: .distantPast).skipped.contains("downloads/downloads"))
        run.steps[i].leftAlone = ["~/Downloads/Docker.dmg: replaced or changed since the scan."]
        XCTAssertTrue(CleanupState(runs: [run], after: .distantPast).skipped.contains("downloads/downloads"),
                      "every target changed: it can't succeed before a new scan")
    }

    func testLowerBoundsKeepTheirSignEvenAtZero() {
        let s = Demo.snapshot()
        var step = CleanupPlan(snapshot: s, selected: ["go/goBuildCache"], picks: [:]).steps[0]
        step.item.reclaimable = .atLeast(0)
        step.expectedBytes = 0
        XCTAssertEqual(step.expectedText, "≥ 0 bytes")
        step.item.reclaimable = .atLeast(5_000_000_000)
        step.expectedBytes = 5_000_000_000
        XCTAssertEqual(step.expectedText, "≥ 5.0 GB")
    }

    func testTrashDeletionIsItsOwnEventAndOnlyCountsDeletedEntries() {
        var run = makeRun()
        let mine = TrashEntry(original: "~/Downloads/a.iso", landed: "/t/a.iso", identity: nil, bytes: 7, picked: true)
        let cache = TrashEntry(original: "~/Library/Caches/x", landed: "/t/x", identity: nil, bytes: 5, picked: false)
        let i = index(run, "downloads/downloads")
        run.steps[i] = .init(step: run.steps[i].step, outcome: .done(measured: 12), trashed: [cache, mine])
        XCTAssertEqual(run.trashed.first, mine, "the user's own files come first")
        run.trashDeletions.append(.init(date: Demo.scanDate, deleted: [cache], refused: ["/t/gone"]))
        XCTAssertEqual(run.deletedFromTrash, 5)
        XCTAssertEqual(run.stillInTrash, [mine])
        let text = Receipt.text(run)
        XCTAssertTrue(text.contains("deleted 1 item (5 bytes) from the Trash permanently:\n    ~/Library/Caches/x"))
        XCTAssertTrue(text.contains("Refused (moved, replaced or restored since):\n    /t/gone"))
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

    func testAnUnmeasuredOwnerIsAGapNotAZero() {
        let day: TimeInterval = 86_400
        func scan(_ i: Double, _ docker: Int64?) -> ScanSummary {
            var s = ScanSummary(date: Date(timeIntervalSince1970: i * day), used: 100, free: 900,
                                owners: docker.map { ["docker": $0] } ?? [:], names: ["docker": "Docker"])
            if docker == nil { s.unmeasured = ["docker"] }
            return s
        }
        let h = History(scans: [scan(0, 50), scan(1, nil), scan(2, 50)])
        XCTAssertTrue(h.changes(from: 0, to: 1).isEmpty, "no 'shrank 50 GB' when it just wasn't measured")
        XCTAssertTrue(h.changes(from: 1, to: 2).isEmpty)
        XCTAssertTrue(h.changes(from: 0, to: 2).isEmpty, "no change across the gap")
        XCTAssertEqual(h.scans[1].size("docker"), nil)
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
        XCTAssertTrue(r.unrecognized.isEmpty)
    }

    func testBrewDryRunThatAnnouncesMoreThanRemovalsIsIncomplete() {
        let r = Parse.brewCleanup("Would remove: /opt/homebrew/Cellar/a/1 (3 files, 1MB)\nWould prune 2 symbolic links from /opt/homebrew\n==> Would autoremove 1 unneeded formula:\nlibfoo")
        XCTAssertEqual(r.targets.count, 1)
        XCTAssertEqual(r.unrecognized.count, 3)
        var fact = Fact(.homebrewOldVersions, onDisk: .bytes(1), targets: r.targets)
        fact.targetsComplete = false
        guard case .userRunsCommand = Rules.item(fact).action else { return XCTFail("an incomplete re-checked list is handed to the user") }
    }

    func testBuildxRecordsKeepInUseRecordsApart() throws {
        let records = Parse.buildxRecords(try fixture("buildx-du-verbose.txt"))
        XCTAssertEqual(records.map(\.id), ["uv9usm2hguieiwuudzlmxwowm", "k2j3h4g5f6d7s8a9q0w1e2r3t"])
        XCTAssertEqual(records.map(\.reclaimable), [true, false])
        XCTAssertEqual(records[0].bytes, 996_700_000)
    }

    func testBrewPathsMayContainParentheses() {
        let r = Parse.brewCleanup("Would remove: /Users/USER/Library/Caches/Homebrew/a (copy) (2).dmg (12.0MB)")
        XCTAssertEqual(r.targets.first?.id, "/Users/USER/Library/Caches/Homebrew/a (copy) (2).dmg")
        XCTAssertEqual(r.targets.first?.bytes, 12_000_000)
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
