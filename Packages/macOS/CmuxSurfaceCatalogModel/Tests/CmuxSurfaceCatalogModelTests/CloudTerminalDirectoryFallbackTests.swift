import CmuxSurfaceCatalogModel
import Testing

@Suite struct CloudTerminalDirectoryFallbackTests {
    private func terminal(_ id: String, title: String, cwd: String? = "/home/u", cols: Int? = 80) -> CloudVMTerminalState {
        CloudVMTerminalState(id: id, tabIDs: ["tab-\(id)"], title: title, cwd: cwd, lifecycle: "running", cols: cols)
    }

    @Test func probesWhenShownAndOnEachTitleChangeOnly() throws {
        var fallback = CloudTerminalDirectoryFallback()
        let first = fallback.observe([terminal("t1", title: "bash")], projected: ["t1"])
        #expect(first.map(\.terminalID) == ["t1"])
        _ = fallback.finish(try #require(first.first), directory: "/home/u")
        // A resize is not a reason to ask again; a new title is.
        #expect(fallback.observe([terminal("t1", title: "bash", cols: 120)], projected: ["t1"]).isEmpty)
        #expect(fallback.observe([terminal("t1", title: "vim notes")], projected: ["t1"]).map(\.terminalID) == ["t1"])
    }

    @Test func titleChangesDuringAQueryQueueOneRerun() throws {
        var fallback = CloudTerminalDirectoryFallback()
        let probe = try #require(fallback.observe([terminal("t1", title: "a")], projected: ["t1"]).first)
        #expect(fallback.observe([terminal("t1", title: "b")], projected: ["t1"]).isEmpty)
        #expect(fallback.observe([terminal("t1", title: "c")], projected: ["t1"]).isEmpty)
        let done = fallback.finish(probe, directory: "/home/u/a")
        let rerun = try #require(done.next)
        #expect(rerun.terminalID == "t1")
        #expect(fallback.finish(rerun, directory: "/home/u/c").next == nil)
        #expect(fallback.directory(forTerminal: "t1") == "/home/u/c")
    }

    @Test func answerSetsTheDirectoryAndReportsChangesOnly() throws {
        var fallback = CloudTerminalDirectoryFallback()
        let probe = try #require(fallback.observe([terminal("t1", title: "a")], projected: ["t1"]).first)
        #expect(fallback.finish(probe, directory: "/srv/proj").directoryChanged)
        #expect(fallback.directory(forTerminal: "t1") == "/srv/proj")
        let again = try #require(fallback.observe([terminal("t1", title: "b")], projected: ["t1"]).first)
        #expect(!fallback.finish(again, directory: "/srv/proj").directoryChanged)
        // A failed query keeps the last answer.
        let failed = try #require(fallback.observe([terminal("t1", title: "c")], projected: ["t1"]).first)
        #expect(!fallback.finish(failed, directory: nil).directoryChanged)
        #expect(fallback.directory(forTerminal: "t1") == "/srv/proj")
    }

    @Test func aTerminalThatReportsItsDirectoryIsNeverAskedAgain() throws {
        var fallback = CloudTerminalDirectoryFallback()
        let probe = try #require(fallback.observe([terminal("t1", title: "a", cwd: "/home/u")], projected: ["t1"]).first)
        // The shell reported a cd: the graph cwd moved off the spawn directory.
        #expect(fallback.observe([terminal("t1", title: "b", cwd: "/home/u/src")], projected: ["t1"]).isEmpty)
        let late = fallback.finish(probe, directory: "/somewhere/else")
        #expect(!late.directoryChanged && late.next == nil)
        #expect(fallback.directory(forTerminal: "t1") == nil)
        #expect(fallback.observe([terminal("t1", title: "c", cwd: "/home/u")], projected: ["t1"]).isEmpty)
    }

    @Test func onlyShownTerminalsAreAskedAndGoneOnesAreForgotten() throws {
        var fallback = CloudTerminalDirectoryFallback()
        #expect(fallback.observe([terminal("t1", title: "a"), terminal("t2", title: "a")], projected: ["t2"]).map(\.terminalID) == ["t2"])
        #expect(fallback.observe([terminal("t1", title: "b"), terminal("t2", title: "a")], projected: ["t2"]).isEmpty)
        let shown = fallback.observe([terminal("t1", title: "b"), terminal("t2", title: "a")], projected: ["t1", "t2"])
        #expect(shown.map(\.terminalID) == ["t1"])
        let shownProbe = try #require(shown.first)
        // t1 closes while its query runs: the answer is dropped, and a new t1 starts fresh.
        #expect(fallback.observe([terminal("t2", title: "a")], projected: ["t2"]).isEmpty)
        #expect(!fallback.finish(shownProbe, directory: "/x").directoryChanged)
        #expect(fallback.directory(forTerminal: "t1") == nil)
        let reopened = fallback.observe([terminal("t1", title: "b"), terminal("t2", title: "a")], projected: ["t1", "t2"])
        #expect(reopened.map(\.terminalID) == ["t1"])
        let reopenedProbe = try #require(reopened.first)
        #expect(!fallback.finish(shownProbe, directory: "/stale").directoryChanged)
        #expect(fallback.finish(reopenedProbe, directory: "/fresh").directoryChanged)
        #expect(fallback.directory(forTerminal: "t1") == "/fresh")
    }

    @Test func repeatedFailuresStopTheQueries() throws {
        var fallback = CloudTerminalDirectoryFallback()
        var probes = fallback.observe([terminal("t1", title: "0")], projected: ["t1"])
        for round in 1...CloudTerminalDirectoryFallback.maximumFailedProbes {
            #expect(probes.count == 1, "round \(round)")
            guard let probe = probes.first else { return }
            _ = fallback.finish(probe, directory: nil)
            probes = fallback.observe([terminal("t1", title: "\(round)")], projected: ["t1"])
        }
        #expect(probes.isEmpty)
    }

    @Test func aSuccessResetsTheFailureCount() throws {
        var fallback = CloudTerminalDirectoryFallback()
        var title = 0
        func next() -> CloudTerminalDirectoryFallback.Probe? {
            title += 1
            return fallback.observe([terminal("t1", title: "\(title)")], projected: ["t1"]).first
        }
        let start = try #require(fallback.observe([terminal("t1", title: "0")], projected: ["t1"]).first)
        _ = fallback.finish(start, directory: nil)
        for _ in 1..<(CloudTerminalDirectoryFallback.maximumFailedProbes - 1) { if let p = next() { _ = fallback.finish(p, directory: nil) } }
        // The last allowed query succeeds instead.
        if let p = next() { _ = fallback.finish(p, directory: "/ok") }
        #expect(next() != nil)
    }
}
