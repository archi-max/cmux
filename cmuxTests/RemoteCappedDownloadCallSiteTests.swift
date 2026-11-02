import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The callers of the one-request capped read: the waveform viewer's session
/// and alias reads keep their error meanings, and the slang config's build
/// write never overwrites a host edit made after its read.
@MainActor
@Suite(.serialized) struct RemoteCappedDownloadCallSiteTests {
    private func provider(_ files: [String: Data]) -> (SSHFileExplorerProvider, CappedRequestCountingTransport) {
        let transport = CappedRequestCountingTransport(files: files)
        return (SSHFileExplorerProvider(destination: "dev@host", port: nil, identityFile: nil, sshOptions: [],
                                        homePath: "/home/dev", isAvailable: true, transport: transport), transport)
    }

    @Test func aSessionReadSaysTooLargeOrNoSuchFile() async throws {
        let (provider, host) = provider(["/home/dev/sim/dump.json": Data(repeating: 0x20, count: 9 * 1024 * 1024)])
        do {
            _ = try await FilePreviewWaveformSession.downloadSessionText(path: "/home/dev/sim/dump.json", provider: provider)
            Issue.record("an oversize session was read")
        } catch let error as CocoaError {
            #expect(error.code == .fileReadTooLarge, "\(error)")
        }
        do {
            _ = try await FilePreviewWaveformSession.downloadSessionText(path: "/home/dev/sim/none.json", provider: provider)
            Issue.record("a missing session was read")
        } catch let error as CocoaError {
            #expect(error.code == .fileReadNoSuchFile, "\(error)")
        }
        #expect(!host.requests.contains("download"), "nothing is downloaded: \(host.requests)")
    }

    @Test func aBuildWriteNeverOverwritesAHostEditMadeAfterItsRead() async throws {
        let path = "/home/dev/proj/.slang/local/server.json"
        let original = Data(#"{"other": 1}"#.utf8)
        let (provider, host) = provider([path: original])
        let location = SlangCompilationActions.ConfigFileLocation(path: path, sshProvider: provider)
        // Someone edits the config on the host just after cmux read it.
        host.editAfterRead = true
        await #expect(throws: FileExplorerError.remoteFileChanged) {
            _ = try await SlangCompilationActions.writeBuild("/home/dev/proj/build", to: location)
        }
        #expect(host.contents(path) == original, "the host's file was overwritten")
        // With no edit in between, the build is written.
        host.editAfterRead = false
        _ = try await SlangCompilationActions.writeBuild("/home/dev/proj/build", to: location)
        let written = String(decoding: host.contents(path) ?? Data(), as: UTF8.self)
        #expect(written.contains("/home/dev/proj/build") && written.contains("other"), written)
    }
}
