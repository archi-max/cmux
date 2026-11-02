import AppKit
import CmuxSyntaxHighlighting
import os

nonisolated private let waveformEnumLogger = Logger(subsystem: "com.cmuxterm.app", category: "WaveformEnumLink")

/// SystemVerilog enum member names for waveform values, from the design's source: slang-server
/// knows each signal's declared type (`SlangEnumTypes.swift`), the dump usually doesn't.
/// - The SV editor's inline values read an enum signal's raw bits and show the member's name
///   (`inlineValues`), and the hover gives the raw value too.
/// - The viewer page asks for the types of the rows it shows (`typesRequested`), and gets each
///   enum type as a value alias table it makes the rows' default format (cmux-enum.js).
/// When types are used, read again, kept or dropped is `SlangEnumScopeState`'s decision, one
/// per language server session; this type runs its timers and reads.
@MainActor
enum WaveformEnumLink {
    /// Per language server session: the typedefs and declarations already read, and the scopes.
    private final class SessionTypes {
        weak var session: LanguageServerSession?
        let cache = SlangEnumTypeCache()
        var state = SlangEnumScopeState()
        /// Reads in flight, per design instance.
        var reads: [String: (read: SlangEnumScopeState.Read, task: Task<[String: SlangEnumSignal], Never>)] = [:]
        /// The debounced "types may have changed".
        var staleTimer: Task<Void, Never>?
        init(_ session: LanguageServerSession) { self.session = session }
    }

    private static var sessions: [ObjectIdentifier: SessionTypes] = [:]
    /// Enum signals per waveform and dump instance, as the editor's last refresh found them:
    /// every caller of `inlineValues` for that instance formats alike.
    private static var inlineEnums: [ObjectIdentifier: [String: [String: SlangEnumSignal]]] = [:]
    /// Most rows asked about per page message.
    private static let maxPaths = 200

    private static func types(for session: LanguageServerSession) -> SessionTypes {
        sessions = sessions.filter { $0.value.session != nil }
        let key = ObjectIdentifier(session)
        if let entry = sessions[key], entry.session === session { return entry }
        let entry = SessionTypes(session)
        sessions[key] = entry
        return entry
    }

    /// slang reported diagnostics on a document of `session`: after a save, that is its compile
    /// of the saved files, so the types are read again, whatever the edit was. Unsaved edits
    /// don't read them again: slang-server gives no types until they're saved
    /// (`SlangEnumScopeError.unsavedEdits`), and the dump comes from saved sources too.
    static func serverReported(_ session: LanguageServerSession) {
        guard let delay = types(for: session).state.serverReported() else { return }
        scheduleStale(session, after: delay)
    }

    /// A document of `session` was saved: the types are read again once slang has compiled it
    /// (`serverReported`), or after a delay if it doesn't report.
    static func documentSaved(_ session: LanguageServerSession) {
        let delay = types(for: session).state.saved(at: Date())
        scheduleStale(session, after: delay)
    }

    /// The clean buffer of an editor was reloaded from its file, changed by something else (an
    /// agent, git, another editor). The buffer is the saved text, so it's sent and handled as a
    /// save: otherwise slang refuses every read of the file, and the types from before the change
    /// would stay (verify X1).
    static func documentReloadedFromDisk(_ session: LanguageServerSession, uri: URL, text: String, version: Int) async {
        await session.reloadedFromDisk(uri: uri, text: text, version: version)
        documentSaved(session)
    }

    /// A waveform is loading its file again, usually a new simulation of changed sources: every
    /// session's types are read again.
    static func waveformReloading() {
        for entry in sessions.values {
            guard let session = entry.session else { continue }
            designChanged(session)
        }
    }

    /// Types are read again after `delay` with no newer reason to (each reason restarts it).
    private static func scheduleStale(_ session: LanguageServerSession, after delay: Duration) {
        let entry = types(for: session)
        entry.staleTimer?.cancel()
        entry.staleTimer = Task { @MainActor [weak session, weak entry] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let session, let entry else { return }
            entry.staleTimer = nil
            await markStale(session)
        }
    }

    /// The design changed (a new top level, a compile): every type is read again, in the background.
    static func designChanged(_ session: LanguageServerSession) {
        let entry = types(for: session)
        entry.staleTimer?.cancel()
        entry.staleTimer = nil
        Task { @MainActor in await markStale(session) }
    }

    private static func markStale(_ session: LanguageServerSession) async {
        let entry = types(for: session)
        await entry.cache.removeAll()
        entry.state.markStale()
        // Reads started before it may hold old types: their answers don't count.
        entry.reads = [:]
        FilePreviewLanguageFeatures.enumTypesMayHaveChanged(session: session)
    }

    /// The waveform closed or opened its file again.
    static func waveformReset(_ waveform: FilePreviewPanel) {
        inlineEnums.removeValue(forKey: ObjectIdentifier(waveform))
    }

    /// The enum-typed signals of design instance `designInstance`, by name ([:] when slang
    /// can't say), waiting for a read when there is none yet or it is stale (the viewer's rows).
    static func enumSignals(designInstance: String, session: LanguageServerSession) async -> [String: SlangEnumSignal] {
        if let signals = types(for: session).state.current(designInstance, now: Date()) { return signals }
        return await read(designInstance: designInstance, session: session).value
    }

    /// The enum signals already read for `designInstance`, without waiting (the editor's inline
    /// values and the debugger's steps). A missing or stale entry is read in the background, and
    /// the editors refresh when it brings something new.
    static func enumSignalsNow(designInstance: String, session: LanguageServerSession) -> [String: SlangEnumSignal] {
        let entry = types(for: session)
        if let signals = entry.state.current(designInstance, now: Date()) { return signals }
        let known = entry.state.known(designInstance)
        let task = read(designInstance: designInstance, session: session)
        Task { @MainActor [weak session] in
            let signals = await task.value
            if signals != known, let session {
                FilePreviewLanguageFeatures.enumTypesMayHaveChanged(session: session)
            }
        }
        return known
    }

    /// One read per scope at a time; `SlangEnumScopeState` decides what its answer leaves.
    private static func read(designInstance: String, session: LanguageServerSession) -> Task<[String: SlangEnumSignal], Never> {
        let entry = types(for: session)
        if let running = entry.reads[designInstance] { return running.task }
        let ticket = entry.state.readStarted(designInstance, at: Date())
        let cache = entry.cache
        let task = Task { @MainActor [weak session, weak entry] () -> [String: SlangEnumSignal] in
            guard let session, let entry else { return [:] }
            let outcome: SlangEnumScopeState.Outcome
            do {
                outcome = .signals(try await session.slangEnumSignals(inScope: designInstance, cache: cache))
            } catch SlangEnumScopeError.unsavedEdits {
                outcome = .refused
            } catch {
                outcome = .failed
            }
            for note in await cache.takeOverBudget() {
                waveformEnumLogger.info("enum type at \(note, privacy: .public) is over the \(SlangEnumValues.defaultMaxMemberHovers) member hover budget of a scope read: its values show without names")
            }
            if entry.reads[designInstance]?.read == ticket { entry.reads[designInstance] = nil }
            if let kept = entry.state.readFinished(ticket, outcome, at: Date()) { return kept }
            // A save or reload came while it ran: its answer may be the old types, so read again.
            return await read(designInstance: designInstance, session: session).value
        }
        entry.reads[designInstance] = (ticket, task)
        return task
    }

    // MARK: Editor

    static func setInlineEnums(_ signals: [String: SlangEnumSignal], dumpInstance: String, waveform: FilePreviewPanel) {
        inlineEnums[ObjectIdentifier(waveform), default: [:]][dumpInstance] = signals
    }

    static func inlineEnums(dumpInstance: String, waveform: FilePreviewPanel) -> [String: SlangEnumSignal] {
        inlineEnums[ObjectIdentifier(waveform)]?[dumpInstance] ?? [:]
    }

    /// An inline value: as shown, and (an enum) the raw value it names.
    struct Value: Equatable {
        var shown: String
        var raw: String?
    }

    /// A value from the page's `valuesAt`: as its row shows it, or the bits for cmux to name.
    enum PageValue: Equatable {
        case text(String)
        case bits(String)
    }

    /// `values` read with `raw` set for the enum names: each enum's bits as its member's name;
    /// text (a row the user set to another format) as it is.
    static func named(_ values: [PageValue?], names: [String], enums: [String: SlangEnumSignal]) -> [Value?] {
        zip(names, values).map { name, value -> Value? in
            guard let value else { return nil }
            guard case .bits(let value) = value else {
                if case .text(let text) = value { return Value(shown: text, raw: nil) }
                return nil
            }
            guard let signal = enums[name], !signal.isArray else { return Value(shown: value, raw: nil) }
            let bits = value.lowercased()
            guard !bits.isEmpty, bits.allSatisfy({ "01xzuwlh-".contains($0) }) else { return Value(shown: value, raw: nil) }
            let fitted = SlangEnumValues.fitted(bits, width: signal.type.width)
            return Value(shown: signal.type.display(bits).text, raw: SlangEnumValues.hexLiteral(fitted))
        }
    }

    // MARK: Viewer rows

    /// The page shows rows whose types it doesn't know yet: tells it which are enums.
    static func typesRequested(_ value: Any?, waveform: FilePreviewPanel) {
        guard let list = value as? [Any] else { return }
        let paths = list.prefix(maxPaths).compactMap { WaveformSourceLink.dumpPath(fromPage: $0) }
        guard !paths.isEmpty else { return }
        Task { @MainActor in
            guard let lookup = await WaveformSourceLink.designLookup(for: waveform) else { return }
            // Rows by the dump scope they are in; one slang scope read per scope.
            let byScope = Set(paths.filter { $0.count >= 2 }.map { Array($0.dropLast()) })
                .sorted { $0.joined(separator: ".") < $1.joined(separator: ".") }
            var tables: [String: SlangEnumType] = [:]
            var signals: [String: String] = [:]
            for dumpScope in byScope {
                let designScope = lookup.mapping.designPath(forDumpPath: HierarchyPathMapping.join(dumpScope))
                let found = await enumSignals(designInstance: designScope, session: lookup.session)
                guard !Task.isCancelled else { return }
                // Every enum signal of the scope: rows added later get their table in their own add.
                for (name, signal) in found where !signal.isArray {
                    let id = tableId(signal.type)
                    tables[id] = signal.type
                    signals[HierarchyPathMapping.join(dumpScope + [name])] = id
                }
            }
            guard !tables.isEmpty else { return }
            let answer: [String: Any] = [
                "tables": tables.sorted { $0.key < $1.key }.map { id, type in
                    [
                        "id": id,
                        "label": SlangEnumValues.tableLabel(type),
                        "width": type.width,
                        "members": type.members.map { [$0.name, $0.bits] },
                    ] as [String: Any]
                },
                "signals": signals,
            ]
            _ = await waveform.nativeViewSessions.waveform.callEnums("define", argument: answer)
        }
    }

    /// One table per distinct type: its name, width and members (stable across launches).
    static func tableId(_ type: SlangEnumType) -> String {
        SlangEnumValues.tableId(type)
    }

    // MARK: Declared dimensions

    /// Split > By Declared Dimensions on a row: the page asks for the packed dimensions of one
    /// dump path (`{ type: 'packedDims', id, path }`) and gets them, or null when slang can't
    /// say (no linked design, a struct element, one dimension), through
    /// `window.cmuxWaveform.split.declared({ id, dims: [[left, right], ...] })` (cmux-commands.js).
    static func packedDimensionsRequested(_ body: [String: Any], waveform: FilePreviewPanel) {
        let id = body["id"] as? NSNumber
        let path = WaveformSourceLink.dumpPath(fromPage: body["path"])
        Task { @MainActor in
            var dims: [[Int]]?
            if let path, path.count >= 2, let lookup = await WaveformSourceLink.designLookup(for: waveform) {
                let designScope = lookup.mapping.designPath(forDumpPath: HierarchyPathMapping.join(Array(path.dropLast())))
                let found = try? await lookup.session.slangPackedSignals(inScope: designScope)
                dims = found?[path[path.count - 1]]?.map { [$0.left, $0.right] }
            }
            let answer: [String: Any] = ["id": id ?? NSNull(), "dims": dims.map { $0 as Any } ?? NSNull()]
            _ = await waveform.nativeViewSessions.waveform.callSplit("declared", argument: answer)
        }
    }
}
