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
    /// "Switched to <profile> to match the waveform", shown with Undo for a while after an auto-pick.
    var autoPickNotice: String? = nil
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
        var label: String
        if let following = entry.following {
            // A focus switch is building this file's profile.
            label = String(
                format: String(localized: "slangProfile.progress.switch", defaultValue: "Building the design from profile %@…"),
                profileName(of: following)
            )
        } else if let first = tops.first {
            let names = tops.count > 1 ? "\(first) +\(tops.count - 1)" : first
            label = String(
                format: String(localized: "slangProfile.header.withTop", defaultValue: "slang: %1$@ · top %2$@"),
                profile,
                names
            )
        } else {
            label = String(format: String(localized: "slangProfile.header.noTop", defaultValue: "slang: %@"), profile)
        }
        // The file's own (or the last-set) profile isn't what the server compiles: an editor that
        // isn't the active one, or a profile that couldn't be built.
        if entry.following == nil, let mine = profileChoice(for: editor),
           resolved(mine, session: session, entry: entry)
            != resolved(SlangProfileChoice(CompilationState(target: entry.target, isExplore: entry.isExplore)), session: session, entry: entry) {
            label = String(
                format: String(localized: "slangProfile.header.fileProfile", defaultValue: "%1$@ · this file: %2$@"),
                label,
                profileName(of: mine)
            )
        }
        let warning = cachedListing(for: editor)?.configs.contains { $0.health == .empty || $0.health == .invalid } ?? false
        var notice: String?
        if let autoPick = entry.autoPick, entry.target == autoPick.picked, !entry.isExplore,
           Date().timeIntervalSince(autoPick.at) < autoPickNoticeDuration {
            notice = String(
                format: String(localized: "slangProfile.autoPick.notice", defaultValue: "Switched to %@ to match the waveform"),
                autoPick.profile
            )
        }
        return SlangHeaderState(label: label, hasConfigWarning: warning, autoPickNotice: notice)
    }

    /// The server's compilation changed (or it restarted): read its tops again and update the headers.
    static func compilationDidChange(session: LanguageServerSession) {
        // The state machine pane's answers were worked out for the design before: those of this
        // server's waveforms only.
        WaveformFSMEngines.designChanged(session: session)
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
        // The file's profile (its own, else the last-set one), else what the server compiles.
        let entry = entry(for: session)
        let shown = profileChoice(for: editor) ?? SlangProfileChoice(CompilationState(target: entry.target, isExplore: entry.isExplore))
        if let listing = cachedListing(for: editor) {
            if listing.profiles.isEmpty {
                menu.addItem(disabledItem(String(localized: "slangProfile.menu.none", defaultValue: "No profiles (.f files) found")))
            }
            for profile in listing.profiles {
                let item = SlangMenuAction.item(profile.name) { switchProfile(editor: editor, to: profile) }
                item.toolTip = profile.path
                if !profile.buildFile.tops.isEmpty {
                    let tops = String(
                        format: String(localized: "slangProfile.menu.profileTops", defaultValue: "top %@"),
                        profile.buildFile.tops.joined(separator: ", ")
                    )
                    if #available(macOS 14.4, *) {
                        item.subtitle = tops
                    } else {
                        // No menu item subtitles before macOS 14.4: the tops follow the name.
                        item.title = profile.name + " · " + tops
                    }
                }
                if shown == .buildFile(session.serverPath(for: URL(fileURLWithPath: profile.path))) {
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
        if let uri = editor.linkSession?.documentURI, shown == .topLevel(session.serverPath(for: uri)) {
            fileTop.state = .on
        }
        menu.addItem(fileTop)
        let explore = SlangMenuAction.item(String(localized: "slangProfile.menu.explore", defaultValue: "Explore Mode (No Top)")) {
            exploreMode(editor: editor)
        }
        if shown == .explore || (shown == .configured && (entry.tops ?? []).isEmpty) { explore.state = .on }
        menu.addItem(explore)
        let followLast = SlangMenuAction.item(String(
            localized: "slangProfile.menu.followLastSet",
            defaultValue: "Use the Last-Set Profile for This File"
        )) {
            followLastSetProfile(editor: editor)
        }
        followLast.isEnabled = fileKey(of: editor).map { assignments(rootKey: editor.linkRootKey).ownChoice(forFile: $0) != nil } ?? false
        followLast.toolTip = String(
            localized: "slangProfile.menu.followLastSet.help",
            defaultValue: "Each file keeps the profile chosen while it was active. Files with none use the profile set last."
        )
        menu.addItem(followLast)
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
            // A listing a forced refresh replaced (started before a save) doesn't overwrite the newer one.
            guard listingTasks[key]?.token == token else { return listing }
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
        guard let session = editor.linkSession?.session else {
            NSSound.beep()
            return
        }
        Task { @MainActor in
            guard await claimForUser(session) else {
                NSSound.beep()
                return
            }
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
            recordChoice(.buildFile(session.serverPath(for: URL(fileURLWithPath: profile.path))), session: session, editor: editor)
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
        let previous = await currentState(of: session)
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
        guard let session = editor.linkSession?.session else {
            NSSound.beep()
            return
        }
        Task { @MainActor in
            guard await claimForUser(session) else {
                NSSound.beep()
                return
            }
            defer { release([session]) }
            do {
                // Sent again after a restart, unlike setTopLevel("").
                try await session.slangExplore()
                let entry = entry(for: session)
                entry.target = nil
                entry.isExplore = true
                WaveformSourceLink.topLevelWasChosen(session: session)
                recordChoice(.explore, session: session, editor: editor)
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
        guard let session = editor.linkSession?.session else {
            NSSound.beep()
            return
        }
        Task { @MainActor in
            guard await claimForUser(session) else {
                NSSound.beep()
                return
            }
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
            "printf %s \"$HOME\"",
            configuration: remote.configuration
        )
        return output.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `git rev-parse --git-path info/exclude` in the root, made absolute; nil outside a repository.
    private static func gitExcludePath(root: String, context: FilePreviewLanguageDocumentContext) async -> String? {
        let output: String?
        if let remote = context.remote {
            output = await FilePreviewLanguageDocumentContext.runRemoteShell(
                "cd \(shellQuote(root)) && git rev-parse --git-path info/exclude",
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
            let script = "[ -e \(shellQuote(path)) ] && exit 0; mkdir -p \(shellQuote(directory)) && "
                + SSHFileExplorerMutationCommand.writeFile(path: path, expectedStamp: nil).command
            guard await FilePreviewLanguageDocumentContext.runRemoteShell(script, configuration: remote.configuration, input: contents) != nil else {
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
            // Read (stamp first, then the text), add the line, and write it back through a temporary
            // file renamed over it, only if the stamp still holds; read again when it changed.
            let separator = "@@cmux-exclude-text"
            for _ in 0..<3 {
                guard let read = await FilePreviewLanguageDocumentContext.runRemoteShell(
                    SSHFileExplorerMutationCommand.fileStamp(path: path).command
                        + "; printf '\\n%s\\n' \(separator); cat \(shellQuote(path)) 2>/dev/null; true",
                    configuration: remote.configuration
                ), let range = read.range(of: "\n" + separator + "\n") else { throw ProfileFileError.remoteFailed(path) }
                let stamp = SSHRemoteFileStamp(statOutput: String(read[..<range.lowerBound]))
                guard let contents = addingLine(pattern, to: String(read[range.upperBound...])) else { return }
                let script = "mkdir -p \(shellQuote((path as NSString).deletingLastPathComponent)) && "
                    + SSHFileExplorerMutationCommand.writeFile(path: path, expectedStamp: stamp).command
                let result = await FilePreviewLanguageDocumentContext.runRemoteShellWithStatus(
                    script, configuration: remote.configuration, input: Data(contents.utf8)
                )
                if result?.status == 0 { return }
                guard result?.status == SSHFileExplorerMutationCommand.remoteChangedStatus else { break }
            }
            throw ProfileFileError.remoteFailed(path)
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
            let changed = SSHFileExplorerMutationCommand.remoteChangedStatus
            let script = "[ -f \(quoted) ] || exit \(changed); [ -z \"$(tr -d ' \\t\\r\\n' < \(quoted))\" ] || exit \(changed); "
                + SSHFileExplorerMutationCommand.writeFile(path: path, expectedStamp: nil).command
            let result = await FilePreviewLanguageDocumentContext.runRemoteShellWithStatus(script, configuration: remote.configuration, input: contents)
            switch result?.status {
            case 0?: return
            case changed?: throw ProfileFileError.changed(path)
            default: throw ProfileFileError.remoteFailed(path)
            }
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
            // Profiles also live outside the root (~/.config/cmux-slang): list again, not reusing a
            // listing that started before the save.
            listings[editor.linkRootKey] = nil
            refreshListing(for: editor, force: true)
            // The server's form of both paths (symlinks and /private resolved locally).
            let savedPath = session.serverPath(for: URL(fileURLWithPath: path))
            // A saved build file may fix a profile that elaborated nothing.
            if isBuildFile { designFileSaved(savedPath, session: session) }
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

    /// How long the header offers to undo an auto-pick.
    static let autoPickNoticeDuration: TimeInterval = 20
    /// The auto-pick running per server, shared by the link and the waveform's opening (one owner).
    private static var autoPickTasks: [ObjectIdentifier: Task<Bool, Never>] = [:]

    /// Undo of the header's auto-pick note: back to what the server compiled, and no more
    /// auto-picks for this server.
    static func undoAutoPick(editor: FilePreviewLanguageFeatures) {
        guard let session = editor.linkSession?.session else { return }
        let entry = entry(for: session)
        // Only while the auto-picked profile is still what the server compiles.
        guard let autoPick = entry.autoPick, entry.target == autoPick.picked, !entry.isExplore, claim([session]) else {
            NSSound.beep()
            return
        }
        entry.autoPick = nil
        entry.autoPickDeclined = true
        updateHeaders(of: session)
        Task { @MainActor in
            defer { release([session]) }
            await restore(autoPick.previous, on: session)
            // What the server compiles now, also when the restore failed.
            entry.target = await session.slangCompilationTarget
            entry.isExplore = await session.isInChosenExploreMode
            recordLastSet(autoPick.previous == CompilationState(target: nil, isExplore: false) ? nil : SlangProfileChoice(autoPick.previous), session: session)
            FilePreviewLanguageFeatures.designHierarchyDidChange(session: session)
        }
    }

    /// When a waveform's top scope (or the scope below a simulator wrapper) names exactly one
    /// profile's `--top`, builds from that profile. Only for a server with no top level that cmux
    /// was not told to keep in explore mode. True when it did.
    static func autoPickProfile(
        session: LanguageServerSession,
        dumpTops: [String],
        dumpChildren: [String: [String]],
        progress: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Bool {
        let key = ObjectIdentifier(session)
        if let running = autoPickTasks[key] { return await running.value }
        let task = Task { @MainActor in
            await runAutoPick(session: session, dumpTops: dumpTops, dumpChildren: dumpChildren, progress: progress)
        }
        autoPickTasks[key] = task
        let picked = await task.value
        autoPickTasks[key] = nil
        return picked
    }

    private static func runAutoPick(
        session: LanguageServerSession,
        dumpTops: [String],
        dumpChildren: [String: [String]],
        progress: @MainActor @Sendable (String) -> Void
    ) async -> Bool {
        let entry = entry(for: session)
        guard entry.target == nil, !entry.isExplore, !entry.autoPickDeclined, !isBusy(session),
              let editor = FilePreviewLanguageFeatures.allLinkables.first(where: { $0.linkSession?.session === session }),
              await session.supportsCommand("slang.setBuildFile") == true else { return false }
        let profiles = await profiles(for: editor)
        guard let profile = SlangProfileCatalog.profile(matchingDumpTops: dumpTops, children: dumpChildren, in: profiles),
              claim([session]) else { return false }
        defer { release([session]) }
        // The user may have chosen a top level, build file or explore mode while the profiles were listed.
        guard entry.target == nil, !entry.isExplore, !entry.autoPickDeclined, await session.slangCompilationTarget == nil,
              await !session.isInChosenExploreMode else { return false }
        // A server error is not "no tops": nothing is switched while it can't be read.
        guard let tops = try? await session.slangScopeChildren(""), tops.allSatisfy({ $0.kind == "Package" }) else { return false }
        progress(String(
            format: String(
                localized: "slangProfile.autoPick",
                defaultValue: "Building the design from profile %@: its --top matches the waveform’s top scope…"
            ),
            profile.name
        ))
        let previous = await currentState(of: session)
        let outcome = await applyProfile(profile, to: session, editor: editor)
        slangProfileLogger.info("auto-picked slang profile \(profile.path, privacy: .public): \(outcome.tops.count) tops")
        guard !outcome.tops.isEmpty else { return false }
        recordLastSet(.buildFile(session.serverPath(for: URL(fileURLWithPath: profile.path))), session: session)
        // Never silently: the header says what changed, with Undo, for a while.
        entry.autoPick = AutoPick(profile: profile.name, picked: entry.target, previous: previous, at: Date())
        updateHeaders(of: session)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(autoPickNoticeDuration + 0.5))
            updateHeaders(of: session)
        }
        return true
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

// MARK: - Per-file profiles

/// Each file keeps the profile (build file, top level, explore mode) chosen while it was the
/// active file; a file with none follows the root's last-set profile. When a file becomes active
/// the server switches to its profile (`SlangProfileFollower`: debounced, never for the profile
/// it already compiles). One server per root is switched rather than one kept per profile: a
/// switch measured 0.04–0.46 s on designs of 500–3,300 instances (1.6–4 s on a 30,000-instance
/// one), while every extra server costs its own memory (1.4–2.8 GB on that design).
/// The choices persist in user defaults per root (`SlangProfileAssignmentStore`), keyed by
/// server paths: the remote path for an SSH file.
extension SlangCompilationActions {
    private static let assignmentStore = SlangProfileAssignmentStore()
    /// Every root's choices, read from the store on first use.
    private static var loadedAssignments: [String: SlangProfileAssignments]?

    private static func assignments(rootKey: String) -> SlangProfileAssignments {
        if loadedAssignments == nil { loadedAssignments = assignmentStore.load() }
        return loadedAssignments?[rootKey] ?? SlangProfileAssignments()
    }

    private static func updateAssignments(rootKey: String, _ change: (inout SlangProfileAssignments) -> Void) {
        var assignments = assignments(rootKey: rootKey)
        let before = assignments
        change(&assignments)
        guard assignments != before else { return }
        loadedAssignments?[rootKey] = assignments
        scheduleAssignmentSave()
    }

    private static var assignmentSave: Task<Void, Never>?
    private static var assignmentsDirty = false
    private static var terminationFlush: (any NSObjectProtocol)?

    /// Writes every root's choices a second after the last change, encoded and written off the
    /// main thread, one write at a time (verify L3). Quitting writes what is left at once.
    private static func scheduleAssignmentSave() {
        assignmentsDirty = true
        if terminationFlush == nil {
            terminationFlush = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    guard assignmentsDirty, let roots = loadedAssignments else { return }
                    assignmentsDirty = false
                    assignmentStore.saveAll(roots)
                }
            }
        }
        let previous = assignmentSave
        previous?.cancel()
        assignmentSave = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            // A write still going on finishes first, so an older copy never lands last.
            await previous?.value
            guard assignmentsDirty, let roots = loadedAssignments else { return }
            assignmentsDirty = false
            let store = assignmentStore
            _ = await Task.detached(priority: .utility) { store.saveAll(roots) }.value
        }
    }

    /// The editor's file as the server names it (the remote path for an SSH file).
    private static func fileKey(of editor: FilePreviewLanguageFeatures) -> String? {
        guard let (session, documentURI) = editor.linkSession else { return nil }
        return session.serverPath(for: documentURI)
    }

    /// The profile `editor`'s file builds from: its own, else the root's last-set one.
    static func profileChoice(for editor: FilePreviewLanguageFeatures) -> SlangProfileChoice? {
        guard let file = fileKey(of: editor) else { return nil }
        return assignments(rootKey: editor.linkRootKey).choice(forFile: file)
    }

    /// The editor whose file a choice made on `session` belongs to: the given one, else the one
    /// made active last, else the one used last.
    private static func choosingEditor(_ editor: FilePreviewLanguageFeatures?, session: LanguageServerSession) -> FilePreviewLanguageFeatures? {
        if let editor, editor.linkSession?.session === session { return editor }
        if let active = entry(for: session).activeEditor, active.linkSession?.session === session { return active }
        return FilePreviewLanguageFeatures.allLinkables
            .filter { $0.linkSession?.session === session }
            .max { $0.lastActivity < $1.lastActivity }
    }

    /// The user made `session` compile `choice` with `editor`'s file active (nil: from the Files
    /// panel or the View menu, for the file active then): the file's profile and the last-set one.
    static func recordChoice(_ choice: SlangProfileChoice, session: LanguageServerSession, editor: FilePreviewLanguageFeatures?) {
        guard let owner = choosingEditor(editor, session: session) else { return }
        let file = fileKey(of: owner)
        updateAssignments(rootKey: owner.linkRootKey) { $0.choose(choice, file: file) }
        // Chosen again: a profile that failed on an earlier focus is built again on the next one.
        entry(for: session).follower?.userChose(choice)
        updateHeaders(of: session)
    }

    /// The waveform link chose what `session` compiles (or its Undo put it back): only the
    /// last-set profile, no file's own.
    static func recordLastSet(_ choice: SlangProfileChoice?, session: LanguageServerSession) {
        guard let owner = choosingEditor(nil, session: session) else { return }
        updateAssignments(rootKey: owner.linkRootKey) { $0.setLastSet(choice) }
        updateHeaders(of: session)
    }

    /// `editor`'s file follows the last-set profile again, and the server follows it.
    static func followLastSetProfile(editor: FilePreviewLanguageFeatures) {
        guard let file = fileKey(of: editor) else { return }
        updateAssignments(rootKey: editor.linkRootKey) { $0.forgetFile(file) }
        editorBecameActive(editor)
        editor.updateSlangHeader()
    }

    /// `editor` became the active one (focus, a click, a tab switch or an open): once focus
    /// settles its server compiles the file's profile.
    static func editorBecameActive(_ editor: FilePreviewLanguageFeatures) {
        installKeyWindowFollow()
        // An editor has focus now, not a waveform, for every server.
        forgetActiveWaveforms()
        guard let session = editor.linkSession?.session else { return }
        let entry = entry(for: session)
        entry.activeEditor = editor
        follower(for: session, entry: entry).activeFileChanged()
    }

    /// The profile each waveform viewer was elaborated against or auto-picked (in memory only).
    private static let waveformChoices = NSMapTable<FilePreviewPanel, WaveformChoice>.weakToStrongObjects()

    /// A choice is the server's it was recorded with: a waveform's profile of one root is never
    /// applied to another root's server (verify L6).
    private final class WaveformChoice {
        let choice: SlangProfileChoice
        weak var session: LanguageServerSession?
        init(_ choice: SlangProfileChoice, session: LanguageServerSession) {
            self.choice = choice
            self.session = session
        }
    }

    /// The waveform viewer `waveform` was linked to `session`'s design as it compiles now (its
    /// auto-pick, the link's elaboration, or the design it opened against): focusing it brings that back.
    static func recordWaveformDesign(_ waveform: FilePreviewPanel, session: LanguageServerSession) async {
        let state = await currentState(of: session)
        recordWaveformChoice(SlangProfileChoice(state), waveform: waveform, session: session)
    }

    /// `waveform`'s profile on `session` is `choice` (a profile matching its dump).
    static func recordWaveformChoice(_ choice: SlangProfileChoice, waveform: FilePreviewPanel, session: LanguageServerSession) {
        waveformChoices.setObject(WaveformChoice(choice, session: session), forKey: waveform)
    }

    /// `waveform`'s recorded profile, if it was recorded on `session`.
    private static func waveformChoice(_ waveform: FilePreviewPanel, session: LanguageServerSession) -> SlangProfileChoice? {
        guard let recorded = waveformChoices.object(forKey: waveform), recorded.session === session else { return nil }
        return recorded.choice
    }

    /// The server a focused waveform follows: its paired editor's, else the one its profile was
    /// recorded with, else the workspace's most recent editor's (which changes with focus).
    private static func followedSession(for waveform: FilePreviewPanel) -> LanguageServerSession? {
        WaveformSourceLink.pairedSession(for: waveform)
            ?? waveformChoices.object(forKey: waveform)?.session
            ?? WaveformSourceLink.linkedSession(for: waveform)
    }

    /// A waveform viewer took focus (a click, its tab, its window): its server builds the profile
    /// the waveform was elaborated against, so cross-probing, FSM, enums and inline values map to it.
    static func waveformBecameActive(_ waveform: FilePreviewPanel) {
        guard waveform.previewMode == .waveform, let session = followedSession(for: waveform) else { return }
        installKeyWindowFollow()
        let entry = entry(for: session)
        entry.activeWaveform = waveform
        follower(for: session, entry: entry).activeFileChanged()
    }

    /// Follows windows becoming key (Cmd-`, a title-bar click): the key window's focused editor is the active file.
    private static var keyWindowFollow: SlangKeyWindowFollow?

    private static func installKeyWindowFollow() {
        guard keyWindowFollow == nil else { return }
        keyWindowFollow = SlangKeyWindowFollow(name: NSWindow.didBecomeKeyNotification) { object in
            guard let window = object as? NSWindow else { return }
            if let textView = window.firstResponder as? SavingTextView {
                textView.languageFeatures?.editorDidBecomeActive()
                return
            }
            // A waveform viewer's page (or a view inside it) has focus.
            var view = window.firstResponder as? NSView
            while let current = view, !(current is MarkdownWebView) { view = current.superview }
            (view as? MarkdownWebView)?.onBecomeFirstResponder?()
        }
    }

    /// `path` (the server's form) was saved or reloaded from disk in `session`: a profile that
    /// elaborated nothing is tried again, now for the active file, only if its build includes the
    /// file (verify R2), so saving any source doesn't rebuild every broken profile.
    static func designFileSaved(_ path: String, session: LanguageServerSession) {
        let entry = entry(for: session)
        guard let follower = entry.follower else { return }
        let editor = entry.activeEditor ?? FilePreviewLanguageFeatures.allLinkables.first { $0.linkSession?.session === session }
        let listing = editor.flatMap { cachedListing(for: $0) }
        let root = editor?.linkContext?.rootURI?.path
        let serverPath = { (file: String) in session.serverPath(for: URL(fileURLWithPath: file)) }
        let cleared = follower.designFileSaved { choice in
            switch choice {
            case .topLevel(let file):
                return file == path
            case .buildFile(let build):
                if build == path { return true }
                // A build whose files aren't known (not listed yet) may include it.
                guard let root, let profile = listing?.profiles.first(where: { serverPath($0.path) == build }) else { return true }
                // slang resolves a build file's relative paths against the server's folder. Sources of
                // nested command files aren't read here, so a build with any may include it.
                // Neither are files reached through globs or library and include directories (verify V1).
                return !profile.buildFile.commandFiles.isEmpty || profile.buildFile.mayReachUnlistedFiles
                    || profile.buildFile.involves(path, buildFilePath: profile.path, baseDirectory: root, normalize: serverPath)
            case .explore, .configured:
                // Every file of the root is part of these.
                return true
            }
        }
        if cleared, entry.activeWaveform != nil || entry.activeEditor?.linkSession?.session === session {
            follower.activeFileChanged()
        }
    }

    private static func follower(for session: LanguageServerSession, entry: Entry) -> SlangProfileFollower {
        if let follower = entry.follower { return follower }
        let follower = SlangProfileFollower(hooks: .init(
            wanted: { [weak entry, weak session] in
                guard let entry else { return nil }
                if let waveform = entry.activeWaveform {
                    let choice = session.flatMap { waveformChoice(waveform, session: $0) }
                    return SlangProfileFocus.waveform(choice).wanted(in: SlangProfileAssignments())
                }
                guard let editor = entry.activeEditor, let file = fileKey(of: editor) else { return nil }
                return SlangProfileFocus.file(file).wanted(in: assignments(rootKey: editor.linkRootKey))
            },
            current: { [weak session] in
                guard let session else { return CompilationState(target: nil, isExplore: false) }
                return await currentState(of: session)
            },
            isBusy: { [weak session] in session.map { Self.isBusy($0) } ?? true },
            apply: { [weak session, weak entry] choice in
                guard let session, let entry else { return .error }
                return await follow(choice, session: session, entry: entry)
            },
            missing: { [weak entry] choice in
                guard let entry, let path = choice.path else { return }
                if let waveform = entry.activeWaveform, waveformChoices.object(forKey: waveform)?.choice.path == path {
                    waveformChoices.removeObject(forKey: waveform)
                }
                guard let editor = entry.activeEditor else { return }
                updateAssignments(rootKey: editor.linkRootKey) { $0.profileWasRemoved(path) }
            },
            resolve: { [weak session, weak entry] choice in
                guard let session, let entry else { return choice }
                return resolved(choice, session: session, entry: entry)
            }
        ))
        entry.follower = follower
        return follower
    }

    /// Switches `session` to `choice` for the active file. Nothing is asked or shown on success
    /// (the header changes); a profile that elaborates nothing is put back and reported once, and
    /// a switch that throws is put back, reported and tried again on the next focus.
    private static func follow(_ choice: SlangProfileChoice, session: LanguageServerSession, entry: Entry) async -> SlangProfileFollower.ApplyResult {
        // Not the profile's fault: tried again on the next focus (verify R1).
        if case .buildFile = choice, await session.supportsCommand("slang.setBuildFile") != true { return .error }
        // Another change took the server since the follower looked: it waits and tries again.
        guard claim([session]) else { return .busy }
        defer { release([session]) }
        let editor = entry.activeEditor
        entry.following = choice
        updateHeaders(of: session)
        defer {
            entry.following = nil
            updateHeaders(of: session)
        }
        await editor?.sendCurrentText()
        let previous = await currentState(of: session)
        // `.configured` arrives resolved to the config's build when the listing is known; read it now if not.
        if choice == .configured, let editor, cachedListing(for: editor) == nil {
            _ = await refreshListing(for: editor)?.value
        }
        let configured = configuredBuild(session: session, entry: entry)
        _ = await session.takeRecentErrorMessages()
        var failure: (any Error)?
        do {
            // At runtime, never a restart: the config's build is set as a build file (verify M1).
            try await session.slangSwitch(to: choice, configuredBuild: configured)
        } catch {
            failure = error
        }
        let showsMessage = { (lines: [String]) in
            guard let editor, entry.activeEditor === editor, entry.activeWaveform == nil else { return }
            editor.showLinkMessage(lines.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        if let failure {
            // A thrown switch (an ssh timeout, a restart, a lost connection): the previous
            // compilation is put back and the profile is tried again on the next focus (verify R1).
            slangProfileLogger.error("following the active file's profile failed: \(String(describing: failure), privacy: .public)")
            let detail = userMessage(for: failure)
            try? await session.slangSwitch(to: SlangProfileChoice(previous), configuredBuild: configured)
            FilePreviewLanguageFeatures.designHierarchyDidChange(session: session)
            if let path = choice.path, await !fileExists(path, editor: editor) {
                slangProfileLogger.info("profile \(path, privacy: .public) is gone; its files follow the last-set profile")
                return .missing
            }
            // Once per outage: later focuses back off (the follower) and stay quiet until a switch works.
            guard !entry.switchErrorShown else { return .error }
            entry.switchErrorShown = true
            showsMessage([
                String(
                    format: String(localized: "slangProfile.switchError.detail", defaultValue: "Couldn’t switch slang-server to %@; it is tried again the next time this file is focused."),
                    profileName(of: choice)
                ),
                detail,
            ])
            return .error
        }
        // The switch went through: the outage, if any, is over.
        entry.switchErrorShown = false
        // An unanswered scope query (a lost connection) says nothing about the profile: only an
        // answer with no top levels counts as elaborating nothing.
        let tops = (try? await session.slangScopeChildren(""))?.filter { $0.kind != "Package" }.map(\.name)
        if let path = choice.path, tops?.isEmpty == true {
            // What went wrong, read before the restore replaces the compilation.
            let summary = await session.diagnosticsSummary()
            let errors = await session.takeRecentErrorMessages()
            let detail = Outcome(tops: [], instanceCount: 0, summary: summary, serverErrors: errors).failureDetail
            try? await session.slangSwitch(to: SlangProfileChoice(previous), configuredBuild: configured)
            FilePreviewLanguageFeatures.designHierarchyDidChange(session: session)
            if await !fileExists(path, editor: editor) {
                slangProfileLogger.info("profile \(path, privacy: .public) is gone; its files follow the last-set profile")
                return .missing
            }
            // Reported once: the follower doesn't build this profile again until a file of its
            // build is saved or the user chooses it.
            showsMessage([
                String(
                    format: String(localized: "slangProfile.switchFailed.detail", defaultValue: "slang-server elaborated nothing from profile %@."),
                    profileName(of: choice)
                ),
                detail,
            ])
            return .failed
        }
        let applied = choice.resolved(configuredBuild: configured)
        entry.target = applied.state.target
        entry.isExplore = applied == .explore
        WaveformSourceLink.topLevelWasChosen(session: session)
        FilePreviewLanguageFeatures.designHierarchyDidChange(session: session)
        return .applied
    }

    /// The config's build of `session`'s root as the server names it, from the active (or any)
    /// editor's cached listing; nil when no config names one or nothing is listed yet.
    private static func configuredBuild(session: LanguageServerSession, entry: Entry) -> String? {
        let editor = entry.activeEditor ?? FilePreviewLanguageFeatures.allLinkables.first { $0.linkSession?.session === session }
        guard let editor, let root = editor.linkContext?.rootURI?.path, let listing = cachedListing(for: editor),
              let build = SlangServerConfigFile.configuredBuild(in: listing.configs, root: root) else { return nil }
        return session.serverPath(for: URL(fileURLWithPath: build))
    }

    /// `.configured` as the config's build, so it is compared with (and switched to) what the server compiles.
    private static func resolved(_ choice: SlangProfileChoice, session: LanguageServerSession, entry: Entry) -> SlangProfileChoice {
        choice.resolved(configuredBuild: configuredBuild(session: session, entry: entry))
    }

    /// Claims `session` for a choice the user made (menu, palette): after a focus switch that is
    /// running, instead of failing (verify L1). False when another user change holds it.
    static func claimForUser(_ session: LanguageServerSession) async -> Bool {
        for _ in 0..<4 {
            if claim([session]) { return true }
            let entry = entry(for: session)
            guard entry.following != nil, let follower = entry.follower else { return false }
            await follower.waitForRunningSwitch()
        }
        return claim([session])
    }

    /// Whether `path` is still there (on the editor's SSH host for a remote file). An unanswered
    /// ssh counts as there, so a dropped connection never forgets anyone's profile.
    private static func fileExists(_ path: String, editor: FilePreviewLanguageFeatures?) async -> Bool {
        guard let remote = editor?.linkContext?.remote else { return FileManager.default.fileExists(atPath: path) }
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let answer = await FilePreviewLanguageDocumentContext.runRemoteShell(
            "if [ -e \(quoted) ]; then printf yes; else printf no; fi",
            configuration: remote.configuration
        )
        return answer?.trimmingCharacters(in: .whitespacesAndNewlines) != "no"
    }

    /// A Files panel rename or move: profiles and files below it keep their choices under the new path.
    /// `hostIdentity`: `local`, or the SSH route.
    static func pathWasMoved(from old: String, to new: String, hostIdentity: String) {
        if loadedAssignments == nil { loadedAssignments = assignmentStore.load() }
        // Local server paths are real paths; the old one no longer exists, so resolve its folder.
        let (from, to) = hostIdentity == "local"
            ? (LanguageServerSession.realPath(old), LanguageServerSession.realPath(new))
            : (old, new)
        for rootKey in (loadedAssignments ?? [:]).keys where rootKey.hasPrefix(hostIdentity + "|") {
            updateAssignments(rootKey: rootKey) { $0.pathWasMoved(from: from, to: to) }
        }
        for editor in FilePreviewLanguageFeatures.allLinkables where editor.linkHostIdentity == hostIdentity {
            editor.updateSlangHeader()
        }
    }

    /// A profile's short name for the header and messages.
    static func profileName(of choice: SlangProfileChoice) -> String {
        switch choice {
        case .buildFile(let path): return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        case .topLevel(let path): return (path as NSString).lastPathComponent
        case .explore: return String(localized: "slangProfile.header.explore", defaultValue: "explore")
        case .configured: return String(localized: "slangProfile.header.config", defaultValue: "server.json")
        }
    }
}
