import AppKit
import CmuxSyntaxHighlighting
import Foundation
import os

nonisolated private let slangProfileLogger = Logger(subsystem: "com.cmuxterm.app", category: "SlangProfiles")

/// What the SystemVerilog editor's header shows: `slang: <profile> · top <name> ▾`.
struct SlangHeaderState: Equatable {
    var label: String
    /// A config file of the folder is empty or unreadable (slang-server then ignores all of them).
    var hasConfigWarning: Bool
}

/// The slang menu of a SystemVerilog editor: profiles (`.f` build files), this file
/// as the top level, explore mode, editing profiles, a config warning and a
/// restart. The editor's header, the command palette and the context menu all
/// call these functions, so each action has one path.
///
/// Nothing here writes a file except on an explicit choice in an alert
/// (creating a profile, hiding `.slang/` from Git, fixing an empty config).
/// Switching profiles is `slang.setBuildFile` at runtime: no file, no restart.
/// A later server.json editor (with a `slang -f` check) can hang off
/// `configFiles(for:)` and `restartLanguageServer(editor:)`.
extension SlangCompilationActions {
    /// Profile listings are reused this long; a save of a `.f` or server.json drops them.
    private static let listingLifetime: TimeInterval = 30
    private static let remoteListingTimeout: TimeInterval = 15

    private struct CachedListing {
        var listing: SlangProfileCatalog.Listing
        var at: Date
    }

    private static var listings: [String: CachedListing] = [:]
    private static var listingTasks: [String: (token: UUID, task: Task<SlangProfileCatalog.Listing?, Never>)] = [:]

    // MARK: Header

    static func headerState(for editor: FilePreviewLanguageFeatures) -> SlangHeaderState? {
        guard let session = editor.linkSession?.session else { return nil }
        let entry = entry(for: session)
        let profile: String
        switch entry.target {
        case .buildFile(let path)?:
            profile = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        case .topLevel(let path)?:
            profile = (path as NSString).lastPathComponent
        case nil:
            profile = entry.isExplore || (entry.tops ?? []).isEmpty
                ? String(localized: "slangProfile.header.explore", defaultValue: "explore")
                : String(localized: "slangProfile.header.config", defaultValue: "server.json")
        }
        let tops = entry.tops ?? []
        let label: String
        if let first = tops.first {
            let names = tops.count > 1 ? "\(first) +\(tops.count - 1)" : first
            label = String(
                format: String(localized: "slangProfile.header.withTop", defaultValue: "slang: %1$@ · top %2$@"),
                profile,
                names
            )
        } else {
            label = String(format: String(localized: "slangProfile.header.noTop", defaultValue: "slang: %@"), profile)
        }
        let warning = cachedListing(for: editor)?.configs.contains { $0.health == .empty || $0.health == .invalid } ?? false
        return SlangHeaderState(label: label, hasConfigWarning: warning)
    }

    /// The server's compilation changed (or it restarted): read its tops again and update the headers.
    static func compilationDidChange(session: LanguageServerSession) {
        Task { @MainActor in
            let tops = ((try? await session.slangScopeChildren("")) ?? []).filter { $0.kind != "Package" }.map(\.name)
            let entry = Self.entry(for: session)
            entry.tops = tops
            // A restart that dropped what cmux set (or another target) ends a chosen explore mode.
            let chosenExplore = await session.isInChosenExploreMode
            entry.isExplore = entry.target == nil && chosenExplore
            updateHeaders(of: session)
        }
    }

    static func updateHeaders(of session: LanguageServerSession) {
        for editor in FilePreviewLanguageFeatures.allLinkables where editor.linkSession?.session === session {
            editor.updateSlangHeader()
        }
    }

    // MARK: Menu

    /// The slang menu for `editor`; built from cached profiles (a fresh listing updates the next one).
    static func menu(for editor: FilePreviewLanguageFeatures) -> NSMenu? {
        guard let session = editor.linkSession?.session else { return nil }
        let menu = NSMenu(title: "slang")
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: String(localized: "slangProfile.menu.profiles", defaultValue: "Profiles")))
        let target = target(of: session)
        if let listing = cachedListing(for: editor) {
            if listing.profiles.isEmpty {
                menu.addItem(disabledItem(String(localized: "slangProfile.menu.none", defaultValue: "No profiles (.f files) found")))
            }
            for profile in listing.profiles {
                let item = SlangMenuAction.item(profile.name) { switchProfile(editor: editor, to: profile) }
                item.toolTip = profile.path
                if !profile.buildFile.tops.isEmpty {
                    item.subtitle = String(
                        format: String(localized: "slangProfile.menu.profileTops", defaultValue: "top %@"),
                        profile.buildFile.tops.joined(separator: ", ")
                    )
                }
                if case .buildFile(let path)? = target, path == session.serverPath(for: URL(fileURLWithPath: profile.path)) {
                    item.state = .on
                }
                menu.addItem(item)
            }
        } else {
            menu.addItem(disabledItem(String(localized: "slangProfile.menu.loading", defaultValue: "Looking for profiles…")))
        }
        refreshListing(for: editor)
        menu.addItem(.separator())
        let fileTop = SlangMenuAction.item(String(localized: "slangProfile.menu.setFileTop", defaultValue: "Set This File as Top")) {
            setCurrentFileAsTop(editor: editor)
        }
        fileTop.isEnabled = !SystemVerilogModuleLocator.declarations(in: editor.documentText ?? "").isEmpty
        if case .topLevel(let path)? = target, let uri = editor.linkSession?.documentURI, path == session.serverPath(for: uri) {
            fileTop.state = .on
        }
        menu.addItem(fileTop)
        let explore = SlangMenuAction.item(String(localized: "slangProfile.menu.explore", defaultValue: "Explore Mode (No Top)")) {
            exploreMode(editor: editor)
        }
        if target == nil, entry(for: session).isExplore || (entry(for: session).tops ?? []).isEmpty { explore.state = .on }
        menu.addItem(explore)
        menu.addItem(.separator())
        for config in cachedListing(for: editor)?.configs ?? [] where config.health == .empty || config.health == .invalid {
            let name = displayName(ofConfig: config.path, editor: editor)
            let title = config.health == .empty
                ? String(format: String(localized: "slangProfile.menu.configEmpty", defaultValue: "%@ is empty — Fix…"), name)
                : String(format: String(localized: "slangProfile.menu.configInvalid", defaultValue: "%@ can’t be read — Fix…"), name)
            let item = SlangMenuAction.item(title) { fixConfig(config, editor: editor) }
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(SlangMenuAction.item(String(localized: "slangProfile.menu.edit", defaultValue: "Edit Profiles…")) {
            editProfiles(editor: editor)
        })
        menu.addItem(SlangMenuAction.item(String(localized: "slangProfile.menu.restart", defaultValue: "Restart Language Server")) {
            restartLanguageServer(editor: editor)
        })
        return menu
    }

    private static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// `.slang/server.json` relative to the root, else the path.
    private static func displayName(ofConfig path: String, editor: FilePreviewLanguageFeatures) -> String {
        guard let root = editor.linkContext?.rootURI?.path, path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    // MARK: Listing

    private static func listingKey(for editor: FilePreviewLanguageFeatures) -> String {
        editor.linkRootKey
    }

    static func cachedListing(for editor: FilePreviewLanguageFeatures) -> SlangProfileCatalog.Listing? {
        guard let cached = listings[listingKey(for: editor)] else { return nil }
        return cached.listing
    }

    /// Lists the editor's root again unless a fresh listing is cached; updates the headers when done.
    @discardableResult
    static func refreshListing(for editor: FilePreviewLanguageFeatures, force: Bool = false) -> Task<SlangProfileCatalog.Listing?, Never>? {
        let key = listingKey(for: editor)
        if !force, let cached = listings[key], Date().timeIntervalSince(cached.at) < listingLifetime { return nil }
        if !force, let running = listingTasks[key] { return running.task }
        guard let context = editor.linkContext, let root = context.rootURI?.path else { return nil }
        let remote = context.remote
        let token = UUID()
        let task = Task { @MainActor () -> SlangProfileCatalog.Listing? in
            defer { if listingTasks[key]?.token == token { listingTasks[key] = nil } }
            let listing: SlangProfileCatalog.Listing?
            if let remote {
                listing = await FilePreviewLanguageDocumentContext.runRemoteShell(
                    SlangProfileCatalog.listingCommand(root: root),
                    configuration: remote.configuration,
                    timeout: remoteListingTimeout
                ).map(SlangProfileCatalog.parseListing)
            } else {
                listing = await Task.detached { SlangProfileCatalog.localListing(root: root) }.value
            }
            guard let listing else {
                slangProfileLogger.error("couldn't list slang profiles of \(root, privacy: .public)")
                return nil
            }
            listings[key] = CachedListing(listing: listing, at: Date())
            for other in FilePreviewLanguageFeatures.allLinkables where other.linkRootKey == key {
                other.updateSlangHeader()
            }
            return listing
        }
        listingTasks[key] = (token, task)
        return task
    }

    /// The editor's profiles, listed now if none are cached.
    static func profiles(for editor: FilePreviewLanguageFeatures) async -> [SlangProfile] {
        if let cached = cachedListing(for: editor) { return cached.profiles }
        return await refreshListing(for: editor)?.value?.profiles ?? []
    }

    /// The root's `.slang/server.json` and `.slang/local/server.json`, as last listed (for a later settings editor).
    static func configFiles(for editor: FilePreviewLanguageFeatures) -> [SlangServerConfigFile.Found] {
        cachedListing(for: editor)?.configs ?? []
    }

    // MARK: Actions

    /// Builds the design from `profile` with `slang.setBuildFile` (no restart, no file written).
    static func switchProfile(editor: FilePreviewLanguageFeatures, to profile: SlangProfile) {
        guard let session = editor.linkSession?.session, claim([session]) else {
            NSSound.beep()
            return
        }
        Task { @MainActor in
            defer { release([session]) }
            guard await session.supportsCommand("slang.setBuildFile") == true else {
                showAlert(
                    title: String(localized: "slangProfile.switchFailed.title", defaultValue: "Couldn’t Use the Profile"),
                    message: String(
                        format: String(
                            localized: "slangProfile.noRuntime",
                            defaultValue: "This slang-server can’t switch build files while it runs. Right-click %@ in the Files panel and choose Use as SystemVerilog Build File."
                        ),
                        profile.path
                    ),
                    window: editor.linkPanelWindow
                )
                return
            }
            await editor.sendCurrentText()
            editor.showLinkMessage(String(
                format: String(localized: "slangProfile.progress.switch", defaultValue: "Building the design from profile %@…"),
                profile.name
            ), isProgress: true)
            let outcome = await applyProfile(profile, to: session, editor: editor)
            editor.closeLinkProgress()
            guard !outcome.tops.isEmpty else {
                showAlert(
                    title: String(localized: "slangProfile.switchFailed.title", defaultValue: "Couldn’t Use the Profile"),
                    message: [
                        String(
                            format: String(localized: "slangProfile.switchFailed.detail", defaultValue: "slang-server elaborated nothing from profile %@."),
                            profile.name
                        ),
                        outcome.failureDetail,
                    ].filter { !$0.isEmpty }.joined(separator: "\n\n"),
                    window: editor.linkPanelWindow
                )
                return
            }
            var lines = [
                String(
                    format: String(localized: "slangProfile.switched", defaultValue: "slang-server now builds the design from profile %@."),
                    profile.name
                ),
                outcome.successLine,
            ]
            if let warning = outsideRootWarning(profile, editor: editor) { lines.append(warning) }
            editor.showLinkMessage(lines.joined(separator: "\n"))
        }
    }

    /// `slang.setBuildFile` with the profile; back to what the server compiled when nothing elaborates.
    private static func applyProfile(_ profile: SlangProfile, to session: LanguageServerSession, editor: FilePreviewLanguageFeatures) async -> Outcome {
        let previous = await currentTarget(of: session)
        let serverPath = session.serverPath(for: URL(fileURLWithPath: profile.path))
        _ = await session.takeRecentErrorMessages()
        var outcome: Outcome
        do {
            try await session.slangSetBuildFile(serverPath)
            outcome = await Self.outcome(of: session)
        } catch {
            slangProfileLogger.error("setBuildFile failed: \(String(describing: error), privacy: .public)")
            outcome = Outcome(failure: error, summary: await session.diagnosticsSummary())
        }
        let entry = entry(for: session)
        if outcome.tops.isEmpty {
            await restore(previous, on: session)
        } else {
            entry.target = .buildFile(serverPath)
            entry.isExplore = false
            if let workspaceId = editor.linkWorkspaceId { entry.workspaceIds.insert(workspaceId) }
            WaveformSourceLink.topLevelWasChosen(session: session)
        }
        FilePreviewLanguageFeatures.designHierarchyDidChange(session: session)
        return outcome
    }

    /// A note when the profile's sources are outside the editor's root (a build file of another
    /// checkout or worktree), so the files edited here are not the ones slang compiles.
    static func outsideRootWarning(_ profile: SlangProfile, editor: FilePreviewLanguageFeatures) -> String? {
        guard let root = editor.linkContext?.rootURI?.path else { return nil }
        // slang resolves a build file's relative paths against the server's folder.
        let outside = profile.buildFile.sources(outside: root, baseDirectory: root)
        guard let first = outside.first, outside.count * 2 >= profile.buildFile.sources.count else { return nil }
        return String(
            format: String(
                localized: "slangProfile.outsideRoot",
                defaultValue: "Source files of %1$@ are outside %2$@ (for example %3$@), so the files you edit here may not be the ones slang compiles."
            ),
            profile.name,
            root,
            first
        )
    }

    /// Set as SystemVerilog Top Level with the module at the caret, else the file's first module.
    static func setCurrentFileAsTop(editor: FilePreviewLanguageFeatures) {
        let text = editor.documentText ?? ""
        let caret = editor.caretIndex ?? 0
        guard let declaration = SystemVerilogModuleLocator.declaration(at: caret, in: text)
            ?? SystemVerilogModuleLocator.declarations(in: text).first else {
            NSSound.beep()
            editor.showLinkMessage(String(localized: "slangProfile.noModule", defaultValue: "This file declares no module."))
            return
        }
        setTopLevel(module: declaration.name, editor: editor, anchor: caret)
    }

    /// No top level and no build file, not even the config's, until another is chosen.
    static func exploreMode(editor: FilePreviewLanguageFeatures) {
        guard let session = editor.linkSession?.session, claim([session]) else {
            NSSound.beep()
            return
        }
        Task { @MainActor in
            defer { release([session]) }
            do {
                // Sent again after a restart, unlike setTopLevel("").
                try await session.slangExplore()
                let entry = entry(for: session)
                entry.target = nil
                entry.isExplore = true
                WaveformSourceLink.topLevelWasChosen(session: session)
                FilePreviewLanguageFeatures.designHierarchyDidChange(session: session)
                editor.showLinkMessage(String(
                    localized: "slangProfile.explore.done",
                    defaultValue: "slang-server is in explore mode: it checks each file on its own, with no top level."
                ))
            } catch {
                showAlert(
                    title: String(localized: "slangProfile.explore.failed.title", defaultValue: "Couldn’t Switch to Explore Mode"),
                    message: userMessage(for: error),
                    window: editor.linkPanelWindow
                )
            }
        }
    }

    /// Relaunches the editor's server (it rereads its config files), keeping what cmux set it to compile.
    static func restartLanguageServer(editor: FilePreviewLanguageFeatures) {
        guard let session = editor.linkSession?.session, claim([session]) else {
            NSSound.beep()
            return
        }
        Task { @MainActor in
            defer { release([session]) }
            editor.showLinkMessage(String(localized: "slangProfile.restart.progress", defaultValue: "Restarting slang-server…"), isProgress: true)
            refreshListing(for: editor, force: true)
            do {
                try await session.restart(keepingCompilation: true)
                await editor.sendCurrentText()
                FilePreviewLanguageFeatures.designHierarchyDidChange(session: session)
                editor.showLinkMessage(String(localized: "slangProfile.restart.done", defaultValue: "slang-server restarted."))
            } catch {
                editor.closeLinkProgress()
                showAlert(
                    title: String(localized: "slangProfile.restart.failed.title", defaultValue: "Couldn’t Restart the Language Server"),
                    message: userMessage(for: error),
                    window: editor.linkPanelWindow
                )
            }
        }
    }

    // MARK: Edit profiles

    /// Opens a profile, or creates one (after the user picks where) for the module at the caret.
    static func editProfiles(editor: FilePreviewLanguageFeatures) {
        Task { @MainActor in
            let profiles = await profiles(for: editor)
            if profiles.isEmpty {
                await newProfile(editor: editor)
                return
            }
            let menu = NSMenu(title: String(localized: "slangProfile.menu.edit", defaultValue: "Edit Profiles…"))
            menu.autoenablesItems = false
            for profile in profiles {
                let item = SlangMenuAction.item(String(
                    format: String(localized: "slangProfile.edit.open", defaultValue: "Open %@"),
                    profile.name
                )) { open(profile.path, editor: editor) }
                item.toolTip = profile.path
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(SlangMenuAction.item(String(localized: "slangProfile.edit.new", defaultValue: "New Profile…")) {
                Task { @MainActor in await newProfile(editor: editor) }
            })
            editor.popUpSlangMenu(menu, atCaret: true)
        }
    }

    private static func open(_ path: String, editor: FilePreviewLanguageFeatures) {
        let start = LSPPosition(line: 0, character: 0)
        editor.navigate(to: LSPLocation(uri: URL(fileURLWithPath: path), range: LSPRange(start: start, end: start)))
    }

    /// Asks where to create a profile for the caret's module, writes it there (never over an
    /// existing file) and opens it. Optionally hides `.slang/` from Git.
    private static func newProfile(editor: FilePreviewLanguageFeatures) async {
        guard let context = editor.linkContext, let root = context.rootURI?.path else { return }
        let text = editor.documentText ?? ""
        let module = (SystemVerilogModuleLocator.declaration(at: editor.caretIndex ?? 0, in: text)
            ?? SystemVerilogModuleLocator.declarations(in: text).first)?.name ?? "top"
        let home = await homeDirectory(context: context)
        let repoDirectory = SlangProfileCatalog.repoProfileDirectory(root: root)
        let userDirectory = home.map { SlangProfileCatalog.userProfileDirectory(root: root, home: $0) }
        let gitExclude = await gitExcludePath(root: root, context: context)

        let alert = NSAlert()
        alert.messageText = String(localized: "slangProfile.edit.title", defaultValue: "New slang Profile")
        alert.informativeText = String(
            format: String(
                localized: "slangProfile.edit.detail",
                defaultValue: "A profile is a slang .f build file: --top, defines, include directories and source files. cmux lists the .f files in %1$@ and %2$@, and other .f files in this folder. Create %3$@ with %4$@ as the top level and this file as its source?"
            ),
            repoDirectory,
            userDirectory ?? "~/.config/cmux-slang/" + SlangProfileCatalog.projectName(ofRoot: root),
            module + ".f",
            module
        )
        alert.addButton(withTitle: String(localized: "slangProfile.edit.newRepo", defaultValue: "Create in .slang/"))
        if userDirectory != nil {
            alert.addButton(withTitle: String(localized: "slangProfile.edit.newUser", defaultValue: "Create in ~/.config/cmux-slang"))
        }
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        var excludeBox: NSButton?
        if let gitExclude {
            let box = NSButton(
                checkboxWithTitle: String(
                    format: String(localized: "slangProfile.edit.gitExclude", defaultValue: "Hide .slang/ from Git (adds it to %@)"),
                    gitExclude
                ),
                target: nil,
                action: nil
            )
            box.state = .off
            alert.accessoryView = box
            excludeBox = box
        }
        let response = await runAlert(alert, window: editor.linkPanelWindow)
        let directory: String
        switch response {
        case .alertFirstButtonReturn: directory = repoDirectory
        case .alertSecondButtonReturn where userDirectory != nil: directory = userDirectory!
        default: return
        }
        let path = (directory as NSString).appendingPathComponent(module + ".f")
        let contents = "// slang profile for cmux: a slang command file (see slang --help).\n"
            + "--top \(module)\n"
            + quotedBuildFileWord(context.documentURI.path) + "\n"
        do {
            try await writeNewFile(path, contents: Data(contents.utf8), context: context)
            if directory == repoDirectory, excludeBox?.state == .on, let gitExclude {
                try await appendGitExclude(".slang/", to: gitExclude, context: context)
            }
        } catch {
            showAlert(
                title: String(localized: "slangProfile.edit.failed.title", defaultValue: "Couldn’t Create the Profile"),
                message: error.localizedDescription,
                window: editor.linkPanelWindow
            )
            return
        }
        refreshListing(for: editor, force: true)
        open(path, editor: editor)
    }

    private enum ProfileFileError: LocalizedError {
        case remoteFailed(String)
        case changed(String)

        var errorDescription: String? {
            switch self {
            case .remoteFailed(let path):
                return String(format: String(localized: "slangProfile.error.remoteWrite", defaultValue: "cmux couldn’t write %@ on the SSH host."), path)
            case .changed(let path):
                return String(format: String(localized: "slangProfile.error.changed", defaultValue: "%@ is no longer empty, so cmux left it unchanged."), path)
            }
        }
    }

    private static func homeDirectory(context: FilePreviewLanguageDocumentContext) async -> String? {
        guard let remote = context.remote else { return NSHomeDirectory() }
        let output = await FilePreviewLanguageDocumentContext.runRemoteShell(
            SlangWorkspaceRoot.posixShellCommand("printf %s \"$HOME\""),
            configuration: remote.configuration
        )
        return output.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `git rev-parse --git-path info/exclude` in the root, made absolute; nil outside a repository.
    private static func gitExcludePath(root: String, context: FilePreviewLanguageDocumentContext) async -> String? {
        let output: String?
        if let remote = context.remote {
            output = await FilePreviewLanguageDocumentContext.runRemoteShell(
                SlangWorkspaceRoot.posixShellCommand("cd \(shellQuote(root)) && git rev-parse --git-path info/exclude"),
                configuration: remote.configuration
            )
        } else {
            // /usr/bin/git without the developer tools asks to install them: don't.
            output = await Task.detached { () -> String? in
                guard runLocal("/usr/bin/xcode-select", ["-p"]) != nil else { return nil }
                return runLocal("/usr/bin/git", ["-C", root, "rev-parse", "--git-path", "info/exclude"])
            }.value
        }
        guard let line = output?.split(whereSeparator: \.isNewline).first.map(String.init), !line.isEmpty else { return nil }
        return line.hasPrefix("/") ? line : (root as NSString).appendingPathComponent(line)
    }

    /// Creates `path` (and its folders) with `contents`; an existing file is left as it is.
    private static func writeNewFile(_ path: String, contents: Data, context: FilePreviewLanguageDocumentContext) async throws {
        let directory = (path as NSString).deletingLastPathComponent
        if let remote = context.remote {
            let command = SlangWorkspaceRoot.posixShellCommand(
                "[ -e \(shellQuote(path)) ] && exit 0; mkdir -p \(shellQuote(directory)) && "
                    + SSHFileExplorerMutationCommand.writeFile(path: path, expectedStamp: nil).command
            )
            guard await FilePreviewLanguageDocumentContext.runRemoteShell(command, configuration: remote.configuration, input: contents) != nil else {
                throw ProfileFileError.remoteFailed(path)
            }
            return
        }
        guard !FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try contents.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Adds `pattern` as a line of the exclude file unless it is there already.
    private static func appendGitExclude(_ pattern: String, to path: String, context: FilePreviewLanguageDocumentContext) async throws {
        if let remote = context.remote {
            // Read, add the line, and write it back through a temporary file renamed over it.
            guard let existing = await FilePreviewLanguageDocumentContext.runRemoteShell(
                SlangWorkspaceRoot.posixShellCommand("cat \(shellQuote(path)) 2>/dev/null; true"),
                configuration: remote.configuration
            ) else { throw ProfileFileError.remoteFailed(path) }
            guard let contents = addingLine(pattern, to: existing) else { return }
            let command = SlangWorkspaceRoot.posixShellCommand(
                "mkdir -p \(shellQuote((path as NSString).deletingLastPathComponent)) && "
                    + SSHFileExplorerMutationCommand.writeFile(path: path, expectedStamp: nil).command
            )
            guard await FilePreviewLanguageDocumentContext.runRemoteShell(command, configuration: remote.configuration, input: Data(contents.utf8)) != nil else {
                throw ProfileFileError.remoteFailed(path)
            }
            return
        }
        let url = URL(fileURLWithPath: path)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard let contents = addingLine(pattern, to: existing) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    /// `text` with `line` added as its own line; nil when it has the line already.
    private static func addingLine(_ line: String, to text: String) -> String? {
        guard !text.split(whereSeparator: \.isNewline).contains(where: { $0 == line }) else { return nil }
        let separator = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
        return text + separator + line + "\n"
    }

    /// A path as one word of a slang command file: quoted when it has white space, quotes or backslashes.
    static func quotedBuildFileWord(_ path: String) -> String {
        guard path.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "\\" }) else { return path }
        return "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    nonisolated private static func runLocal(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    private static func shellQuote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Config warning

    /// An empty config: write `{}` and restart, after the user confirms. An unreadable one: open it.
    static func fixConfig(_ config: SlangServerConfigFile.Found, editor: FilePreviewLanguageFeatures) {
        guard let context = editor.linkContext else { return }
        Task { @MainActor in
            let alert = NSAlert()
            let shown = displayName(ofConfig: config.path, editor: editor)
            if config.health == .empty {
                alert.messageText = String(localized: "slangProfile.config.empty.title", defaultValue: "Empty slang-server Config")
                alert.informativeText = String(
                    format: String(
                        localized: "slangProfile.config.empty.detail",
                        defaultValue: "%@ is empty. slang-server can’t read it, so it ignores all of this folder’s config files. Write an empty JSON object ({}) to it and restart the language server?"
                    ),
                    shown
                )
                alert.addButton(withTitle: String(localized: "slangProfile.config.write", defaultValue: "Write {} and Restart"))
            } else {
                alert.messageText = String(localized: "slangProfile.config.invalid.title", defaultValue: "Unreadable slang-server Config")
                alert.informativeText = String(
                    format: String(
                        localized: "slangProfile.config.invalid.detail",
                        defaultValue: "%@ isn’t a JSON object. slang-server can’t read it, so it ignores all of this folder’s config files. Open it to fix it?"
                    ),
                    shown
                )
            }
            alert.addButton(withTitle: String(localized: "slangProfile.config.open", defaultValue: "Open File"))
            alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
            let response = await runAlert(alert, window: editor.linkPanelWindow)
            let opens = config.health == .empty ? response == .alertSecondButtonReturn : response == .alertFirstButtonReturn
            if opens {
                open(config.path, editor: editor)
                return
            }
            guard config.health == .empty, response == .alertFirstButtonReturn else { return }
            do {
                try await replaceEmptyFile(config.path, contents: Data("{}\n".utf8), context: context)
            } catch {
                showAlert(
                    title: String(localized: "slangProfile.config.failed.title", defaultValue: "Couldn’t Fix the Config"),
                    message: error.localizedDescription,
                    window: editor.linkPanelWindow
                )
                return
            }
            refreshListing(for: editor, force: true)
            restartLanguageServer(editor: editor)
        }
    }

    /// Writes `path` through a temporary file renamed over it, only while it is still empty
    /// (white space only), so a config edited since the warning is never replaced.
    private static func replaceEmptyFile(_ path: String, contents: Data, context: FilePreviewLanguageDocumentContext) async throws {
        if let remote = context.remote {
            let quoted = shellQuote(path)
            let command = SlangWorkspaceRoot.posixShellCommand(
                "[ -f \(quoted) ] || exit 75; [ -z \"$(tr -d ' \\t\\r\\n' < \(quoted))\" ] || exit 75; "
                    + SSHFileExplorerMutationCommand.writeFile(path: path, expectedStamp: nil).command
            )
            guard await FilePreviewLanguageDocumentContext.runRemoteShell(command, configuration: remote.configuration, input: contents) != nil else {
                throw ProfileFileError.remoteFailed(path)
            }
            return
        }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard SlangServerConfigFile.health(of: FileManager.default.contents(atPath: url.path)) == .empty else {
            throw ProfileFileError.changed(path)
        }
        try contents.write(to: url, options: .atomic)
    }

    // MARK: Saves

    /// A file was saved in an editor: a server.json of a server's root restarts that server,
    /// and a `.f` a server builds from is sent to it again. `hostIdentity`: `local`, or the SSH route.
    static func fileWasSaved(path: String, hostIdentity: String) {
        let name = (path as NSString).lastPathComponent
        let isConfig = name == "server.json"
        let isBuildFile = isBuildFileCandidate(path: path)
        guard isConfig || isBuildFile else { return }
        var seen = Set<ObjectIdentifier>()
        for editor in FilePreviewLanguageFeatures.allLinkables where editor.linkHostIdentity == hostIdentity {
            guard let session = editor.linkSession?.session, seen.insert(ObjectIdentifier(session)).inserted,
                  let root = session.rootURI?.path else { continue }
            // Profiles also live outside the root (~/.config/cmux-slang): list again.
            listings[editor.linkRootKey] = nil
            // The server's form of both paths (symlinks and /private resolved locally).
            let savedPath = session.serverPath(for: URL(fileURLWithPath: path))
            if isConfig, [".slang/server.json", SlangServerConfigFile.relativePath].contains(where: {
                session.serverPath(for: URL(fileURLWithPath: SlangServerConfigFile.path(inWorkspace: root, relativePath: $0))) == savedPath
            }) {
                slangProfileLogger.info("server.json saved: restarting the server of \(root, privacy: .public)")
                restartLanguageServer(editor: editor)
                continue
            }
            if isBuildFile, case .buildFile(let buildPath)? = target(of: session),
               buildPath == savedPath, claim([session]) {
                Task { @MainActor in
                    defer { release([session]) }
                    do {
                        try await session.slangSetBuildFile(buildPath)
                    } catch {
                        slangProfileLogger.error("re-sending the saved build file failed: \(String(describing: error), privacy: .public)")
                        editor.showLinkMessage(userMessage(for: error))
                    }
                    FilePreviewLanguageFeatures.designHierarchyDidChange(session: session)
                }
            }
        }
    }

    // MARK: Waveform

    /// When a waveform's top scope (or the scope below a simulator wrapper) names exactly one
    /// profile's `--top`, builds from that profile. Only for a server with no top level that cmux
    /// was not told to keep in explore mode. True when it did.
    static func autoPickProfile(
        session: LanguageServerSession,
        dumpTops: [String],
        dumpChildren: [String: [String]],
        progress: @MainActor @Sendable (String) -> Void
    ) async -> Bool {
        let entry = entry(for: session)
        guard entry.target == nil, !entry.isExplore, !isBusy(session),
              let editor = FilePreviewLanguageFeatures.allLinkables.first(where: { $0.linkSession?.session === session }),
              await session.supportsCommand("slang.setBuildFile") == true else { return false }
        let profiles = await profiles(for: editor)
        guard let profile = SlangProfileCatalog.profile(matchingDumpTops: dumpTops, children: dumpChildren, in: profiles),
              claim([session]) else { return false }
        defer { release([session]) }
        // The user may have chosen a top level, build file or explore mode while the profiles were listed.
        guard entry.target == nil, !entry.isExplore, await session.slangCompilationTarget == nil,
              await !session.isInChosenExploreMode,
              ((try? await session.slangScopeChildren("")) ?? []).allSatisfy({ $0.kind == "Package" }) else { return false }
        progress(String(
            format: String(
                localized: "slangProfile.autoPick",
                defaultValue: "Building the design from profile %@: its --top matches the waveform’s top scope…"
            ),
            profile.name
        ))
        let outcome = await applyProfile(profile, to: session, editor: editor)
        slangProfileLogger.info("auto-picked slang profile \(profile.path, privacy: .public): \(outcome.tops.count) tops")
        return !outcome.tops.isEmpty
    }
}

/// A menu item that runs a closure.
@MainActor
final class SlangMenuAction: NSObject {
    private let action: @MainActor () -> Void

    private init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    static func item(_ title: String, action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let handler = SlangMenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = handler
        // The item keeps its handler alive (`target` is weak).
        item.representedObject = handler
        return item
    }

    @objc private func run(_ sender: Any?) {
        action()
    }
}
