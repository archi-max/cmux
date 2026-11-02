import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Go to File queries that name a path, and the per-root listing cache.
@Suite struct GoToFileTypedPathTests {
    @Test func aQueryStartingLikeAPathNamesOne() {
        #expect(GoToFileTypedPath.parse("~/.bashrc") == "~/.bashrc")
        #expect(GoToFileTypedPath.parse("  /etc/hosts ") == "/etc/hosts")
        #expect(GoToFileTypedPath.parse("./tb/top.sv") == "./tb/top.sv")
        #expect(GoToFileTypedPath.parse("../notes.md") == "../notes.md")
    }

    @Test func otherQueriesStillSearchTheListing() {
        #expect(GoToFileTypedPath.parse("alu") == nil)
        #expect(GoToFileTypedPath.parse(".gitignore") == nil, "a dotfile name is a search, not a path")
        #expect(GoToFileTypedPath.parse("hdl/alu.sv") == nil)
        #expect(GoToFileTypedPath.parse("~") == nil)
        #expect(GoToFileTypedPath.parse("~user/x") == nil, "another user's home is never looked up")
        #expect(GoToFileTypedPath.parse("~/") == nil, "a directory, not a file")
        #expect(GoToFileTypedPath.parse("/tmp/") == nil)
        #expect(GoToFileTypedPath.parse("/") == nil)
        #expect(GoToFileTypedPath.parse("/a\nb") == nil)
        #expect(GoToFileTypedPath.parse("") == nil)
    }

    @Test func aHomePathResolvesAgainstTheHostsHomeOnly() {
        #expect(GoToFileTypedPath.resolve("~/.bashrc", root: "/w", home: "/home/u") == "/home/u/.bashrc")
        #expect(GoToFileTypedPath.resolve("~/.bashrc", root: "/w", home: "/home/u/") == "/home/u/.bashrc")
        #expect(GoToFileTypedPath.resolve("~/.bashrc", root: "/w", home: nil) == nil)
        #expect(GoToFileTypedPath.resolve("~/.bashrc", root: "/w", home: "$HOME") == nil, "never a shell word")
        #expect(GoToFileTypedPath.needsHome("~/.bashrc"))
        #expect(!GoToFileTypedPath.needsHome("/etc/hosts"))
    }

    @Test func relativePathsResolveAgainstTheRootAndFoldDots() {
        #expect(GoToFileTypedPath.resolve("./tb/../rtl/alu.sv", root: "/w", home: nil) == "/w/rtl/alu.sv")
        #expect(GoToFileTypedPath.resolve("../notes.md", root: "/w/proj", home: nil) == "/w/notes.md")
        #expect(GoToFileTypedPath.resolve("/a/./b//c", root: "/w", home: nil) == "/a/b/c")
        #expect(GoToFileTypedPath.resolve("/../x", root: "/w", home: nil) == "/x")
        #expect(GoToFileTypedPath.resolve("./a", root: "/", home: nil) == "/a")
    }

    @Test func withoutAFilesRootATerminalOnTheHostStillOpensTypedPaths() {
        #expect(GoToFileTypedPath.paletteMode(hasFilesRoot: true, hasTerminalOnHost: true) == .listing)
        #expect(GoToFileTypedPath.paletteMode(hasFilesRoot: true, hasTerminalOnHost: false) == .listing)
        #expect(GoToFileTypedPath.paletteMode(hasFilesRoot: false, hasTerminalOnHost: true) == .typedPathsOnly)
        #expect(GoToFileTypedPath.paletteMode(hasFilesRoot: false, hasTerminalOnHost: false) == nil)
    }

    @Test func relativePathsUseTheTerminalsLiveDirectory() {
        #expect(GoToFileTypedPath.relativeRoot(live: "/home/u/proj/tb", fallback: "/home/u") == "/home/u/proj/tb")
        #expect(GoToFileTypedPath.relativeRoot(live: nil, fallback: "/home/u") == "/home/u")
        #expect(GoToFileTypedPath.relativeRoot(live: "proj", fallback: "/home/u") == "/home/u", "not absolute")
        #expect(GoToFileTypedPath.resolve("./a.sv", root: "", home: nil) == nil, "no directory to resolve against")
        #expect(GoToFileTypedPath.resolve("/etc/hosts", root: "", home: nil) == "/etc/hosts")
    }

    private final class Clock: @unchecked Sendable {
        var now = ContinuousClock.now
    }

    private final class Counter: @unchecked Sendable {
        var count = 0
    }

    private struct Failed: Error, Equatable {}

    @MainActor
    @Test func aListingIsReusedForItsLifetimeAndDroppedByARefresh() async throws {
        let clock = Clock()
        let loads = Counter()
        let cache = ExpiringValueCache<String, Int>(lifetime: .seconds(45), now: { clock.now })
        let load: () async throws -> Int = { loads.count += 1; return loads.count }
        let first = try await cache.value(for: "/w", load: load)
        #expect(first == 1)
        clock.now = clock.now.advanced(by: .seconds(30))
        let reopened = try await cache.value(for: "/w", load: load)
        #expect(reopened == 1, "reopened within the lifetime")
        let other = try await cache.value(for: "/other", load: load)
        #expect(other == 2, "per root")
        clock.now = clock.now.advanced(by: .seconds(16))
        let expired = try await cache.value(for: "/w", load: load)
        #expect(expired == 3, "expired")
        cache.invalidateAll()
        let refreshed = try await cache.value(for: "/w", load: load)
        #expect(refreshed == 4, "a Files refresh lists again")
    }

    @MainActor
    private final class Gate {
        private var waiter: CheckedContinuation<Void, Never>?
        private(set) var isWaiting = false
        func wait() async {
            await withCheckedContinuation { waiter = $0; isWaiting = true }
        }
        func open() {
            waiter?.resume()
            waiter = nil
        }
    }

    @MainActor
    @Test func aRefreshDuringAListingIsNotUndoneByIt() async throws {
        // A Files refresh lands while Go to File is still listing: the
        // pre-refresh listing reaches the caller but isn't kept for 45 s.
        let cache = ExpiringValueCache<String, Int>(lifetime: .seconds(45))
        let gate = Gate()
        let inFlight = Task { @MainActor in
            try await cache.value(for: "/w") { await gate.wait(); return 1 }
        }
        while !gate.isWaiting { await Task.yield() }
        cache.invalidateAll()
        gate.open()
        let stale = try await inFlight.value
        #expect(stale == 1, "the caller still gets what it asked for")
        let fresh = try await cache.value(for: "/w") { 2 }
        #expect(fresh == 2, "listed again after the refresh")
    }

    @MainActor
    @Test func aFailedListingIsNotKept() async throws {
        let cache = ExpiringValueCache<String, Int>(lifetime: .seconds(45))
        var threw = false
        do { _ = try await cache.value(for: "/w") { throw Failed() } } catch is Failed { threw = true }
        #expect(threw)
        let next = try await cache.value(for: "/w") { 7 }
        #expect(next == 7)
    }
}
