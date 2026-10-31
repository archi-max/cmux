import Foundation
import UniformTypeIdentifiers

extension FilePreviewKindResolver {
    /// Whether `path` names a type that would preview only through Quick Look
    /// (web archives, mail, Office and iWork documents, which Quick Look may
    /// render through WebKit), judged from the extension alone so the file
    /// need not be downloaded. `cmux open` refuses these; they still open
    /// with a click in the Files panel. Extensionless and unknown types are
    /// not refused here: they are sniffed after the download.
    static func opensOnlyThroughQuickLook(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        // A plist may be XML text; it is sniffed after the download.
        guard !ext.isEmpty, ext != "plist", initialMode(for: url) == .quickLook,
              let type = UTType(filenameExtension: ext), !type.isDynamic else { return false }
        return !type.conforms(to: .text)
    }

    /// How `cmux open` opens `path`, judged from the extension alone.
    static func commandLineOpenRoute(path: String) -> CommandLineOpenRoute {
        if isReadInPlaceOnRemoteHost(path) { return .readInPlaceOnHost }
        if opensOnlyThroughQuickLook(path: path) { return .filesPanelOnly }
        return .download
    }
}

/// How `cmux open` opens a host file.
enum CommandLineOpenRoute: Equatable {
    /// The waveform viewer reads it on the host (FSDB), as the Files panel does; nothing is downloaded.
    case readInPlaceOnHost
    /// Quick Look only: refused; it opens with a click in the Files panel.
    case filesPanelOnly
    /// A capped download into the remote preview cache, shown in the native preview.
    case download
}
