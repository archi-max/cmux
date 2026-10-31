@testable import CmuxSyntaxHighlighting
import Foundation
import Testing

@Suite struct SlangWorkspaceRootTests {
    static let file = "/home/u/class/ece411/mp_pipeline/rtl/cpu.sv"

    @Test func ancestorsStopBelowTheFilesystemRoot() {
        #expect(SlangWorkspaceRoot.ancestors(ofFile: "/a/b//c/./x.sv") == ["/a/b/c", "/a/b", "/a"])
        #expect(SlangWorkspaceRoot.ancestors(ofFile: "/x.sv").isEmpty)
    }

    @Test func theNearestServerConfigWins() {
        let markers = SlangWorkspaceRoot.Markers(
            config: ["/home/u/class/ece411/mp_pipeline", "/home/u/class"],
            git: ["/home/u/class/ece411/mp_pipeline/rtl", "/home/u/class/ece411"],
            home: "/home/u"
        )
        #expect(SlangWorkspaceRoot.root(forFile: Self.file, markers: markers) == "/home/u/class/ece411/mp_pipeline")
    }

    @Test func gitIsTheFallback() {
        let markers = SlangWorkspaceRoot.Markers(git: ["/home/u/class/ece411", "/home/u/class"], home: "/home/u")
        #expect(SlangWorkspaceRoot.root(forFile: Self.file, markers: markers) == "/home/u/class/ece411")
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
        let output = "H /home/u\nS /home/u/class/ece411/mp_pipeline\nG /home/u/class/ece411\nG /home/u/a b\n\njunk\n"
        let markers = SlangWorkspaceRoot.parseProbe(output)
        #expect(markers.home == "/home/u")
        #expect(markers.config == ["/home/u/class/ece411/mp_pipeline"])
        #expect(markers.git == ["/home/u/class/ece411", "/home/u/a b"])
    }

    @Test func theProbeRunsInAShell() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cmux-root-\(UUID().uuidString)/it's here")
        let rtl = root.appendingPathComponent("rtl")
        try FileManager.default.createDirectory(at: rtl, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".slang"), withIntermediateDirectories: true)
        try "{}".write(to: root.appendingPathComponent(".slang/server.json"), atomically: true, encoding: .utf8)
        try "gitdir: elsewhere".write(to: rtl.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let file = rtl.appendingPathComponent("cpu.sv").path
        // ssh hands the command to the host's login shell, which need not be a POSIX one.
        for shell in ["/bin/sh", "/bin/zsh", "/bin/csh"] {
            let (status, output) = try Self.run(SlangWorkspaceRoot.probeCommand(forFile: file), shell: shell)
            let markers = SlangWorkspaceRoot.parseProbe(output)
            #expect(status == 0, "\(shell)")
            #expect(markers.config == [root.path], "\(shell)")
            #expect(markers.git == [rtl.path], "\(shell)")
            #expect(markers == SlangWorkspaceRoot.localMarkers(forFile: file, home: markers.home ?? ""), "\(shell)")
            #expect(SlangWorkspaceRoot.root(forFile: file, markers: markers) == root.path, "\(shell)")
        }
    }

    /// Runs `command` the way a login shell given it by ssh would; its status and stdout.
    static func run(_ command: String, shell: String, environment: [String: String]? = nil, input: Data? = nil) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try process.run()
        if let input {
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
