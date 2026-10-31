@testable import CmuxSyntaxHighlighting
import Foundation
import Testing

@Suite struct SlangWorkspaceRootTests {
    static let file = "/home/u/work/proj/design_a/rtl/cpu.sv"

    @Test func ancestorsStopBelowTheFilesystemRoot() {
        #expect(SlangWorkspaceRoot.ancestors(ofFile: "/a/b//c/./x.sv") == ["/a/b/c", "/a/b", "/a"])
        #expect(SlangWorkspaceRoot.ancestors(ofFile: "/x.sv").isEmpty)
    }

    @Test func theNearestServerConfigWins() {
        let markers = SlangWorkspaceRoot.Markers(
            config: ["/home/u/work/proj/design_a", "/home/u/work"],
            git: ["/home/u/work/proj/design_a/rtl", "/home/u/work/proj"],
            home: "/home/u"
        )
        #expect(SlangWorkspaceRoot.root(forFile: Self.file, markers: markers) == "/home/u/work/proj/design_a")
    }

    @Test func gitIsTheFallback() {
        let markers = SlangWorkspaceRoot.Markers(git: ["/home/u/work/proj", "/home/u/work"], home: "/home/u")
        #expect(SlangWorkspaceRoot.root(forFile: Self.file, markers: markers) == "/home/u/work/proj")
    }

    @Test func homeNeverCountsAndNoMarkerGivesNil() {
        let markers = SlangWorkspaceRoot.Markers(config: ["/home/u"], git: ["/home/u"], home: "/home/u/")
        #expect(SlangWorkspaceRoot.root(forFile: Self.file, markers: markers) == nil)
        #expect(SlangWorkspaceRoot.root(forFile: Self.file, markers: .init()) == nil)
    }

    @Test func topLevelFoldersNeverCount() {
        // A shared host's stray /tmp/.git must not make /tmp the workspace.
        let markers = SlangWorkspaceRoot.Markers(config: ["/home"], git: ["/tmp"], home: "/home/u")
        #expect(SlangWorkspaceRoot.root(forFile: "/tmp/me/mp/rtl/cpu.sv", markers: markers) == nil)
        #expect(SlangWorkspaceRoot.root(forFile: "/home/u2/x.sv", markers: markers) == nil)
        #expect(SlangWorkspaceRoot.root(forFile: "/tmp/me/x.sv", markers: .init(git: ["/tmp/me"])) == "/tmp/me")
    }

    @Test func probeOutputRoundTrips() {
        let output = "H /home/u\nS /home/u/work/proj/design_a\nG /home/u/work/proj\nG /home/u/a b\n\njunk\n"
        let markers = SlangWorkspaceRoot.parseProbe(output)
        #expect(markers.home == "/home/u")
        #expect(markers.config == ["/home/u/work/proj/design_a"])
        #expect(markers.git == ["/home/u/work/proj", "/home/u/a b"])
    }

    @Test func theProbeRunsInAShell() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cmux-root-\(UUID().uuidString)/it's here")
        let rtl = root.appendingPathComponent("rtl")
        try FileManager.default.createDirectory(at: rtl, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".slang"), withIntermediateDirectories: true)
        try "{}".write(to: root.appendingPathComponent(".slang/server.json"), atomically: true, encoding: .utf8)
        try "gitdir: elsewhere".write(to: rtl.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let file = rtl.appendingPathComponent("cpu.sv").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SlangWorkspaceRoot.probeCommand(forFile: file)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let markers = SlangWorkspaceRoot.parseProbe(output)
        #expect(process.terminationStatus == 0)
        #expect(markers.config == [root.path])
        #expect(markers.git == [rtl.path])
        #expect(markers == SlangWorkspaceRoot.localMarkers(forFile: file, home: markers.home ?? ""))
        #expect(SlangWorkspaceRoot.root(forFile: file, markers: markers) == root.path)
    }
}
