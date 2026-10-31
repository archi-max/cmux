import AppKit
import CmuxCore
import CmuxSyntaxHighlighting
import Foundation

/// Converts between LSP line/character positions and `NSString` offsets.
///
/// LSP characters and `NSRange` locations are both UTF-16 code units, so the
/// only work is finding line starts. `\n`, `\r\n` and a lone `\r` all end a
/// line, as the LSP specification requires.
struct FilePreviewLSPLineIndex {
    let length: Int
    private var lineStarts: [Int] = [0]
    /// Offset where each line's content ends, before its terminator.
    private var lineEnds: [Int] = []

    init(_ text: String) {
        var offset = 0
        var previousWasCarriageReturn = false
        for unit in text.utf16 {
            if unit == 0x0A {
                if previousWasCarriageReturn {
                    // The `\r` already ended this line; `\n` only moves its start.
                    lineStarts[lineStarts.count - 1] = offset + 1
                } else {
                    lineEnds.append(offset)
                    lineStarts.append(offset + 1)
                }
                previousWasCarriageReturn = false
            } else if unit == 0x0D {
                lineEnds.append(offset)
                lineStarts.append(offset + 1)
                previousWasCarriageReturn = true
            } else {
                previousWasCarriageReturn = false
            }
            offset += 1
        }
        lineEnds.append(offset)
        length = offset
    }

    /// Offset of `position`, clamped to its line's content and to the text.
    func offset(for position: LSPPosition) -> Int {
        guard position.line >= 0 else { return 0 }
        guard position.line < lineStarts.count else { return length }
        let start = lineStarts[position.line]
        return min(start + max(0, position.character), lineEnds[position.line])
    }

    func position(at offset: Int) -> LSPPosition {
        let offset = min(max(0, offset), length)
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset {
                low = middle
            } else {
                high = middle - 1
            }
        }
        let character = min(offset, lineEnds[low]) - lineStarts[low]
        return LSPPosition(line: low, character: max(0, character))
    }

    func characterRange(for range: LSPRange) -> NSRange {
        let start = offset(for: range.start)
        let end = max(start, offset(for: range.end))
        return NSRange(location: start, length: end - start)
    }

    /// The range to underline: an empty diagnostic range still marks one character.
    func underlineRange(for range: LSPRange, in text: NSString) -> NSRange {
        let characters = characterRange(for: range)
        guard characters.length == 0, length > 0 else { return characters }
        let location = characters.location
        if location < length, !Self.isLineTerminator(text.character(at: location)) {
            return NSRange(location: location, length: 1)
        }
        guard location > 0 else { return characters }
        return NSRange(location: location - 1, length: 1)
    }

    private static func isLineTerminator(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D
    }
}

/// SystemVerilog identifier scanning over UTF-16 text.
enum FilePreviewLanguageIdentifier {
    static func isIdentifierUnit(_ unit: unichar) -> Bool {
        switch unit {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x24:
            return true
        default:
            return false
        }
    }

    /// The identifier containing `index`, or nil when `index` is not on one.
    static func range(containing index: Int, in text: NSString) -> NSRange? {
        guard index >= 0, index < text.length, isIdentifierUnit(text.character(at: index)) else { return nil }
        var start = index
        while start > 0, isIdentifierUnit(text.character(at: start - 1)) {
            start -= 1
        }
        var end = index + 1
        while end < text.length, isIdentifierUnit(text.character(at: end)) {
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }

    /// The identifier characters immediately before `caret` (possibly empty).
    static func range(endingAt caret: Int, in text: NSString) -> NSRange {
        let caret = min(max(0, caret), text.length)
        var start = caret
        while start > 0, isIdentifierUnit(text.character(at: start - 1)) {
            start -= 1
        }
        return NSRange(location: start, length: caret - start)
    }
}

/// Where a File Preview document lives for the language server.
@MainActor
struct FilePreviewLanguageDocumentContext {
    /// The workspace SSH route of a remote document.
    struct RemoteRoute {
        let configuration: WorkspaceRemoteConfiguration
        let providerIdentity: String
    }

    let documentURI: URL
    let rootURI: URL?
    let serverLaunch: LanguageToolLaunch
    /// Set for documents previewed from an SSH workspace. Their buffer is a
    /// read-only downloaded copy; `documentURI` is the path on the remote host.
    let remote: RemoteRoute?

    static func resolve(
        languageId: String,
        panel: FilePreviewPanel?,
        filePath: String
    ) -> FilePreviewLanguageDocumentContext? {
        let workspace = panel.flatMap { AppDelegate.shared?.workspaceFor(tabId: $0.workspaceId) }
        return resolve(
            languageId: languageId,
            workspace: workspace,
            filePath: filePath,
            remotePath: panel?.cloudPreviewRemotePath,
            providerIdentity: panel?.cloudPreviewProviderIdentity
        )
    }

    /// The context a document at `filePath` (local) or `remotePath` (on the
    /// workspace's SSH host, `providerIdentity` naming the route) would get, so
    /// other features reach the same pooled language server as its editor.
    static func resolve(
        languageId: String,
        workspace: Workspace?,
        filePath: String,
        remotePath: String?,
        providerIdentity: String?
    ) -> FilePreviewLanguageDocumentContext? {
        if let remotePath {
            // Only SSH workspaces can run a remote language server.
            guard let providerIdentity,
                  providerIdentity.hasPrefix("ssh:"),
                  let configuration = workspace?.remoteConfiguration,
                  configuration.transport == .ssh,
                  let launch = remoteServerLaunch(languageId: languageId, configuration: configuration) else {
                return nil
            }
            // The terminal directory is often the remote home, where the server
            // would index every checkout; use the pinned Files root or the file's folder.
            let root = rootDirectory(for: remotePath, workspaceDirectory: workspace?.fileExplorerPinnedRootPath)
            return FilePreviewLanguageDocumentContext(
                documentURI: URL(fileURLWithPath: remotePath),
                rootURI: URL(fileURLWithPath: root, isDirectory: true),
                serverLaunch: launch,
                remote: RemoteRoute(configuration: configuration, providerIdentity: providerIdentity)
            )
        }
        guard let launch = LanguageToolRegistry.languageServer(forLanguage: languageId, remoteDestination: nil) else {
            return nil
        }
        // A remote workspace's directory is a path on the remote host.
        let workspaceDirectory = workspace?.usesRemoteDirectoryProvenance == true ? nil : workspace?.currentDirectory
        let root = rootDirectory(for: filePath, workspaceDirectory: workspaceDirectory)
        return FilePreviewLanguageDocumentContext(
            documentURI: URL(fileURLWithPath: filePath),
            rootURI: URL(fileURLWithPath: root, isDirectory: true),
            serverLaunch: launch,
            remote: nil
        )
    }

    /// Runs the registry's remote command through the workspace's own batch
    /// `ssh` arguments, the same route the Files explorer uses: it reuses the
    /// `cmux ssh` ControlPath, so password-only hosts work too.
    private static func remoteServerLaunch(
        languageId: String,
        configuration: WorkspaceRemoteConfiguration
    ) -> LanguageToolLaunch? {
        guard case .ssh(_, _, let remoteCommand)? = LanguageToolRegistry.languageServer(
            forLanguage: languageId,
            remoteDestination: configuration.destination
        ) else { return nil }
        let arguments = configuration.batchSSHCommandArguments(
            command: remoteCommand,
            effectiveSSHOptions: configuration.fileOperationSSHOptions
        )
        return .remote(executablePath: "/usr/bin/ssh", arguments: arguments)
    }

    /// The workspace directory when it contains the file, else the file's parent.
    private static func rootDirectory(for filePath: String, workspaceDirectory: String?) -> String {
        if let workspaceDirectory {
            let trimmed = workspaceDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
            if !trimmed.isEmpty, filePath.hasPrefix(prefix) {
                return trimmed
            }
        }
        return (filePath as NSString).deletingLastPathComponent
    }
}

/// Popover content for hover text and diagnostic messages.
final class FilePreviewLanguageHoverViewController: NSViewController {
    private static let maximumWidth: CGFloat = 520
    private static let maximumLines = 40
    private let content: NSAttributedString
    private let isSelectable: Bool

    /// `isSelectable`: the text can be selected and copied (link messages).
    init(sections: [String], isSelectable: Bool = false) {
        content = Self.render(sections: sections)
        self.isSelectable = isSelectable
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let label = NSTextField(labelWithAttributedString: content)
        label.isSelectable = isSelectable
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = Self.maximumWidth
        label.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maximumWidth),
        ])
        container.layoutSubtreeIfNeeded()
        preferredContentSize = container.fittingSize
        view = container
    }

    /// Minimal markdown: fenced code renders monospaced; emphasis and inline
    /// code markers are dropped. Sections are separated by a blank line.
    private static func render(sections: [String]) -> NSAttributedString {
        let bodyFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        let codeFont = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
        let output = NSMutableAttributedString()
        var lineCount = 0
        for (sectionIndex, section) in sections.enumerated() {
            if sectionIndex > 0 {
                output.append(NSAttributedString(string: "\n\n", attributes: [.font: bodyFont]))
            }
            var isInCodeBlock = false
            var lines: [(text: String, isCode: Bool)] = []
            for rawLine in section.components(separatedBy: .newlines) {
                if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    isInCodeBlock.toggle()
                    continue
                }
                if isInCodeBlock {
                    lines.append((rawLine, true))
                } else {
                    var line = rawLine
                    while line.hasPrefix("#") { line.removeFirst() }
                    line = line.replacingOccurrences(of: "**", with: "")
                        .replacingOccurrences(of: "`", with: "")
                    lines.append((line.trimmingCharacters(in: .whitespaces), false))
                }
            }
            while let last = lines.last, last.text.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeLast()
            }
            for (lineIndex, line) in lines.enumerated() {
                guard lineCount < maximumLines else { break }
                let suffix = lineIndex < lines.count - 1 ? "\n" : ""
                output.append(NSAttributedString(
                    string: line.text + suffix,
                    attributes: [
                        .font: line.isCode ? codeFont : bodyFont,
                        .foregroundColor: NSColor.labelColor,
                    ]
                ))
                lineCount += 1
            }
        }
        return output
    }
}
