#if os(macOS)
import CmuxSyntaxHighlighting
import Foundation
import Testing

/// Driver tracing's design model sidecar (cmux-sv-model): the arguments cmux loads a design
/// with, the dump/design prefixes the page maps fan-in paths with, and the client against a
/// fake sidecar (a shell script speaking the protocol) and, when one is built, the real one
/// (`CMUX_SV_MODEL_BIN`, as `run.sh sv-model` builds it).
@Suite struct SVModelSidecarTests {
    // MARK: Load arguments

    @Test func buildFileLoadsWithItsFileList() {
        let args = SVModelLoad.arguments(target: .buildFile("/w/cpu.f"), configBuild: nil, root: "/w")
        #expect(args == ["-f", "/w/cpu.f"])
    }

    @Test func configBuildIsRelativeToTheRoot() {
        #expect(SVModelLoad.arguments(target: nil, configBuild: "sim/files.f", root: "/w") == ["-f", "/w/sim/files.f"])
        #expect(SVModelLoad.arguments(target: nil, configBuild: "/abs/files.f", root: "/w") == ["-f", "/abs/files.f"])
    }

    @Test func buildRelativePathsReadsTheFileListRelativeToItself() {
        #expect(SVModelLoad.arguments(target: nil, configBuild: "adapter_tb.f", buildRelativePaths: true, root: "/w") == ["-F", "/w/adapter_tb.f"])
    }

    @Test func aChosenTargetWinsOverTheConfig() {
        #expect(SVModelLoad.arguments(target: .buildFile("/w/a.f"), configBuild: "b.f", root: "/w") == ["-f", "/w/a.f"])
    }

    @Test func topLevelFileFindsOtherModulesInTheRootByName() {
        let args = SVModelLoad.arguments(target: .topLevel("/w/rtl/tb.sv"), configBuild: nil, root: "/w")
        #expect(args == ["/w/rtl/tb.sv", "-y", "/w/rtl", "-y", "/w", "--libext", ".sv", "--libext", ".v", "--libext", ".svh"])
    }

    @Test func nothingChosenIsNil() {
        #expect(SVModelLoad.arguments(target: nil, configBuild: nil, root: "/w") == nil)
        #expect(SVModelLoad.arguments(target: nil, configBuild: "  ", root: "/w") == nil)
    }

    // MARK: Prefixes

    @Test func samePathsHaveNoPrefixes() {
        let p = SVModelLoad.prefixes(dumpPath: ["tb", "dut", "x"], designPath: ["tb", "dut", "x"])
        #expect(p.designPrefix == "" && p.dumpPrefix == "")
    }

    @Test func aWrapperScopeIsTheDumpPrefix() {
        let p = SVModelLoad.prefixes(dumpPath: ["TOP", "tb", "dut", "x"], designPath: ["tb", "dut", "x"])
        #expect(p.designPrefix == "" && p.dumpPrefix == "TOP")
    }

    @Test func aRenamedTopMapsWholeSegments() {
        let p = SVModelLoad.prefixes(dumpPath: ["top_tb", "dut", "x"], designPath: ["cpu", "x"])
        #expect(p.designPrefix == "cpu" && p.dumpPrefix == "top_tb.dut")
        let q = SVModelLoad.prefixes(dumpPath: ["tb", "u0", "x"], designPath: ["tb", "dut", "x"])
        #expect(q.designPrefix == "tb.dut" && q.dumpPrefix == "tb.u0")
    }

    // MARK: Install directory

    @Test func versionHashesTheFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("svm-version-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a".utf8).write(to: dir.appendingPathComponent("build.sh"))
        let first = SVModelSidecar.version(of: dir)
        #expect(first.count == 16)
        try Data("b".utf8).write(to: dir.appendingPathComponent("build.sh"))
        #expect(SVModelSidecar.version(of: dir) != first)
    }

    // MARK: Client against a fake sidecar

    /// A sidecar that answers each request line with `{"id":N,"ok":true,"echo":"<cmd>"}`, or an
    /// error for cmd "bad", after some shell noise before its ready line.
    static let fakeScript = """
    printf 'Welcome to the host\\n'
    printf '{"id":0,"ready":true,"model":1}\\n'
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
      cmd=$(printf '%s' "$line" | sed -n 's/.*"cmd":"\\([a-z]*\\)".*/\\1/p')
      if [ "$cmd" = bad ]; then printf '{"id":%s,"ok":false,"error":"noInstance","message":"nope"}\\n' "$id"
      elif [ "$cmd" = quit ]; then exit 3
      else printf '{"id":%s,"ok":true,"echo":"%s"}\\n' "$id" "$cmd"; fi
    done
    """

    static func fake(_ script: String = fakeScript) -> SVModelSidecar {
        SVModelSidecar(
            runner: { command in .init(executable: "/bin/sh", arguments: ["-c", command]) },
            launchCommand: script,
            installCommand: nil
        )
    }

    @Test func requestsGetTheirOwnReplies() async throws {
        let sidecar = Self.fake()
        defer { sidecar.stop() }
        async let a = sidecar.request(["cmd": "alpha"])
        async let b = sidecar.request(["cmd": "beta"])
        let (ra, rb) = try await (a, b)
        #expect(ra["echo"] as? String == "alpha")
        #expect(rb["echo"] as? String == "beta")
    }

    @Test func anErrorReplyThrowsItsCode() async throws {
        let sidecar = Self.fake()
        defer { sidecar.stop() }
        await #expect(throws: SVModelSidecar.Failure.request(code: "noInstance", message: "nope")) {
            _ = try await sidecar.request(["cmd": "bad"])
        }
        // Still usable afterwards.
        #expect(try await sidecar.request(["cmd": "again"])["echo"] as? String == "again")
    }

    @Test func anExitFailsWaitingRequests() async throws {
        let sidecar = Self.fake()
        defer { sidecar.stop() }
        await #expect(throws: SVModelSidecar.Failure.self) {
            _ = try await sidecar.request(["cmd": "quit"])
        }
    }

    /// A session that can't start (the Verdi engine's launcher without a KDB or a licence seat)
    /// says why on its ready line and exits at once: requests get that code, not "exited".
    @Test func aRefusedReadyLineThrowsItsCode() async throws {
        for _ in 0..<5 {
            let sidecar = Self.fake(#"printf '\n{"id":0,"ready":false,"error":"licence","message":"no seat"}\n'; exit 0"#)
            defer { sidecar.stop() }
            await #expect(throws: SVModelSidecar.Failure.request(code: "licence", message: "no seat")) {
                _ = try await sidecar.request(["cmd": "info"])
            }
        }
    }

    /// The Verdi engine's launch command carries both scripts and an awkward FSDB path through
    /// `sh -c '…'` (as cmux runs it over SSH), and the launcher's scratch folder goes away after.
    @Test func verdiLaunchCommandCarriesScriptsAndPath() async throws {
        let launcher = Data(#"""
        W=$1
        trap 'rm -rf "$W"' EXIT
        printf '{"id":0,"ready":true,"path":"%s","serve":"%s","dir":"%s"}\n' "$2" "$(cat "$W/serve.tcl")" "$W"
        read -r line
        printf '{"id":1,"ok":true}\n'
        """#.utf8)
        let path = "/tmp/a b/it's $HOME (1).fsdb"
        let command = VerdiTraceLaunch.command(launcher: launcher, serve: Data("serve-ok".utf8), fsdbPath: path)
        #expect(!command.contains("'"))
        let sidecar = SVModelSidecar(
            runner: { command in .init(executable: "/bin/sh", arguments: ["-c", "sh -c '\(command)'"]) },
            launchCommand: command,
            installCommand: nil
        )
        defer { sidecar.stop() }
        _ = try await sidecar.request(["cmd": "info"])
        let ready = try #require(sidecar.lastReady)
        #expect(ready["path"] as? String == path)
        #expect(ready["serve"] as? String == "serve-ok")
        let dir = try #require(ready["dir"] as? String)
        #expect(dir.hasPrefix("/tmp/cmux-verdi-trace."))
        sidecar.stop()
        for _ in 0..<40 where FileManager.default.fileExists(atPath: dir) { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(!FileManager.default.fileExists(atPath: dir))
    }

    @Test func unitsMatchNeedsEqualNonEmptyUnits() {
        #expect(VerdiTraceLaunch.unitsMatch(.init(object: ["fileUnit": "1ps", "windowUnit": "1ps"])))
        #expect(!VerdiTraceLaunch.unitsMatch(.init(object: ["fileUnit": "1ps", "windowUnit": "1ns"])))
        #expect(!VerdiTraceLaunch.unitsMatch(.init(object: ["fileUnit": "", "windowUnit": ""])))
    }

    @Test func notInstalledRunsTheInstallThenLaunchesAgain() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("svm-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("installed").path
        let launch = "[ -f '\(marker)' ] || exit 87\n" + Self.fakeScript
        let sidecar = SVModelSidecar(
            runner: { command in .init(executable: "/bin/sh", arguments: ["-c", command]) },
            launchCommand: launch,
            installCommand: "mkdir -p '\(dir.path)' && touch '\(marker)'"
        )
        defer { sidecar.stop() }
        let statuses = StatusLog()
        sidecar.onStatus = { statuses.append($0) }
        #expect(try await sidecar.request(["cmd": "hi"])["echo"] as? String == "hi")
        #expect(statuses.all == [.connecting, .building, .connecting])
    }

    @Test func aFailedInstallReportsItsExitCode() async throws {
        let sidecar = SVModelSidecar(
            runner: { command in .init(executable: "/bin/sh", arguments: ["-c", command]) },
            launchCommand: "exit 87",
            installCommand: "echo 'no cmake here' >&2; exit 20"
        )
        defer { sidecar.stop() }
        await #expect(throws: SVModelSidecar.Failure.setupFailed(code: 20, detail: "no cmake here")) {
            _ = try await sidecar.request(["cmd": "hi"])
        }
    }

    // MARK: The real sidecar

    @Test func realSidecarLoadsTheTraceFixture() async throws {
        guard let bin = ProcessInfo.processInfo.environment["CMUX_SV_MODEL_BIN"], FileManager.default.isExecutableFile(atPath: bin) else { return }
        let designs = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../../scripts/waveform-viewer-checks/trace/designs").standardizedFileURL.path
        let sidecar = SVModelSidecar(
            runner: { command in .init(executable: "/bin/sh", arguments: ["-c", command]) },
            launchCommand: "exec '\(bin)'",
            installCommand: nil
        )
        defer { sidecar.stop() }
        let load = try await sidecar.request(["cmd": "load", "args": ["--top", "tb_c", "c_struct.sv", "tb_c.sv"], "cwd": designs])
        #expect(load["tops"] as? [String] == ["tb_c"])
        let lookup = try await sidecar.request(["cmd": "lookup", "path": "tb_c.dut.u_mid.u_sink.in"])
        #expect(lookup["instance"] as? String == "tb_c.dut.u_mid.u_sink")
        let instances = try await sidecar.request(["cmd": "instances"])
        #expect((instances["instances"] as? [String])?.contains("tb_c.dut.u_src") == true)
        let model = try await sidecar.request(["cmd": "instance", "path": "tb_c.dut.u_src"])
        #expect((model["model"] as? [String: Any])?["module"] as? String == "c_src")
    }
}

private final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SVModelSidecar.Status] = []
    func append(_ status: SVModelSidecar.Status) { lock.withLock { items.append(status) } }
    var all: [SVModelSidecar.Status] { lock.withLock { items } }
}
#endif
