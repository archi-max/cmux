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

    /// Whether `cmux open` sends `path` to the Files panel instead of
    /// downloading it: Quick-Look-only types, and waveforms read in place on
    /// the host (FSDB), whose downloaded copy the local viewer can't read.
    static func commandLineOpenNeedsFilesPanel(path: String) -> Bool {
        opensOnlyThroughQuickLook(path: path) || isReadInPlaceOnRemoteHost(path)
    }
}
