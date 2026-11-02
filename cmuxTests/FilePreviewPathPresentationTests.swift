import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The file preview header names the file the user opened: the host path for
/// a remote file, never cmux's local cache copy, which stays one menu item away.
@Suite struct FilePreviewPathPresentationTests {
    private let cache = "/private/var/folders/x/T/cmux-cloud-previews-1-A/B/alu.sv"

    @Test func aRemoteFileShowsAndCopiesItsHostPath() {
        let shown = FilePreviewPathPresentation(localPath: cache, remotePath: "/home/u/proj/rtl/alu.sv")
        #expect(shown.displayedPath == "/home/u/proj/rtl/alu.sv")
        #expect(shown.copyPath == "/home/u/proj/rtl/alu.sv")
        #expect(shown.localCopyPath == cache, "Copy Local Path gives the cache file")
    }

    @Test func aLocalFileHasOnlyOnePath() {
        let shown = FilePreviewPathPresentation(localPath: "/Users/me/a.sv", remotePath: nil)
        #expect(shown.displayedPath == "/Users/me/a.sv")
        #expect(shown.copyPath == "/Users/me/a.sv")
        #expect(shown.localCopyPath == nil, "no second item for a local file")
    }

    @Test func anEmptyRemotePathIsNotARemoteFile() {
        let shown = FilePreviewPathPresentation(localPath: "/Users/me/a.sv", remotePath: "")
        #expect(shown.displayedPath == "/Users/me/a.sv")
        #expect(shown.localCopyPath == nil)
    }
}
