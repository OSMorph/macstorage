import XCTest
@testable import ProbeCore

final class ScrubberTests: XCTestCase {
    private func makeScrubber() -> Scrubber {
        Scrubber(home: "/Users/jdoe", userName: "jdoe", hostNames: ["jdoe-mbp", "Jane's MacBook Pro"])
    }

    func testHomePathKeepsKnownComponentsAndHidesProjects() {
        let s = makeScrubber()
        let out = s.scrub("/Users/jdoe/Documents/projects/acme-billing/node_modules 1.2G")
        XCTAssertEqual(out, "/Users/USER/Documents/projects/dir-1/node_modules 1.2G")
    }

    func testSameFolderGetsSamePlaceholder() {
        let s = makeScrubber()
        let out = s.scrub("/Users/jdoe/src/acme/a\n/Users/jdoe/src/acme/b\n/Users/jdoe/src/other")
        XCTAssertEqual(out, "/Users/USER/src/dir-1/dir-2\n/Users/USER/src/dir-1/dir-3\n/Users/USER/src/dir-4")
    }

    func testDatedWorktreeKeepsItsDate() {
        let s = makeScrubber()
        let out = s.scrub("/Users/jdoe/Documents/projects/acme-worker-20261006")
        XCTAssertEqual(out, "/Users/USER/Documents/projects/dir-1-20261006")
    }

    func testSpacedLibraryNamesSurvive() {
        let s = makeScrubber()
        let out = s.scrub("/Users/jdoe/Library/Application Support/AcmeCorpAgent/cache.db")
        XCTAssertEqual(out, "/Users/USER/Library/Application Support/dir-1/cache.db")
    }

    func testDockerVMDiskPathIsKept() {
        let s = makeScrubber()
        let path = "/Users/jdoe/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
        XCTAssertEqual(s.scrub(path), "/Users/USER/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
    }

    func testSimilarHomePrefixIsNotTreatedAsHome() {
        let s = makeScrubber()
        XCTAssertEqual(s.scrub("/Users/jdoe2/x"), "/Users/jdoe2/x")
    }

    func testLearnedImageNamesAreReplaced() {
        let s = makeScrubber()
        s.learn("registry.acme.io/team/avworker", as: "image")
        s.learn("postgres", as: "image")          // official images are harmless
        let out = s.scrub("registry.acme.io/team/avworker   test-20261003   1.2GB\npostgres 16 400MB")
        XCTAssertEqual(out, "image-1   test-20261003   1.2GB\npostgres 16 400MB")
    }

    func testRedactedWordsAreCaseInsensitive() {
        let s = makeScrubber()
        s.redact(["Acme"])
        XCTAssertEqual(s.scrub("ACME internal tool, acme.io"), "redacted-1 internal tool, redacted-1.io")
    }

    func testUserHostEmailUUIDAndIP() {
        let s = makeScrubber()
        let input = "jdoe on jdoe-mbp (Jane's MacBook Pro) jane@acme.io 6F9619FF-8B86-D011-B42D-00C04FC964FF 192.168.1.20 127.0.0.1"
        let out = s.scrub(input)
        XCTAssertEqual(out, "USER on HOST (HOST) email-1 uuid-1 ip-1 127.0.0.1")
    }

    func testURLsAndGitRemotes() {
        let s = makeScrubber()
        let out = s.scrub("origin git@github.com:acme/billing.git (fetch)\nhttps://git.acme.io/x/y\nunix:///Users/jdoe/.orbstack/run/docker.sock")
        XCTAssertEqual(out, "origin url-1 (fetch)\nurl-2\nunix:///Users/USER/.orbstack/run/docker.sock")
    }

    func testVolumes() {
        let s = makeScrubber()
        XCTAssertEqual(s.scrub("/Volumes/Acme Backup and /Volumes/Macintosh HD"), "/Volumes/volume-1 Backup and /Volumes/Macintosh HD")
    }

    func testSummaryCountsWithoutOriginals() {
        let s = makeScrubber()
        _ = s.scrub("/Users/jdoe/src/acme jdoe")
        XCTAssertEqual(s.lastSummary["path"], 1)
        XCTAssertEqual(s.lastSummary["user"], 1)
    }

    func testScrubbingTwiceIsStable() {
        let s = makeScrubber()
        let once = s.scrub("/Users/jdoe/src/acme/x jane@acme.io")
        XCTAssertEqual(s.scrub(once), once)
    }
}

final class ScrubberAllowListTests: XCTestCase {
    func testProjectNamesThatContainToolNamesAreStillHidden() {
        let s = Scrubber(home: "/Users/jdoe", userName: "jdoe", hostNames: [])
        XCTAssertEqual(s.scrub("/Users/jdoe/src/climate-app"), "/Users/USER/src/dir-1")
    }

    func testLearnIgnoresWellKnownNames() {
        let s = Scrubber(home: "/Users/jdoe", userName: "jdoe", hostNames: [])
        s.learn("node_modules", as: "dir")
        s.learn("build", as: "dir")
        XCTAssertEqual(s.scrub("node_modules build"), "node_modules build")
    }
}
