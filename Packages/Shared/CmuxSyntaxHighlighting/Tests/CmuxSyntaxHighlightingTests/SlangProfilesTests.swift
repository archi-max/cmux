@testable import CmuxSyntaxHighlighting
import Foundation
import Testing

@Suite struct SlangProfilesTests {
    @Test func buildFileTopsSourcesAndSkippedOptions() {
        let text = """
        // pipeline build
        --top mp_pipeline_tb  # wrapper
        -I hvl/include +incdir+rtl/inc
        +define+FOO=1 -DBAR=2 --std 1800-2017
        -f common.f
        --top=other_top
        rtl/cpu.sv "pkg/my types.sv" /* hvl/old.sv */ hvl/top_tb.sv
        """
        let file = SlangBuildFile.parse(text)
        #expect(file.tops == ["mp_pipeline_tb", "other_top"])
        #expect(file.commandFiles == ["common.f"])
        #expect(file.sources == ["rtl/cpu.sv", "pkg/my types.sv", "hvl/top_tb.sv"])
    }

    @Test func slashesInsidePathsAndEscapesStayWords() {
        let file = SlangBuildFile.parse("-DMSG=\\\"hi\\\" /abs/a.sv\n#comment line\nb.sv")
        #expect(file.sources == ["/abs/a.sv", "b.sv"])
    }

    @Test func sourcesOutsideTheRootAreReported() {
        let file = SlangBuildFile(sources: ["rtl/cpu.sv", "../../ece411-cp3-worktree/rtl/cpu.sv", "/home/u/ece411/x.sv", "/home/u/ece4110/y.sv"])
        let outside = file.sources(outside: "/home/u/ece411", baseDirectory: "/home/u/ece411/.slang")
        #expect(outside == ["/home/u/ece411-cp3-worktree/rtl/cpu.sv", "/home/u/ece4110/y.sv"])
    }

    @Test func listingParsesPathsAndBodies() {
        let output = "\n@@cmux-slang-profile /r/.slang/a.f\n--top a_tb\nx.sv\n\n@@cmux-slang-profile /h/.config/cmux-slang/r/b.f\n--top b_tb"
            + "\n@@cmux-slang-config /r/.slang/server.json\n\n@@cmux-slang-config /r/.slang/local/server.json\n{\"build\": \"a.f\", // mine\n}\n"
        let listing = SlangProfileCatalog.parseListing(output)
        let profiles = listing.profiles
        #expect(profiles.map(\.path) == ["/r/.slang/a.f", "/h/.config/cmux-slang/r/b.f"])
        #expect(profiles.map(\.buildFile.tops) == [["a_tb"], ["b_tb"]])
        #expect(profiles.map(\.name) == ["a", "b"])
        #expect(listing.configs == [
            .init(path: "/r/.slang/server.json", health: .empty),
            .init(path: "/r/.slang/local/server.json", health: .valid),
        ])
        #expect(SlangProfileCatalog.parseListing("") == .init())
    }

    @Test func listingCommandRunsInAShell() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("slang-profiles-\(UUID().uuidString)/my proj").path
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("slang-profiles-home-\(UUID().uuidString)").path
        defer {
            try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent)
            try? FileManager.default.removeItem(atPath: home)
        }
        let manager = FileManager.default
        try manager.createDirectory(atPath: root + "/.slang", withIntermediateDirectories: true)
        try manager.createDirectory(atPath: root + "/sim/deep", withIntermediateDirectories: true)
        try manager.createDirectory(atPath: root + "/.git", withIntermediateDirectories: true)
        try manager.createDirectory(atPath: home + "/.config/cmux-slang/my proj", withIntermediateDirectories: true)
        try "--top a_tb\n".write(toFile: root + "/.slang/a.f", atomically: true, encoding: .utf8)
        try "--top w_tb\n".write(toFile: root + "/sim/deep/w.f", atomically: true, encoding: .utf8)
        try "--top hidden\n".write(toFile: root + "/.git/h.f", atomically: true, encoding: .utf8)
        try "--top u_tb\n".write(toFile: home + "/.config/cmux-slang/my proj/u.f", atomically: true, encoding: .utf8)
        try "--top s_tb\n".write(toFile: home + "/.config/cmux-slang/my proj.f", atomically: true, encoding: .utf8)
        try Data().write(to: URL(fileURLWithPath: root + "/.slang/server.json"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SlangProfileCatalog.listingCommand(root: root)]
        process.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let remoteListing = SlangProfileCatalog.parseListing(String(decoding: data, as: UTF8.self))
        let remote = remoteListing.profiles
        #expect(remoteListing.configs == [.init(path: root + "/.slang/server.json", health: .empty)])
        let tops = Set(remote.flatMap(\.buildFile.tops))
        #expect(tops == ["a_tb", "w_tb", "u_tb", "s_tb"])
        #expect(remote.count == 4) // hidden folders other than .slang are not searched

        let localListing = SlangProfileCatalog.localListing(root: root, home: home)
        #expect(localListing.configs == remoteListing.configs)
        let local = localListing.profiles
        #expect(Set(local.flatMap(\.buildFile.tops)) == tops)
        #expect(local.count == 4)
    }

    @Test func autoPickMatchesTheDumpTopOrTheScopeBelowIt() {
        let a = SlangProfile(path: "/r/.slang/a.f", buildFile: .init(tops: ["mp_pipeline_tb"]))
        let b = SlangProfile(path: "/r/.slang/b.f", buildFile: .init(tops: ["cache_tb"]))
        let stray = SlangProfile(path: "/r/sim/old.f", buildFile: .init(tops: ["cache_tb"]))
        #expect(SlangProfileCatalog.profile(matchingDumpTops: ["mp_pipeline_tb"], children: [:], in: [a, b]) == a)
        #expect(SlangProfileCatalog.profile(matchingDumpTops: ["TOP"], children: ["TOP": ["cache_tb"]], in: [a, b]) == b)
        #expect(SlangProfileCatalog.profile(matchingDumpTops: ["cache_tb"], children: [:], in: [b, stray]) == b)
        #expect(SlangProfileCatalog.profile(matchingDumpTops: ["nothing"], children: [:], in: [a, b]) == nil)
        let twin = SlangProfile(path: "/r/.slang/c.f", buildFile: .init(tops: ["cache_tb"]))
        #expect(SlangProfileCatalog.profile(matchingDumpTops: ["cache_tb"], children: [:], in: [b, twin]) == nil)
    }

    @Test func serverConfigHealth() {
        #expect(SlangServerConfigFile.health(of: nil) == .missing)
        #expect(SlangServerConfigFile.health(of: Data()) == .empty)
        #expect(SlangServerConfigFile.health(of: Data(" \n".utf8)) == .empty)
        #expect(SlangServerConfigFile.health(of: Data("[1]".utf8)) == .invalid)
        #expect(SlangServerConfigFile.health(of: Data("{\"build\":".utf8)) == .invalid)
        #expect(SlangServerConfigFile.health(of: Data("{}".utf8)) == .valid)
        #expect(SlangServerConfigFile.health(of: Data("// flags\n{\"flags\": \"-DX\",}".utf8)) == .valid)
    }
}
