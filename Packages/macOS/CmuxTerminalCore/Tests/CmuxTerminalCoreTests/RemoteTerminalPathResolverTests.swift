import CmuxTerminalCore
import Foundation
import Testing

@Suite struct RemoteTerminalPathResolverTests {
    private let resolver = RemoteTerminalPathResolver()

    @Test func tildeUsesRemoteHomeAndNeverTheMacHome() {
        #expect(resolver.candidates(
            tokens: ["~/notes.md"], workingDirectory: "/work", homeDirectory: "/srv/ssh-user", remoteHost: "host"
        ) == ["/srv/ssh-user/notes.md"])
        #expect(resolver.candidates(
            tokens: ["~/notes.md", "relative.txt"], workingDirectory: nil, homeDirectory: nil, remoteHost: "host"
        ).isEmpty)
    }

    @Test func resolvesSourceDirectoryWithoutCollapsingRemoteSymlinks() {
        #expect(resolver.candidates(
            tokens: ["linked/../notes.txt"], workingDirectory: "/remote/project", homeDirectory: nil, remoteHost: "host"
        ) == ["/remote/project/linked/../notes.txt"])
    }

    @Test func absolutePathsDoNotRequireDirectoryReports() {
        #expect(resolver.candidates(
            tokens: ["/remote/notes.txt"], workingDirectory: nil, homeDirectory: nil, remoteHost: "host"
        ) == ["/remote/notes.txt"])
    }

    @Test func fileURLsDecodeSpacesAndValidateTheRemoteHost() {
        #expect(resolver.candidates(
            tokens: ["file://host/remote/file%20name.txt"], workingDirectory: nil, homeDirectory: nil, remoteHost: "host"
        ) == ["/remote/file name.txt"])
        #expect(resolver.candidates(
            tokens: ["file://other/remote/notes.txt", "https://host/notes.txt"],
            workingDirectory: "/remote", homeDirectory: nil, remoteHost: "host"
        ).isEmpty)
    }

    @Test func literalPunctuationPrecedesTrimmedAndUnescapedCandidates() {
        let paths = resolver.candidates(
            tokens: ["notes\\ file.txt,"], workingDirectory: "/remote", homeDirectory: nil, remoteHost: "host"
        )
        #expect(paths.first == "/remote/notes\\ file.txt,")
        #expect(paths.contains("/remote/notes file.txt"))
        #expect(Set(paths).count == paths.count)
    }

    @Test func visibleColumnsKeepTheFullSpacedFilename() {
        let tokens = resolver.tokens(in: "alpha.txt  remote file.txt  omega.txt", column: 16)
        let paths = resolver.candidates(
            tokens: tokens, workingDirectory: "/remote", homeDirectory: nil, remoteHost: "host"
        )
        #expect(paths.first == "/remote/remote file.txt")
        #expect(!paths.contains("/remote/omega.txt"))
    }

    @Test func refusesNamedUserTildesAndControlCharacters() {
        #expect(resolver.candidates(
            tokens: ["~other/file.txt", "/remote/a\0b", "/remote/a\nb"],
            workingDirectory: "/remote", homeDirectory: "/home/user", remoteHost: "host"
        ).isEmpty)
    }

    // MARK: path:line links (compiler, test runner and agent output)

    @Test func aLineSuffixIsTriedAfterTheLiteralName() {
        let refs = resolver.references(
            tokens: ["rtl/alu.sv:42"], workingDirectory: "/w", homeDirectory: nil, remoteHost: "host"
        )
        // A file may really be named `alu.sv:42`, so the literal spelling goes first.
        #expect(refs == [
            RemoteFileReference(path: "/w/rtl/alu.sv:42"),
            RemoteFileReference(path: "/w/rtl/alu.sv", line: 42),
        ])
    }

    @Test func aLineAndColumnSuffixKeepsBoth() {
        let refs = resolver.references(
            tokens: ["/r/tb/top_tb.sv:12:5:"], workingDirectory: nil, homeDirectory: nil, remoteHost: "host"
        )
        #expect(refs.contains(RemoteFileReference(path: "/r/tb/top_tb.sv", line: 12, column: 5)))
        #expect(refs.first?.line == nil, "the literal spelling comes first")
    }

    @Test func aBareNameWithALineIsAFileNotAURLScheme() {
        // Foundation reads `alu.sv:42` as a URL with the scheme `alu.sv`.
        #expect(resolver.isClickedFileCandidate("alu.sv:42"))
        #expect(resolver.isClickedFileCandidate("README.md:3:1"))
        #expect(!resolver.isClickedFileCandidate("https://host/alu.sv"))
        #expect(!resolver.isClickedFileCandidate("mailto:someone"))
        let refs = resolver.references(
            tokens: ["alu.sv:42"], workingDirectory: "/w", homeDirectory: nil, remoteHost: "host"
        )
        #expect(refs.contains(RemoteFileReference(path: "/w/alu.sv", line: 42)))
        #expect(resolver.candidates(
            tokens: ["alu.sv:42"], workingDirectory: "/w", homeDirectory: nil, remoteHost: "host"
        ).contains("/w/alu.sv"))
    }

    @Test func aFileURLWithALineKeepsTheLine() {
        let refs = resolver.references(
            tokens: ["file:///r/a.sv:7"], workingDirectory: nil, homeDirectory: nil, remoteHost: "host"
        )
        #expect(refs.contains(RemoteFileReference(path: "/r/a.sv", line: 7)))
    }

    @Test func zeroOrNonNumericSuffixesAreNotLines() {
        let refs = resolver.references(
            tokens: ["/r/a.sv:0", "/r/b.sv:x"], workingDirectory: nil, homeDirectory: nil, remoteHost: "host"
        )
        #expect(refs.allSatisfy { $0.line == nil })
    }

    // MARK: ~ resolved on the host, in the same round trip as the download

    @Test func tildeIsLeftForTheHostWhenItsHomeIsNotKnown() {
        let refs = resolver.references(
            tokens: ["~/proj/a.sv:3"], workingDirectory: nil, homeDirectory: nil, remoteHost: "host",
            expandsHomeOnHost: true
        )
        #expect(refs == [
            RemoteFileReference(path: "~/proj/a.sv:3"),
            RemoteFileReference(path: "~/proj/a.sv", line: 3),
        ])
        // A known home still wins, and named-user tildes stay refused.
        #expect(resolver.references(
            tokens: ["~/a.sv", "~other/b.sv"], workingDirectory: nil, homeDirectory: "/home/u", remoteHost: "host",
            expandsHomeOnHost: true
        ).map(\.path) == ["/home/u/a.sv"])
    }

    @Test func needsWorkingDirectoryOnlyForRelativeTokens() {
        #expect(!resolver.needsWorkingDirectory(tokens: ["/abs/a.sv:3", "~/b.sv", "file:///c.sv"]))
        #expect(resolver.needsWorkingDirectory(tokens: ["tb/a.sv"]))
        #expect(resolver.needsWorkingDirectory(tokens: ["/abs/a.sv", "README.md:2"]))
    }
}
