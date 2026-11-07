#if os(macOS)
import CmuxSyntaxHighlighting
import Foundation
import Testing

/// A loaded design and the answers kept for it are bound to the sources slang read (the load's
/// fingerprint) and to the sidecar's design generation: an edit of the RTL or a file list, a
/// changed define or parameter, or a sidecar restart onto changed sources never mixes answers of
/// two designs; a load that can't say what it read fails instead of being trusted.
@Suite struct SVDesignSessionTests {
    // MARK: Against a fake sidecar

    /// A sidecar whose design is the text of `<dir>/fp` (empty: a load that names no sources),
    /// read at each load; `stale` says changed when `fp` differs from what was loaded, or once
    /// after `<dir>/touched` appears (a save that left the text as it was). Instance replies name
    /// the design they came from; each request is logged to `<dir>/log`.
    static func script(_ dir: URL) -> String {
        """
        D='\(dir.path)'
        printf '{"id":0,"ready":true,"model":1}\\n'
        loaded=
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          cmd=$(printf '%s' "$line" | sed -n 's/.*"cmd":"\\([a-z]*\\)".*/\\1/p')
          printf '%s\\n' "$cmd" >> "$D/log"
          fp=$(cat "$D/fp" 2>/dev/null)
          case "$cmd" in
          load) loaded=$fp
            if [ -n "$fp" ]; then printf '{"id":%s,"ok":true,"tops":["tb"],"messages":["m-%s"],"fingerprint":"%s"}\\n' "$id" "$fp" "$fp"
            else printf '{"id":%s,"ok":true,"tops":["tb"],"messages":[]}\\n' "$id"; fi ;;
          stale) c=false; [ "$fp" != "$loaded" ] && c=true
            if [ -f "$D/touched" ]; then rm -f "$D/touched"; c=true; fi
            printf '{"id":%s,"ok":true,"changed":%s}\\n' "$id" "$c" ;;
          instance) printf '{"id":%s,"ok":true,"model":{"src":"%s"}}\\n' "$id" "$loaded" ;;
          instances) printf '{"id":%s,"ok":true,"tops":["tb"],"instances":["tb","tb.%s"]}\\n' "$id" "$loaded" ;;
          lookup) printf '{"id":%s,"ok":true,"instance":"tb","name":"%s"}\\n' "$id" "$loaded" ;;
          quit) exit 3 ;;
          *) printf '{"id":%s,"ok":false,"error":"badCmd","message":""}\\n' "$id" ;;
          esac
        done
        """
    }

    final class Fake {
        let dir: URL
        let sidecar: SVModelSidecar
        let session: SVDesignSession

        init(_ fingerprint: String) throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("svdesign-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            sidecar = SVModelSidecar(
                runner: { command in .init(executable: "/bin/sh", arguments: ["-c", command]) },
                launchCommand: SVDesignSessionTests.script(dir),
                installCommand: nil
            )
            session = SVDesignSession(sidecar: sidecar, args: ["--top", "tb", "tb.sv"], cwd: dir.path)
            try set(fingerprint)
        }

        func set(_ fingerprint: String) throws { try Data(fingerprint.utf8).write(to: dir.appendingPathComponent("fp")) }
        func touch() throws { try Data().write(to: dir.appendingPathComponent("touched")) }
        func asked(_ cmd: String) -> Int {
            ((try? String(contentsOf: dir.appendingPathComponent("log"), encoding: .utf8)) ?? "")
                .split(separator: "\n").filter { $0 == cmd }.count
        }
        /// The sidecar exits (a crash, an ssh drop): the next request starts it and replays the load.
        func restart() async { _ = try? await sidecar.request(["cmd": "quit"]) }

        deinit {
            sidecar.stop()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test func answersAreKeptForTheDesignTheyCameFrom() async throws {
        let fake = try Fake("A")
        let loaded = try await fake.session.load()
        #expect(loaded.generation == fake.session.generation && loaded.generation > 0)
        #expect(loaded.messages == ["m-A"])
        let g = loaded.generation
        #expect(try await fake.session.model("tb", generation: g)?["src"] as? String == "A")
        #expect(try await fake.session.model("tb", generation: g)?["src"] as? String == "A")
        #expect(fake.asked("instance") == 1, "a model is asked once per design")
        #expect(try await fake.session.hierarchy(generation: g).instances == ["tb", "tb.A"])
        _ = try await fake.session.hierarchy(generation: g)
        #expect(fake.asked("instances") == 1)
    }

    /// A design's id names its session as well as its generation: a design evicted and made again
    /// under the same key (a new sidecar, generation 1 again) never answers to the old one's id,
    /// so a page never takes the old design's kept answers for the new one's (Refs #8).
    @Test func designIdsNeverRepeatAcrossSessions() async throws {
        let first = try Fake("A")
        let g1 = try await first.session.load().generation
        let second = try Fake("B")
        let g2 = try await second.session.load().generation
        #expect(g1 == g2, "both sidecars count from the same start")
        let id1 = first.session.designId(key: "k", generation: g1)
        let id2 = second.session.designId(key: "k", generation: g2)
        #expect(id1 != id2)
        #expect(second.session.generation(ofDesignId: id1, key: "k") == nil, "the old design's id is not the new one's")
        #expect(second.session.generation(ofDesignId: id2, key: "k") == g2)
        #expect(first.session.generation(ofDesignId: id1, key: "k") == g1)
        #expect(first.session.generation(ofDesignId: id1, key: "other") == nil)
        #expect(first.session.generation(ofDesignId: "k#" + String(g1), key: "k") == nil, "the old form names no session")
    }

    @Test func aRestartOntoEditedSourcesIsANewDesign() async throws {
        let fake = try Fake("A")
        let g = try await fake.session.load().generation
        _ = try await fake.session.model("tb", generation: g)
        _ = try await fake.session.hierarchy(generation: g)
        try fake.set("B")
        await fake.restart()
        // A trace of the old design asks again: the sidecar now answers for another one.
        await #expect(throws: SVDesignSession.Failure.designChanged) {
            _ = try await fake.session.lookup("tb.q", generation: g)
        }
        let now = fake.session.generation
        #expect(now > g)
        // The old design's answers are gone, not mixed into the new one's.
        await #expect(throws: SVDesignSession.Failure.designChanged) {
            _ = try await fake.session.model("tb", generation: g)
        }
        #expect(try await fake.session.model("tb", generation: now)?["src"] as? String == "B")
        #expect(try await fake.session.hierarchy(generation: now).instances == ["tb", "tb.B"])
        #expect(fake.session.loadMessages == ["m-B"])
    }

    @Test func aRestartOntoTheSameSourcesKeepsTheDesign() async throws {
        let fake = try Fake("A")
        let g = try await fake.session.load().generation
        _ = try await fake.session.model("tb", generation: g)
        await fake.restart()
        #expect(try await fake.session.lookup("tb.q", generation: g)?.instance == "tb")
        #expect(fake.session.generation == g)
        #expect(try await fake.session.model("tb", generation: g)?["src"] as? String == "A")
        #expect(fake.asked("instance") == 1, "the same sources' answers stay")
    }

    @Test func refreshLoadsEditedSourcesAgain() async throws {
        let fake = try Fake("A")
        let g = try await fake.session.load().generation
        _ = try await fake.session.model("tb", generation: g)
        #expect(try await fake.session.refresh() == false)
        #expect(fake.asked("load") == 1)
        try fake.set("B")
        #expect(try await fake.session.refresh() == true)
        let now = fake.session.generation
        #expect(now > g)
        #expect(try await fake.session.model("tb", generation: now)?["src"] as? String == "B")
        await #expect(throws: SVDesignSession.Failure.designChanged) {
            _ = try await fake.session.model("tb", generation: g)
        }
    }

    @Test func aSaveThatLeavesTheTextKeepsTheDesign() async throws {
        let fake = try Fake("A")
        let g = try await fake.session.load().generation
        _ = try await fake.session.model("tb", generation: g)
        try fake.touch()
        #expect(try await fake.session.refresh() == true, "loaded again")
        #expect(fake.session.generation == g, "the same fingerprint: the same design")
        _ = try await fake.session.model("tb", generation: g)
        #expect(fake.asked("instance") == 1)
    }

    @Test func aLoadThatCannotSayWhatItReadFails() async throws {
        let fake = try Fake("")
        await #expect(throws: SVDesignSession.Failure.noProvenance) {
            _ = try await fake.session.load()
        }
    }

    @Test func aRestartThatCannotSayWhatItReadIsNeverTrusted() async throws {
        let fake = try Fake("A")
        let g = try await fake.session.load().generation
        try fake.set("")
        await fake.restart()
        await #expect(throws: SVDesignSession.Failure.designChanged) {
            _ = try await fake.session.model("tb", generation: g)
        }
        await #expect(throws: SVDesignSession.Failure.noProvenance) {
            _ = try await fake.session.model("tb", generation: fake.session.generation)
        }
    }

    // MARK: The real sidecar

    final class Real {
        let dir: URL
        let bin: String
        var sidecars: [SVModelSidecar] = []

        init?() throws {
            guard let bin = ProcessInfo.processInfo.environment["CMUX_SV_MODEL_BIN"], FileManager.default.isExecutableFile(atPath: bin) else { return nil }
            self.bin = bin
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("svdesign-real-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        func session(_ args: [String]) -> SVDesignSession {
            let sidecar = SVModelSidecar(
                runner: { command in .init(executable: "/bin/sh", arguments: ["-c", command]) },
                launchCommand: "exec '\(bin)'",
                installCommand: nil
            )
            sidecars.append(sidecar)
            return SVDesignSession(sidecar: sidecar, args: args, cwd: dir.path)
        }

        /// Writes a file with a modification time `age` seconds from now (so an edit is seen
        /// even within the file system's time resolution).
        func write(_ name: String, _ text: String, age: TimeInterval = 0) throws {
            let url = dir.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(age)], ofItemAtPath: url.path)
        }

        deinit {
            sidecars.forEach { $0.stop() }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    static func signals(_ model: [String: Any]?) -> Set<String> {
        if let names = model?["signals"] as? [String: Any] { return Set(names.keys) }
        return Set((model?["signals"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
    }

    @Test func realSidecarSeesAnRTLEdit() async throws {
        guard let real = try Real() else { return }
        try real.write("top.sv", "module top(input logic clk); logic q; endmodule\n", age: -10)
        let session = real.session(["--top", "top", "top.sv"])
        let g = try await session.load().generation
        #expect(Self.signals(try await session.model("top", generation: g)) == ["clk", "q"])
        #expect(try await session.refresh() == false)
        try real.write("top.sv", "module top(input logic clk); logic q; logic y; endmodule\n")
        #expect(try await session.refresh() == true)
        let now = session.generation
        #expect(now > g)
        #expect(Self.signals(try await session.model("top", generation: now)) == ["clk", "q", "y"])
    }

    @Test func realSidecarSeesAFileListEdit() async throws {
        guard let real = try Real() else { return }
        try real.write("a.sv", "module top(input logic clk); logic a; endmodule\n", age: -10)
        try real.write("b.sv", "module top(input logic clk); logic b; endmodule\n", age: -10)
        try real.write("files.f", "a.sv\n", age: -10)
        let session = real.session(["--top", "top", "-f", "files.f"])
        let g = try await session.load().generation
        #expect(Self.signals(try await session.model("top", generation: g)) == ["clk", "a"])
        try real.write("files.f", "b.sv\n")
        #expect(try await session.refresh() == true)
        let now = session.generation
        #expect(now > g)
        #expect(Self.signals(try await session.model("top", generation: now)) == ["clk", "b"])
    }

    @Test func realSidecarSeesAnIncludedFileEdit() async throws {
        guard let real = try Real() else { return }
        try real.write("w.svh", "`define W 4\n", age: -10)
        try real.write("top.sv", "`include \"w.svh\"\nmodule top; logic [`W-1:0] q; endmodule\n", age: -10)
        let session = real.session(["--top", "top", "top.sv"])
        let g = try await session.load().generation
        try real.write("w.svh", "`define W 8\n")
        #expect(try await session.refresh() == true)
        #expect(session.generation > g)
    }

    @Test func realSidecarFingerprintsDefinesAndParameters() async throws {
        guard let real = try Real() else { return }
        try real.write("top.sv", "module top #(parameter int P = 1); logic [P-1:0] q; endmodule\n", age: -10)
        func fingerprint(_ extra: [String]) async throws -> String {
            let loaded = try await real.session(["--top", "top", "top.sv"] + extra).load()
            return loaded.fingerprint
        }
        let base = try await fingerprint([])
        #expect(try await fingerprint([]) == base, "the same sources and arguments: the same design")
        #expect(try await fingerprint(["-D", "W=4"]) != base)
        #expect(try await fingerprint(["-D", "W=4"]) != (try await fingerprint(["-D", "W=8"])))
        #expect(try await fingerprint(["-G", "P=2"]) != base)
    }

    @Test func realSidecarKeepsTheDesignOfASaveThatLeavesTheText() async throws {
        guard let real = try Real() else { return }
        let text = "module top(input logic clk); logic q; endmodule\n"
        try real.write("top.sv", text, age: -10)
        let session = real.session(["--top", "top", "top.sv"])
        let g = try await session.load().generation
        try real.write("top.sv", text)
        #expect(try await session.refresh() == true)
        #expect(session.generation == g)
    }
}
#endif
