import AppKit
import CmuxSyntaxHighlighting
import Foundation
import os

nonisolated private let waveformTraceLogger = Logger(subsystem: "com.cmuxterm.app", category: "WaveformTrace")

/// Driver tracing, phase P1 (status/tracex-design.md): Trace Driver (Ctrl+T, the waveform row
/// menu, the SystemVerilog editor's menu, View > Trace Driver) shows the active driver of a
/// signal at the waveform's marker: the statement that drove the value, the branch taken, and
/// the fan-in with values, each traced one more step with a click.
///
/// The page does the tracing (`cmux-trace.js`, panel and dump provider in `cmux-trace-ui.js`).
/// cmux gives it the design: a cmux-sv-model sidecar (built with the slang library, on the Mac
/// for a local folder and on the SSH host for a remote one, like the FSDB helper) loads the
/// design the editor's slang-server compiles and answers per-instance trace models. cmux also
/// maps dump paths onto design paths (the saved path mapping, else inference against the
/// model's hierarchy) and opens the driving statement in the editor.
@MainActor
enum WaveformTrace {
    // MARK: Design models

    /// One sidecar with one design loaded: per host, server root and slang arguments.
    @MainActor
    final class Design {
        let key: String
        let sidecar: SVModelSidecar
        let args: [String]
        let root: String
        let hostIdentity: String
        var load: Task<SVModelSidecar.Reply, any Error>?
        var hierarchy: (tops: [String], instances: [String])?
        /// slang's messages from loading the design (its errors first), for a row below a module it left out.
        var loadMessages: [String] = []
        /// Instance models resolve asked for (the sidecar builds each anew), at most `maxModels`.
        var models: [String: [String: Any]] = [:]
        static let maxModels = 16

        init(key: String, sidecar: SVModelSidecar, args: [String], root: String, hostIdentity: String) {
            self.key = key
            self.sidecar = sidecar
            self.args = args
            self.root = root
            self.hostIdentity = hostIdentity
        }
    }

    struct Failure: Error {
        let message: String
    }

    private static var designs: [String: Design] = [:]
    /// When each design's first-time sidecar build started (ms since 1970, the page's clock), while it builds.
    private static var buildStarts: [String: Double] = [:]
    /// The viewers waiting for each design's build: every one gets its progress, done and failed.
    private static var buildWaiters: [String: NSHashTable<FilePreviewPanel>] = [:]
    /// Each build's last stage (with its percent or size), for a viewer that joins it.
    private static var buildStates: [String: [String: Any]] = [:]
    /// Builds whose sidecar is installed and now loads the design: a failure from here on is the
    /// design's (slang's), not the build's.
    private static var buildsInstalled: Set<String> = []
    /// Each design's progress calls in order, one after the other.
    private static var buildSends: [String: Task<Void, Never>] = [:]
    /// The dump path of a trace from the editor that waits for a build, per viewer (its Retry).
    private static let buildEntries = NSMapTable<FilePreviewPanel, NSArray>.weakToStrongObjects()
    /// The design each viewer last traced in, for the page's model requests.
    private static let activeDesigns = NSMapTable<FilePreviewPanel, Design>.weakToStrongObjects()
    /// Sidecars kept at most: each holds an elaborated design in memory.
    private static let maxDesigns = 4

    static func bundledSource(bundle: Bundle = .main) -> URL? {
        guard let url = bundle.resourceURL?.appendingPathComponent("vaporview/sv-model", isDirectory: true),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("build.sh").path) else { return nil }
        return url
    }

    /// The loaded design `editor`'s slang-server compiles. Starts (and on first use builds) the sidecar.
    /// `entry`: the dump path of the editor's trace that waits, for the build panel's Retry.
    static func design(for editor: FilePreviewLanguageFeatures, waveform: FilePreviewPanel?, entry: [String]? = nil) async throws -> Design {
        guard let session = editor.linkSession?.session else { throw Failure(message: noEditorMessage) }
        let root = editor.linkRootPath ?? (editor.filePath as NSString).deletingLastPathComponent
        let state = await SlangCompilationActions.currentState(of: session)
        let config = state.target == nil && !state.isExplore ? localConfigBuild(for: editor) : nil
        guard let args = SVModelLoad.arguments(
            target: state.target,
            configBuild: config?.build,
            buildRelativePaths: config?.relative ?? false,
            root: root
        ) else {
            throw Failure(message: String(
                localized: "waveformTrace.noDesign",
                defaultValue: "Choose what slang compiles first: a profile (.f build file) or a top level, from the editor’s slang menu. Driver tracing loads the same design."
            ))
        }
        let key = editor.linkHostIdentity + "|" + root + "|" + args.joined(separator: "\u{1F}")
        let design: Design
        if let known = designs[key] {
            design = known
        } else {
            guard let source = bundledSource() else {
                throw Failure(message: String(
                    localized: "waveformTrace.missingSidecar",
                    defaultValue: "The design model for driver tracing is missing from this build of cmux."
                ))
            }
            let commands = SVModelSidecar.commands(source: source)
            let runner: SVModelSidecar.Runner
            if let remote = editor.linkRemoteRoute {
                let configuration = remote.configuration
                let options = configuration.fileOperationSSHOptions
                runner = { command in
                    .init(executable: "/usr/bin/ssh", arguments: configuration.batchSSHCommandArguments(
                        command: "sh -c '\(command)'",
                        effectiveSSHOptions: options
                    ))
                }
            } else {
                // A GUI app's PATH lacks Homebrew, where CMake usually is.
                runner = { command in
                    .init(executable: "/bin/sh", arguments: ["-c", "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\"; export PATH; " + command])
                }
            }
            let sidecar = SVModelSidecar(runner: runner, launchCommand: commands.launch, installCommand: commands.install, installSource: source)
            design = Design(key: key, sidecar: sidecar, args: args, root: root, hostIdentity: editor.linkHostIdentity)
            if designs.count >= maxDesigns, let oldest = designs.keys.sorted().first, let evicted = designs.removeValue(forKey: oldest) {
                forget(evicted)
            }
            designs[key] = design
        }
        if let waveform { activeDesigns.setObject(design, forKey: waveform) }
        let host = editor.linkRemoteRoute?.configuration.destination
        if let waveform {
            let waiters = buildWaiters[key] ?? NSHashTable<FilePreviewPanel>.weakObjects()
            waiters.add(waveform)
            buildWaiters[key] = waiters
            if let entry { buildEntries.setObject(entry as NSArray, forKey: waveform) } else { buildEntries.removeObject(forKey: waveform) }
            // A trace that joins a build under way (another viewer's, or from the editor, where
            // the page is not asked first): its viewer shows the build and points at it.
            if buildStarts[key] != nil {
                sendBuildProgress(key: key, host: host, buildStates[key] ?? ["stage": "upload"], to: [waveform], focus: true)
            }
        }
        // The handlers are the design's, not one viewer's: progress goes to every viewer waiting.
        design.sidecar.onStatus = { status in
            Task { @MainActor in
                switch status {
                case .building:
                    buildStarts[key] = Date().timeIntervalSince1970 * 1000
                    buildsInstalled.remove(key)
                    for waiter in buildWaiters[key]?.allObjects ?? [] {
                        _ = await waiter.nativeViewSessions.waveform.callTrace("status", argument: buildingMessage(host: host))
                    }
                case .connecting:
                    // After the install: the sidecar starts again and loads the design.
                    guard buildStarts[key] != nil else { return }
                    buildsInstalled.insert(key)
                    buildProgress("load", key: key, host: host)
                }
            }
        }
        design.sidecar.onBuildProgress = { report in
            Task { @MainActor in
                var extra: [String: Any] = [:]
                if let percent = report.percent { extra["percent"] = percent }
                if let bytes = report.bytes { extra["sourceBytes"] = bytes }
                buildProgress(report.stage.rawValue, key: key, host: host, extra)
            }
        }
        let load = design.load ?? Task { @MainActor in
            try await design.sidecar.request(["cmd": "load", "args": design.args, "cwd": design.root])
        }
        design.load = load
        defer {
            // Done waiting: a viewer gets no more of this design's progress unless it asks again.
            if let waveform, buildStarts[key] == nil {
                buildWaiters[key]?.remove(waveform)
                buildEntries.removeObject(forKey: waveform)
            }
        }
        do {
            let reply = try await load.value
            if buildStarts[key] != nil { endBuild("done", key: key, host: host) }
            guard let tops = reply["tops"] as? [String], !tops.isEmpty else {
                throw Failure(message: loadFailedMessage(reply))
            }
            design.loadMessages = reply["messages"] as? [String] ?? []
        } catch let error as Failure {
            design.load = nil
            throw error
        } catch {
            design.load = nil
            if buildStarts[key] != nil, buildsInstalled.contains(key) {
                // Built and installed; loading the design failed (slang, a timeout): the build panel
                // ends and the trace says why, as for a design model that was there already.
                endBuild("done", key: key, host: host)
            } else if buildStarts[key] != nil {
                // The build failed: the panel shows why with the log's last lines and Retry, which
                // starts over with a new sidecar.
                let detail: String
                let message: String
                if case .setupFailed(let code, let tail)? = error as? SVModelSidecar.Failure {
                    detail = tail
                    message = sidecarMessage(SVModelSidecar.Failure.setupFailed(code: code, detail: ""), host: host)
                } else {
                    detail = ""
                    message = sidecarMessage(error, host: host)
                }
                endBuild("failed", key: key, host: host, ["message": message, "log": detail])
                if designs[key] === design { designs.removeValue(forKey: key) }
                forget(design)
            }
            throw Failure(message: sidecarMessage(error, host: host))
        }
        return design
    }

    /// Stops a design dropped from `designs`, and lets its viewers' next model request say so
    /// (their next trace makes a new one) instead of asking a stopped sidecar.
    private static func forget(_ design: Design) {
        design.sidecar.stop()
        for waveform in activeDesigns.keyEnumerator().allObjects.compactMap({ $0 as? FilePreviewPanel })
        where activeDesigns.object(forKey: waveform) === design {
            activeDesigns.removeObject(forKey: waveform)
        }
    }

    /// A stage of the first-time build, for every viewer waiting (cmux-trace-ui.js progress()).
    private static func buildProgress(_ stage: String, key: String, host: String?, _ extra: [String: Any] = [:]) {
        guard buildStarts[key] != nil else { return }
        var state: [String: Any] = ["stage": stage]
        state.merge(extra) { _, new in new }
        buildStates[key] = state
        sendBuildProgress(key: key, host: host, state, to: buildWaiters[key]?.allObjects ?? [], focus: false)
    }

    /// The build's end (`done` or `failed`) for every viewer waiting; the build is over.
    private static func endBuild(_ stage: String, key: String, host: String?, _ extra: [String: Any] = [:]) {
        var state: [String: Any] = ["stage": stage]
        state.merge(extra) { _, new in new }
        sendBuildProgress(key: key, host: host, state, to: buildWaiters[key]?.allObjects ?? [], focus: false)
        buildStarts[key] = nil
        buildStates[key] = nil
        buildsInstalled.remove(key)
        buildWaiters[key] = nil
    }

    /// Sends a build state to viewers, after the design's earlier progress calls (in order).
    private static func sendBuildProgress(key: String, host: String?, _ state: [String: Any], to waveforms: [FilePreviewPanel], focus: Bool) {
        guard let startedAt = buildStarts[key], !waveforms.isEmpty else { return }
        let calls: [(FilePreviewPanel, [String: Any])] = waveforms.map { waveform in
            var argument = state
            argument["startedAt"] = startedAt
            argument["host"] = host ?? NSNull()
            if focus { argument["focus"] = true }
            if let entry = buildEntries.object(forKey: waveform) { argument["entry"] = ["dumpPath": entry, "time": NSNull()] }
            return (waveform, argument)
        }
        let previous = buildSends[key]
        buildSends[key] = Task { @MainActor in
            await previous?.value
            for (waveform, argument) in calls {
                _ = await waveform.nativeViewSessions.waveform.callTrace("progress", argument: argument)
            }
        }
    }

    /// The `"build"` (and `"buildRelativePaths"`) of the folder's local server.json, then its
    /// server.json (local folders only).
    private static func localConfigBuild(for editor: FilePreviewLanguageFeatures) -> (build: String, relative: Bool)? {
        guard editor.linkRemoteRoute == nil, let root = editor.linkRootPath else { return nil }
        for relative in [SlangServerConfigFile.relativePath, ".slang/server.json"] {
            let path = SlangServerConfigFile.path(inWorkspace: root, relativePath: relative)
            let data = FileManager.default.contents(atPath: path)
            if let build = SlangServerConfigFile.build(in: data) {
                let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                return (build, object?["buildRelativePaths"] as? Bool ?? false)
            }
        }
        return nil
    }

    // MARK: Path mapping

    /// The design path of dump signal `dumpPath`, and the prefixes the page maps fan-in paths back with.
    static func resolve(dumpPath: [String], waveform: FilePreviewPanel) async throws -> [String: Any] {
        guard let editor = WaveformSourceLink.linkedEditor(for: waveform) else { throw Failure(message: noEditorMessage) }
        let design = try await design(for: editor, waveform: waveform)
        let key = await WaveformSourceLink.mappingKey(rootKey: editor.linkRootKey, waveform: waveform)
        let mapping = key.map(WaveformSourceLink.mapping(forKey:)) ?? HierarchyPathMapping()
        let outcome = try await SVModelResolve.resolve(
            dumpPath: dumpPath,
            mapping: mapping,
            loadMessages: design.loadMessages,
            lookup: { path in await lookup(path, in: design) },
            model: { path in await instanceModel(path, in: design) },
            designRoots: { try await designRoots(of: design) },
            dumpChildren: { path in await WaveformSourceLink.dumpChildren(path, in: waveform) }
        )
        switch outcome {
        case .signal(let designPath, let designPrefix, let dumpPrefix):
            return ["designPath": designPath, "designPrefix": designPrefix, "dumpPrefix": dumpPrefix]
        case .notElaborated(let instance):
            throw Failure(message: notElaboratedMessage(instance, messages: design.loadMessages))
        case .notInDesign:
            throw Failure(message: String(
                format: String(
                    localized: "waveformTrace.notInDesign",
                    defaultValue: "%@ was not found in the design. If the dump names the design differently, edit View > Waveform Path Mapping…"
                ),
                HierarchyPathMapping.join(dumpPath)
            ))
        }
    }

    /// The page's design query for a design path traced from a dump path: the path and the
    /// prefixes it maps fan-in paths back with.
    private static func result(designPath: String, dumpPath: [String]) -> [String: Any] {
        let prefixes = SVModelLoad.prefixes(dumpPath: dumpPath, designPath: HierarchyPathMapping.segments(designPath))
        return ["designPath": designPath, "designPrefix": prefixes.designPrefix, "dumpPrefix": prefixes.dumpPrefix]
    }

    /// The sidecar's `lookup`: the deepest instance of the design on `path` and the rest below it.
    private static func lookup(_ path: String, in design: Design) async -> (instance: String, name: String)? {
        guard let found = try? await design.sidecar.request(["cmd": "lookup", "path": path]),
              let instance = found["instance"] as? String, let name = found["name"] as? String else { return nil }
        return (instance, name)
    }

    /// An instance's model, kept per design (a top's is large; resolve asks for it on every click).
    private static func instanceModel(_ path: String, in design: Design) async -> [String: Any]? {
        if let known = design.models[path] { return known }
        guard let model = try? await design.sidecar.request(["cmd": "instance", "path": path])["model"] as? [String: Any] else { return nil }
        if design.models.count >= Design.maxModels { design.models.removeAll() }
        design.models[path] = model
        return model
    }

    /// The row's instance is missing from the design model: which one, slang's first error, and
    /// where the design driver tracing loads is chosen.
    private static func notElaboratedMessage(_ instance: String, messages: [String]) -> String {
        let text = String(
            format: String(
                localized: "waveformTrace.notElaborated",
                defaultValue: "%@ is not in the design model: slang could not elaborate it. Check the editor’s slang profile (.f build file) or top level, which driver tracing loads."
            ),
            instance
        )
        guard let detail = SVModelResolve.loadDetail(messages), !detail.isEmpty else { return text }
        return text + "\n\n" + detail
    }

    /// Each design top and its children, for inference (SVModelResolve.designRoots).
    private static func designRoots(of design: Design) async throws -> [String: [HierarchyNode]] {
        let hierarchy: (tops: [String], instances: [String])
        if let known = design.hierarchy {
            hierarchy = known
        } else {
            let reply = try await design.sidecar.request(["cmd": "instances"])
            hierarchy = (reply["tops"] as? [String] ?? [], reply["instances"] as? [String] ?? [])
            design.hierarchy = hierarchy
        }
        return await SVModelResolve.designRoots(tops: hierarchy.tops, instances: hierarchy.instances) { path in
            await instanceModel(path, in: design)
        }
    }

    // MARK: Entry points

    /// Ctrl+T and View > Trace Driver: the focused viewer's selected row, or the signal at the
    /// caret of a SystemVerilog editor next to a viewer. False (the key goes on) otherwise.
    static func performFromShortcut(window: NSWindow?) -> Bool {
        if let waveform = WaveformSourceLink.focusedWaveformPanel(in: window) {
            guard !waveform.nativeViewSessions.waveform.isEditableElementFocused else { return false }
            traceSelectedSignal(in: waveform)
            return true
        }
        guard let features = AppDelegate.shared?.shortcutFocusedSavingTextView(in: window)?.languageFeatures else { return false }
        return features.traceDriverUnderCaret()
    }

    /// Ctrl+Shift+T and View > Trace X to Root: the focused viewer's selected row at its marker,
    /// followed back along the fan-in its x came by. False (the key goes on) without a viewer.
    static func performXRootFromShortcut(window: NSWindow?) -> Bool {
        guard let waveform = WaveformSourceLink.focusedWaveformPanel(in: window),
              !waveform.nativeViewSessions.waveform.isEditableElementFocused else { return false }
        Task { @MainActor in
            _ = await waveform.nativeViewSessions.waveform.callTrace("xRoot", argument: ["path": NSNull(), "time": NSNull()])
        }
        return true
    }

    /// Traces the viewer's selected row at its marker (the page asks for the design path).
    static func traceSelectedSignal(in waveform: FilePreviewPanel) {
        Task { @MainActor in
            _ = await waveform.nativeViewSessions.waveform.callTrace("driver", argument: ["path": NSNull(), "time": NSNull()])
        }
    }

    /// The editor's Trace Driver: the signal at `position`, in the instance the user picks, at the
    /// viewer's marker. Returns a message for the user when it could not, nil when the page traces.
    static func traceFromEditor(
        session: LanguageServerSession,
        documentURI: URL,
        position: LSPPosition,
        symbol: WaveformSourceLink.LinkSymbol,
        editor: FilePreviewLanguageFeatures,
        chooseInstance: ([String]) async -> [String],
        progress: @escaping @MainActor @Sendable (String) -> Void
    ) async -> String? {
        guard let waveform = WaveformSourceLink.waveformPanel(near: editor.linkPanel) else {
            return String(localized: "waveformLink.noWaveform", defaultValue: "Open a waveform (VCD, FST, GHW or FSDB) in this workspace first.")
        }
        let designPath: String
        switch await WaveformSourceLink.chosenDesignPaths(
            session: session,
            documentURI: documentURI,
            position: position,
            symbol: symbol,
            waveform: waveform,
            chooseInstance: chooseInstance,
            progress: progress
        ) {
        case .message(let message):
            return message
        case .paths(let paths):
            guard let first = paths.first else { return nil }
            designPath = first
        }
        guard let key = await WaveformSourceLink.mappingKey(rootKey: editor.linkRootKey, waveform: waveform) else {
            return WaveformSourceLink.waveformLoadingMessage
        }
        var dumpPath: [String]
        switch await WaveformSourceLink.resolveDumpPaths(designPath, session: session, waveform: waveform, key: key, progress: progress) {
        case .found(let found):
            let picked = found.count > 1 ? await chooseInstance(found) : found
            guard let first = picked.first else { return nil }
            dumpPath = HierarchyPathMapping.segments(first)
        case .notDumped(let scope):
            // Traced all the same: the engine computes a value the dump lacks.
            dumpPath = HierarchyPathMapping.segments(scope) + [HierarchyPathMapping.segments(designPath).last ?? designPath]
        case .instance:
            return String(
                format: String(localized: "waveformTrace.isInstance", defaultValue: "%@ is an instance. Trace Driver traces signals."),
                designPath
            )
        case .notFound:
            return String(
                format: String(
                    localized: "waveformLink.notInWaveform",
                    defaultValue: "%@ is not in this waveform. If the dump names the design differently, edit View > Waveform Path Mapping…"
                ),
                designPath
            )
        }
        let built: Design
        do {
            built = try await design(for: editor, waveform: waveform, entry: dumpPath)
        } catch let error as Failure {
            return error.message
        } catch {
            return error.localizedDescription
        }
        var argument = result(designPath: designPath, dumpPath: dumpPath)
        argument["time"] = NSNull()
        editor.closeLinkProgress()
        // The build's done (queued behind its progress calls) before the trace, as the page expects.
        await buildSends[built.key]?.value
        _ = await waveform.nativeViewSessions.waveform.callTrace("driverOfDesign", argument: argument)
        return nil
    }

    /// The editor's context menu item.
    static func editorMenuItem(target: AnyObject, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: "filePreview.language.traceDriver", defaultValue: "Trace Driver at Marker"),
            action: action,
            keyEquivalent: ""
        )
        let shortcut = KeyboardShortcutSettings.shortcut(for: .traceWaveformDriver)
        if let key = shortcut.menuItemKeyEquivalent {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = shortcut.modifierFlags
        }
        item.target = target
        return item
    }

    // MARK: Page messages

    /// `{type: 'trace', event, ...}` from the viewer page.
    static func pageReported(_ body: [String: Any], waveform: FilePreviewPanel) {
        let page = waveform.nativeViewSessions.waveform
        switch body["event"] as? String {
        case "resolve":
            guard let id = (body["id"] as? NSNumber)?.intValue else { return }
            guard let dumpPath = WaveformSourceLink.dumpPath(fromPage: body["dumpPath"]) else {
                reply(page, id: id, error: "badRequest", message: "")
                return
            }
            Task { @MainActor in
                do {
                    reply(page, id: id, result: try await resolve(dumpPath: dumpPath, waveform: waveform))
                } catch let error as Failure {
                    reply(page, id: id, error: "resolve", message: error.message)
                } catch {
                    reply(page, id: id, error: "resolve", message: error.localizedDescription)
                }
            }
        case "model":
            guard let id = (body["id"] as? NSNumber)?.intValue else { return }
            let cmd = body["cmd"] as? String
            guard cmd == "instance" || cmd == "lookup" || cmd == "writers", let path = body["path"] as? String, path.utf16.count <= 4096 else {
                reply(page, id: id, error: "badRequest", message: "")
                return
            }
            Task { @MainActor in
                guard let design = activeDesigns.object(forKey: waveform) else {
                    reply(page, id: id, error: "noDesign", message: noEditorMessage)
                    return
                }
                do {
                    let answer = try await design.sidecar.request(["cmd": cmd ?? "", "path": path])
                    if cmd == "instance" {
                        reply(page, id: id, result: answer["model"] ?? NSNull())
                    } else if cmd == "writers" {
                        reply(page, id: id, result: answer["writers"] ?? [String]())
                    } else {
                        reply(page, id: id, result: ["instance": answer["instance"] ?? NSNull(), "name": answer["name"] ?? NSNull()])
                    }
                } catch SVModelSidecar.Failure.request(code: "noInstance", message: _) {
                    reply(page, id: id, result: NSNull())
                } catch {
                    reply(page, id: id, error: "model", message: sidecarMessage(error, host: nil))
                }
            }
        case "engine":
            guard let id = (body["id"] as? NSNumber)?.intValue else { return }
            WaveformTraceVerdi.answer(body, id: id, waveform: waveform) { result in reply(page, id: id, result: result) }
        case "buildInfo":
            openBuildDoc(near: waveform)
        case "step", "open":
            let loc = body["event"] as? String == "open" ? body["loc"] : ((body["step"] as? [String: Any])?["stmt"] as? [String: Any])?["loc"]
            if let location = location(fromPage: loc) { open(location, near: waveform) }
        default:
            break
        }
    }

    /// The bundled doc on what the first-time build makes (trace-design-model.md), beside the
    /// waveform (its tab again when it is open). It is opened from a copy in the caches folder:
    /// the markdown pane can save, and the app bundle is not the place for that.
    private static func openBuildDoc(near waveform: FilePreviewPanel) {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("vaporview/trace-design-model.md"),
              let data = FileManager.default.contents(atPath: source.path),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let workspace = AppDelegate.shared?.workspaceContainingPanel(panelId: waveform.id, preferredWorkspaceId: waveform.workspaceId)?.workspace
        else { return }
        let folder = caches.appendingPathComponent("cmux", isDirectory: true)
        let copy = folder.appendingPathComponent("trace-design-model.md")
        if FileManager.default.contents(atPath: copy.path) != data {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard (try? data.write(to: copy, options: .atomic)) != nil else { return }
        }
        _ = workspace.openOrFocusMarkdownSplit(from: waveform.id, filePath: copy.path)
    }

    private static func reply(_ page: FilePreviewWaveformSession, id: Int, result: Any) {
        Task { @MainActor in _ = await page.callTrace("reply", argument: ["id": id, "ok": true, "result": result]) }
    }

    private static func reply(_ page: FilePreviewWaveformSession, id: Int, error: String, message: String) {
        Task { @MainActor in _ = await page.callTrace("reply", argument: ["id": id, "ok": false, "error": error, "message": message]) }
    }

    /// A step's `{file, line, col, endLine, endCol}` (1-based) as an editor location.
    static func location(fromPage value: Any?) -> LSPLocation? {
        guard let loc = value as? [String: Any], let file = loc["file"] as? String, file.hasPrefix("/"), file.utf16.count <= 4096,
              let line = (loc["line"] as? NSNumber)?.intValue, line > 0 else { return nil }
        let col = max(((loc["col"] as? NSNumber)?.intValue ?? 1) - 1, 0)
        let endLine = max(((loc["endLine"] as? NSNumber)?.intValue ?? line), line)
        let endCol = max(((loc["endCol"] as? NSNumber)?.intValue ?? (col + 1)) - 1, 0)
        return LSPLocation(
            uri: URL(fileURLWithPath: file),
            range: LSPRange(start: LSPPosition(line: line - 1, character: col), end: LSPPosition(line: endLine - 1, character: endCol))
        )
    }

    /// Opens `location` in the viewer's linked editor (the file in a new editor when it is another).
    private static func open(_ location: LSPLocation, near waveform: FilePreviewPanel) {
        guard let editor = WaveformSourceLink.linkedEditor(for: waveform) else { return }
        editor.navigate(to: location)
    }

    // MARK: Messages

    private static var noEditorMessage: String {
        String(
            localized: "waveformTrace.noEditor",
            defaultValue: "Open a SystemVerilog file of this design in the editor first: driver tracing loads the design slang-server compiles."
        )
    }

    private static func buildingMessage(host: String?) -> String {
        guard let host else {
            return String(
                localized: "waveformTrace.building",
                defaultValue: "Building the design model (slang) on this Mac. The first time takes a few minutes…"
            )
        }
        return String(
            format: String(
                localized: "waveformTrace.buildingRemote",
                defaultValue: "Building the design model (slang) on %@. The first time takes a few minutes…"
            ),
            host
        )
    }

    private static func loadFailedMessage(_ reply: SVModelSidecar.Reply) -> String {
        let messages = (reply["messages"] as? [String] ?? []).prefix(5).joined(separator: "\n")
        let text = String(
            localized: "waveformTrace.loadFailed",
            defaultValue: "slang could not elaborate the design for driver tracing (no top instance)."
        )
        return messages.isEmpty ? text : text + "\n\n" + messages
    }

    /// A sidecar failure for the user; build.sh's exit codes name what is missing.
    static func sidecarMessage(_ error: any Error, host: String?) -> String {
        let place = host ?? String(localized: "waveformTrace.thisMac", defaultValue: "this Mac")
        switch error as? SVModelSidecar.Failure {
        case .setupFailed(let code, let detail)?:
            let summary: String
            switch code {
            case 20:
                summary = String(format: String(localized: "waveformTrace.setup.cmake", defaultValue: "Building the design model needs CMake 3.20 or later on %@."), place)
            case 21:
                summary = String(format: String(localized: "waveformTrace.setup.compiler", defaultValue: "Building the design model needs a C++20 compiler (GCC 11 or later, or Clang 16 or later) on %@."), place)
            case 22:
                summary = String(format: String(localized: "waveformTrace.setup.python", defaultValue: "Building the design model needs Python 3 on %@."), place)
            case 23, 24:
                summary = String(format: String(localized: "waveformTrace.setup.download", defaultValue: "Downloading slang for the design model failed on %@. Check its internet access."), place)
            default:
                summary = String(format: String(localized: "waveformTrace.setup.failed", defaultValue: "Building the design model failed on %@."), place)
            }
            return detail.isEmpty ? summary : summary + "\n\n" + detail
        case .connectionFailed(let detail)?:
            let text = String(format: String(localized: "waveformTrace.connectionFailed", defaultValue: "Could not connect to %@ for the design model."), place)
            return detail.isEmpty ? text : text + "\n\n" + detail
        case .timedOut?:
            return String(format: String(localized: "waveformTrace.timedOut", defaultValue: "The design model on %@ did not answer in time."), place)
        case .exited(let detail)?:
            let text = String(format: String(localized: "waveformTrace.exited", defaultValue: "The design model on %@ stopped. Try again."), place)
            return detail.isEmpty ? text : text + "\n\n" + detail
        case .request(_, let message)?:
            return message
        case .protocolError?, .stopped?, nil:
            waveformTraceLogger.error("sv-model: \(String(describing: error), privacy: .public)")
            return String(localized: "waveformTrace.failed", defaultValue: "Driver tracing failed.")
        }
    }

    /// Strings of the page's trace panel (cmux-trace-ui.js).
    static func pageStrings() -> [String: String] {
        var strings: [String: String] = [
            "traceTitle": String(localized: "waveformTrace.page.title", defaultValue: "Trace Driver"),
            "traceDriverMenu": String(localized: "waveformTrace.page.menu", defaultValue: "Trace Driver at Marker"),
            "traceDriverKey": KeyboardShortcutSettings.shortcut(for: .traceWaveformDriver).displayString,
            "traceXRootMenu": String(localized: "shortcut.traceWaveformXRoot.label", defaultValue: "Trace X to Root"),
            "traceXRootKey": KeyboardShortcutSettings.shortcut(for: .traceWaveformXRoot).displayString,
            "traceXTitle": String(localized: "waveformTrace.page.x.title", defaultValue: "X chain from %1$@ at %2$@"),
            "traceXRunning": String(localized: "waveformTrace.page.x.running", defaultValue: "Following the x back… (%@ steps)"),
            "traceXCancel": String(localized: "waveformTrace.page.x.cancel", defaultValue: "Cancel"),
            "traceXAdd": String(localized: "waveformTrace.page.x.add", defaultValue: "Add Chain Signals to Waveform"),
            "traceXRootBadge": String(localized: "waveformTrace.page.x.rootBadge", defaultValue: "root"),
            "traceXWhy_start": String(localized: "waveformTrace.page.x.why.start", defaultValue: "the value traced"),
            "traceXWhy_only": String(localized: "waveformTrace.page.x.why.only", defaultValue: "the only input with x or z"),
            "traceXWhy_earliest": String(localized: "waveformTrace.page.x.why.earliest", defaultValue: "the earliest x or z of %@ inputs"),
            "traceXEnd_noXInput": String(localized: "waveformTrace.page.x.end.noXInput", defaultValue: "Root: this statement makes the x (no input has x or z)."),
            "traceXEnd_uninit": String(localized: "waveformTrace.page.x.end.uninit", defaultValue: "Root: never written since the start (uninitialised storage or a declaration)."),
            "traceXEnd_testbench": String(localized: "waveformTrace.page.x.end.testbench", defaultValue: "Root: the testbench sets the value."),
            "traceXEnd_input": String(localized: "waveformTrace.page.x.end.input", defaultValue: "Root: an input of the top level."),
            "traceXEnd_force": String(localized: "waveformTrace.page.x.end.force", defaultValue: "Root: a force or deposit from outside the instance."),
            "traceXEnd_loop": String(localized: "waveformTrace.page.x.end.loop", defaultValue: "Stopped: the x goes round a loop through %@."),
            "traceXEnd_budget": String(localized: "waveformTrace.page.x.end.budget", defaultValue: "Stopped after %@ steps (the step limit)."),
            "traceXEnd_failed": String(localized: "waveformTrace.page.x.end.failed", defaultValue: "Stopped: a step could not be traced."),
            "traceXEnd_cancelled": String(localized: "waveformTrace.page.x.end.cancelled", defaultValue: "Cancelled."),
            "traceXEnd_noX": String(localized: "waveformTrace.page.x.end.noX", defaultValue: "%@ has no x or z bits at this time."),
            "traceNoSignal": String(localized: "waveformTrace.page.noSignal", defaultValue: "Select a signal in the waveform first."),
            "traceNoMarker": String(localized: "waveformTrace.page.noMarker", defaultValue: "Place the marker at the time to trace first."),
            "traceFailed": String(localized: "waveformTrace.failed", defaultValue: "Driver tracing failed."),
            "traceResolving": String(localized: "waveformTrace.page.resolving", defaultValue: "Finding %@ in the design…"),
            "traceRunning": String(localized: "waveformTrace.page.running", defaultValue: "Tracing %1$@ at %2$@…"),
            "traceStepTitle": String(localized: "waveformTrace.page.stepTitle", defaultValue: "%1$@ = %2$@ at %3$@"),
            "traceBack": String(localized: "waveformTrace.page.back", defaultValue: "Back"),
            "traceForward": String(localized: "waveformTrace.page.forward", defaultValue: "Forward"),
            "traceClose": String(localized: "waveformTrace.page.close", defaultValue: "Close"),
            "traceOpen": String(localized: "waveformTrace.page.open", defaultValue: "Open in the editor"),
            "traceKindAssign": String(localized: "waveformTrace.page.kind.assign", defaultValue: "Continuous assignment"),
            "traceKindProc": String(localized: "waveformTrace.page.kind.proc", defaultValue: "%@ block"),
            "traceKindPortIn": String(localized: "waveformTrace.page.kind.portIn", defaultValue: "Input port %1$@ of %2$@"),
            "traceKindPortOut": String(localized: "waveformTrace.page.kind.portOut", defaultValue: "Output port %1$@ of %2$@"),
            "traceKindInitial": String(localized: "waveformTrace.page.kind.initial", defaultValue: "Testbench stimulus"),
            "traceKindTopInput": String(localized: "waveformTrace.page.kind.topInput", defaultValue: "Input of the top level"),
            "traceKindUndriven": String(localized: "waveformTrace.page.kind.undriven", defaultValue: "Nothing drives this signal"),
            "traceKindInitializer": String(localized: "waveformTrace.page.kind.initializer", defaultValue: "Declaration initializer"),
            "traceKindNone": String(localized: "waveformTrace.page.kind.none", defaultValue: "No driver found"),
            "traceActivation": String(localized: "waveformTrace.page.activation", defaultValue: "%1$@ at %2$@, inputs sampled at %3$@"),
            "traceSince": String(localized: "waveformTrace.page.since", defaultValue: "value since %@"),
            "traceTakenThen": String(localized: "waveformTrace.page.taken.then", defaultValue: "then"),
            "traceTakenElse": String(localized: "waveformTrace.page.taken.else", defaultValue: "else"),
            "traceTakenDefault": String(localized: "waveformTrace.page.taken.default", defaultValue: "default"),
            "traceTakenItem": String(localized: "waveformTrace.page.taken.item", defaultValue: "item %@"),
            "traceTakenMerge": String(localized: "waveformTrace.page.taken.merge", defaultValue: "both branches merged (X-propagation)"),
            "traceXCondition": String(localized: "waveformTrace.page.xCondition", defaultValue: "The condition is x or z."),
            "traceFanin": String(localized: "waveformTrace.page.fanin", defaultValue: "Fan-in (click to trace)"),
            "traceLocal": String(localized: "waveformTrace.page.local", defaultValue: "%@ (local)"),
            "traceVia": String(localized: "waveformTrace.page.via", defaultValue: "Written by %@"),
            "traceRootTestbench": String(localized: "waveformTrace.page.rootTestbench", defaultValue: "The value comes from the testbench."),
            "traceRole_data": String(localized: "waveformTrace.page.role.data", defaultValue: "data"),
            "traceRole_control": String(localized: "waveformTrace.page.role.control", defaultValue: "condition"),
            "traceRole_index": String(localized: "waveformTrace.page.role.index", defaultValue: "index"),
            "traceRole_clock": String(localized: "waveformTrace.page.role.clock", defaultValue: "clock"),
            "traceTrust_exact": String(localized: "waveformTrace.page.trust.exact", defaultValue: "exact"),
            "traceTrust_computed": String(localized: "waveformTrace.page.trust.computed", defaultValue: "computed"),
            "traceTrust_approximate": String(localized: "waveformTrace.page.trust.approximate", defaultValue: "approximate"),
            "traceTrust_inconsistent": String(localized: "waveformTrace.page.trust.inconsistent", defaultValue: "inconsistent"),
            "traceTrustHelp_exact": String(localized: "waveformTrace.page.trustHelp.exact", defaultValue: "Re-executing the statement gives the dumped value."),
            "traceTrustHelp_computed": String(localized: "waveformTrace.page.trustHelp.computed", defaultValue: "Re-executed with values the dump lacks (locals, blocking temporaries) computed."),
            "traceTrustHelp_approximate": String(localized: "waveformTrace.page.trustHelp.approximate", defaultValue: "The result rests on assumptions listed below."),
            "traceTrustHelp_inconsistent": String(localized: "waveformTrace.page.trustHelp.inconsistent", defaultValue: "Re-executing the statement does not give the dumped value."),
            "traceError_notInDesign": String(localized: "waveformTrace.page.error.notInDesign", defaultValue: "This signal is not in the design model."),
            "traceError_notASignal": String(localized: "waveformTrace.page.error.notASignal", defaultValue: "This is not a signal of its instance."),
            "traceWriter": String(localized: "waveformTrace.page.writer", defaultValue: "in %@, through its interface port"),
            "traceEngineCmux": String(localized: "waveformTrace.page.engine.cmux", defaultValue: "Traced by cmux (slang design model)"),
            "traceEngineVerdi": String(localized: "waveformTrace.page.engine.verdi", defaultValue: "Traced by Verdi, re-executed by cmux"),
            "traceBuildTitle": String(localized: "waveformTrace.page.build.title", defaultValue: "Building the design model on %@"),
            "traceBuildTitleLocal": String(localized: "waveformTrace.page.build.titleLocal", defaultValue: "Building the design model on this Mac"),
            "traceBuildStage_upload": String(localized: "waveformTrace.page.build.stage.upload", defaultValue: "Upload the model’s sources (%@)"),
            "traceBuildStage_fetch": String(localized: "waveformTrace.page.build.stage.fetch", defaultValue: "Download slang and its libraries"),
            "traceBuildStage_configure": String(localized: "waveformTrace.page.build.stage.configure", defaultValue: "Configure (CMake)"),
            "traceBuildStage_compile": String(localized: "waveformTrace.page.build.stage.compile", defaultValue: "Compile"),
            "traceBuildStage_install": String(localized: "waveformTrace.page.build.stage.install", defaultValue: "Install"),
            "traceBuildStage_load": String(localized: "waveformTrace.page.build.stage.load", defaultValue: "Loading the design"),
            "traceBuildElapsed": String(localized: "waveformTrace.page.build.elapsed", defaultValue: "%@ so far"),
            "traceBuildOnce": String(localized: "waveformTrace.page.build.once", defaultValue: "Built once per host and cmux version."),
            "traceBuildWhat": String(localized: "waveformTrace.page.build.what", defaultValue: "What is being built?"),
            "traceBuildFailedTitle": String(localized: "waveformTrace.page.build.failedTitle", defaultValue: "The design model could not be built on %@"),
            "traceBuildFailedTitleLocal": String(localized: "waveformTrace.page.build.failedTitleLocal", defaultValue: "The design model could not be built on this Mac"),
            "traceBuildLog": String(localized: "waveformTrace.page.build.log", defaultValue: "Last lines of the build log:"),
            "traceBuildRetry": String(localized: "waveformTrace.page.build.retry", defaultValue: "Retry"),
            "traceVerdiStarting": String(localized: "waveformTrace.page.verdi.starting", defaultValue: "Verdi is starting on the host"),
            "traceVerdiChecking": String(localized: "waveformTrace.page.verdi.checking", defaultValue: "Verdi is checking…"),
            "traceVerdiTimedOut": String(localized: "waveformTrace.page.verdi.timedOut", defaultValue: "Verdi: not checked (timed out)"),
            "traceVerdiLarge": String(localized: "waveformTrace.page.verdi.large", defaultValue: "Verdi: not checked (large signal)"),
            "traceVerdiNotFound": String(localized: "waveformTrace.page.verdi.notFound", defaultValue: "Verdi does not know this signal"),
            "traceVerdiLastChange": String(localized: "waveformTrace.page.verdi.lastChange", defaultValue: "Verdi (driver of the last change):"),
            "traceThroughPorts": String(localized: "waveformTrace.page.throughPorts", defaultValue: "through the ports of %@"),
            "traceVerdiUnavailable": String(localized: "waveformTrace.page.verdi.unavailable", defaultValue: "Verdi not used: %@"),
            "traceVerdiUnavailable_noKDB": String(localized: "waveformTrace.page.verdi.noKDB", defaultValue: "Verdi not used: no KDB next to the FSDB (compile with vcs -kdb)"),
            "traceVerdiUnavailable_noVerdi": String(localized: "waveformTrace.page.verdi.noVerdi", defaultValue: "Verdi not used: it is not installed on the host"),
            "traceVerdiUnavailable_licence": String(localized: "waveformTrace.page.verdi.licence", defaultValue: "Verdi not used: no licence seat is free (%@)"),
            "traceVerdiUnavailable_licenceQueue": String(localized: "waveformTrace.page.verdi.licenceQueue", defaultValue: "Verdi not used: Verdi licence not available"),
            "traceVerdiUnavailable_units": String(localized: "waveformTrace.page.verdi.units", defaultValue: "Verdi not used: its time unit is not the FSDB’s (%@)"),
        ]
        strings.merge(reasonStrings()) { first, _ in first }
        return strings
    }

    /// Why a step is approximate or inconsistent (reason codes of cmux-trace.js). `%1$@` is the
    /// reason's subject (a path, statement or time), `%2$@` a predicted value.
    private static func reasonStrings() -> [String: String] {
        [
            "traceReason_opaque": String(localized: "waveformTrace.reason.opaque", defaultValue: "Part of the statement is not modelled: %@"),
            "traceReason_limits": String(localized: "waveformTrace.reason.limits", defaultValue: "A limit was reached (an expression too large to evaluate, or more than 16 blocking temporaries on the way to the fan-in): the result may be incomplete."),
            "traceReason_evaluator": String(localized: "waveformTrace.reason.evaluator", defaultValue: "An expression could not be evaluated: %@"),
            "traceReason_statement": String(localized: "waveformTrace.reason.statement", defaultValue: "A statement kind is not re-executed: %@"),
            "traceReason_delay": String(localized: "waveformTrace.reason.delay", defaultValue: "The block has delays; timing is approximate."),
            "traceReason_lvalue": String(localized: "waveformTrace.reason.lvalue", defaultValue: "The assignment target is not modelled: %@"),
            "traceReason_budget": String(localized: "waveformTrace.reason.budget", defaultValue: "The re-execution stopped at its step limit."),
            "traceReason_notDumped": String(localized: "waveformTrace.reason.notDumped", defaultValue: "Not in the dump: %@"),
            "traceReason_testbench": String(localized: "waveformTrace.reason.testbench", defaultValue: "Driven by testbench code, which is not re-executed."),
            "traceReason_force": String(localized: "waveformTrace.reason.force", defaultValue: "Another instance writes this signal too (a testbench force or $deposit, or a hierarchical write), and its own drivers can't explain the value: that write is shown. It is not re-executed."),
            "traceReason_xprop": String(localized: "waveformTrace.reason.xprop", defaultValue: "The simulator propagated x through a condition (X-propagation)."),
            "traceReason_race": String(localized: "waveformTrace.reason.race", defaultValue: "Inputs changed at the activation time; the order is assumed."),
            "traceReason_targetNotDumped": String(localized: "waveformTrace.reason.targetNotDumped", defaultValue: "The signal is not dumped; its value is computed."),
            "traceReason_noActivation": String(localized: "waveformTrace.reason.noActivation", defaultValue: "No activation of the block was found before %@."),
            "traceReason_sinceUnknown": String(localized: "waveformTrace.reason.sinceUnknown", defaultValue: "When the value last changed is unknown (the signal is too large for the waveform reader): a clocked step uses the last clock edge, a combinational or latch step the values at the time asked."),
            "traceReason_initialValue": String(localized: "waveformTrace.reason.initialValue", defaultValue: "The value is the signal’s initial value."),
            "traceReason_noEdge": String(localized: "waveformTrace.reason.noEdge", defaultValue: "No clock edge before %@."),
            "traceReason_noWrite": String(localized: "waveformTrace.reason.noWrite", defaultValue: "The taken branch does not write the signal: it keeps its value."),
            "traceReason_multiDriven": String(localized: "waveformTrace.reason.multiDriven", defaultValue: "Several drivers; the one that agrees with the dump is shown."),
            "traceReason_mismatch": String(localized: "waveformTrace.reason.mismatch", defaultValue: "Re-execution gives %2$@, not the dumped value."),
            "traceReason_held": String(localized: "waveformTrace.reason.held", defaultValue: "The latch holds the value it had at %@."),
            "traceReason_enginesDiffer": String(localized: "waveformTrace.reason.enginesDiffer", defaultValue: "Verdi names another statement: %@."),
        ]
    }
}
