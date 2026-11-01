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
@MainActor
enum WaveformEnumLink {
    /// One per language server session: the typedefs and declarations already read.
    private static var caches: [ObjectIdentifier: (session: WeakSession, cache: SlangEnumTypeCache)] = [:]
    /// Enum signals per (session, design instance), with when they were read; `stale` after a
    /// save or a reload: still used until the read again has finished.
    private static var scopes: [String: (signals: [String: SlangEnumSignal], at: Date, stale: Bool)] = [:]
    /// Scopes whose last read slang refused for unsaved edits, and when: asked again after
    /// `emptyScopeLifetime`, or at once after a save.
    private static var refusedAt: [String: Date] = [:]
    /// Reads in flight, per scope key.
    private static var reads: [String: Task<ReadResult, Never>] = [:]

    /// A scope read's answer; `refused` when slang had unsaved edits (the signals are the old ones).
    struct ReadResult {
        var signals: [String: SlangEnumSignal]
        var refused = false
    }
    /// The debounced "types may have changed" per session.
    private static var staleTimers: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// After a save, if slang hasn't reported on it by then.
    private static let staleDelay: Duration = .milliseconds(1500)
    /// After slang's report on a save: only long enough to take its reports on other files together.
    private static let compiledDelay: Duration = .milliseconds(300)
    /// Per session: whether slang's next report is its compile of a save (verify N1).
    private static var freshness: [ObjectIdentifier: SlangEnumTypeFreshness] = [:]
    /// A scope read with no enum in it (or before the design compiled) is asked again after this.
    private static let emptyScopeLifetime: TimeInterval = 10
    /// Enum signals per waveform and dump instance, as the editor's last refresh found them:
    /// every caller of `inlineValues` for that instance formats alike.
    private static var inlineEnums: [ObjectIdentifier: [String: [String: SlangEnumSignal]]] = [:]
    /// Most rows asked about per page message.
    private static let maxPaths = 200

    final class WeakSession {
        weak var session: LanguageServerSession?
        init(_ session: LanguageServerSession) { self.session = session }
    }

    private static func cache(for session: LanguageServerSession) -> SlangEnumTypeCache {
        caches = caches.filter { $0.value.session.session != nil }
        let key = ObjectIdentifier(session)
        if let entry = caches[key], entry.session.session === session { return entry.cache }
        let cache = SlangEnumTypeCache()
        caches[key] = (WeakSession(session), cache)
        return cache
    }

    private static func prefix(_ session: LanguageServerSession) -> String { "\(ObjectIdentifier(session).hashValue)|" }

    /// slang reported diagnostics on a document of `session`: after a save, that is its compile
    /// of the saved files, so the types are read again, whatever the edit was. Unsaved edits
    /// don't read them again: slang-server gives no types until they're saved
    /// (`SlangEnumScopeError.unsavedEdits`), and the dump comes from saved sources too.
    static func serverReported(_ session: LanguageServerSession) {
        guard freshness[ObjectIdentifier(session), default: SlangEnumTypeFreshness()].compiled() else { return }
        scheduleStale(session, after: compiledDelay)
    }

    /// A document of `session` was saved: the types are read again once slang has compiled it
    /// (`serverReported`), or after `staleDelay` if it doesn't report.
    static func documentSaved(_ session: LanguageServerSession) {
        freshness[ObjectIdentifier(session), default: SlangEnumTypeFreshness()].saved()
        scheduleStale(session, after: staleDelay)
    }

    /// A waveform is loading its file again, usually a new simulation of changed sources: every
    /// session's types are read again.
    static func waveformReloading() {
        for entry in caches.values {
            guard let session = entry.session.session else { continue }
            staleTimers.removeValue(forKey: ObjectIdentifier(session))?.cancel()
            Task { @MainActor in await markStale(session) }
        }
    }

    /// Types are read again after `delay` with no newer reason to (each reason restarts it).
    private static func scheduleStale(_ session: LanguageServerSession, after delay: Duration) {
        let key = ObjectIdentifier(session)
        staleTimers[key]?.cancel()
        staleTimers[key] = Task { @MainActor [weak session] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let session else { return }
            staleTimers[key] = nil
            await markStale(session)
        }
    }

    /// The design changed (a new top level, a compile): every type is read again, in the background.
    static func designChanged(_ session: LanguageServerSession) {
        staleTimers.removeValue(forKey: ObjectIdentifier(session))?.cancel()
        Task { @MainActor in await markStale(session) }
    }

    private static func markStale(_ session: LanguageServerSession) async {
        await cache(for: session).removeAll()
        let prefix = prefix(session)
        for (key, entry) in scopes where key.hasPrefix(prefix) {
            scopes[key] = (entry.signals, entry.at, true)
        }
        for key in refusedAt.keys where key.hasPrefix(prefix) { refusedAt[key] = nil }
        // Reads started before the edit may hold old types: their answers are read again.
        for (key, _) in reads where key.hasPrefix(prefix) { reads[key] = nil }
        FilePreviewLanguageFeatures.enumTypesMayHaveChanged(session: session)
    }

    /// The waveform closed or opened its file again.
    static func waveformReset(_ waveform: FilePreviewPanel) {
        inlineEnums.removeValue(forKey: ObjectIdentifier(waveform))
    }

    /// The enum-typed signals of design instance `designInstance`, by name ([:] when slang
    /// can't say), waiting for a read when there is none yet or it is stale (the viewer's rows).
    static func enumSignals(designInstance: String, session: LanguageServerSession) async -> [String: SlangEnumSignal] {
        let key = prefix(session) + designInstance
        if let entry = scopes[key], isCurrent(entry, key: key) { return entry.signals }
        return await read(key: key, designInstance: designInstance, session: session).value.signals
    }

    /// The enum signals already read for `designInstance`, without waiting (the editor's inline
    /// values and the debugger's steps). A missing or stale entry is read in the background, and
    /// the editors refresh when it brings something new.
    static func enumSignalsNow(designInstance: String, session: LanguageServerSession) -> [String: SlangEnumSignal] {
        let key = prefix(session) + designInstance
        let entry = scopes[key]
        if entry.map({ isCurrent($0, key: key) }) != true {
            let task = read(key: key, designInstance: designInstance, session: session)
            Task { @MainActor [weak session] in
                let signals = await task.value.signals
                if signals != entry?.signals ?? [:], let session {
                    FilePreviewLanguageFeatures.enumTypesMayHaveChanged(session: session)
                }
            }
        }
        return entry?.signals ?? [:]
    }

    private static func isCurrent(_ entry: (signals: [String: SlangEnumSignal], at: Date, stale: Bool), key: String) -> Bool {
        if let refused = refusedAt[key], Date().timeIntervalSince(refused) < emptyScopeLifetime { return true }
        return !entry.stale && (!entry.signals.isEmpty || Date().timeIntervalSince(entry.at) < emptyScopeLifetime)
    }

    /// One read per scope at a time; its answer replaces the entry (unless it went stale meanwhile).
    private static func read(key: String, designInstance: String, session: LanguageServerSession) -> Task<ReadResult, Never> {
        if let running = reads[key] { return running }
        let cache = cache(for: session)
        let task = Task { @MainActor [weak session] () -> ReadResult in
            guard let session else { return ReadResult(signals: [:]) }
            var result: ReadResult
            do {
                result = ReadResult(signals: try await session.slangEnumSignals(inScope: designInstance, cache: cache))
            } catch SlangEnumScopeError.unsavedEdits {
                // slang can't say while a buffer has unsaved edits: the types already read stay.
                result = ReadResult(signals: scopes[key]?.signals ?? [:], refused: true)
            } catch {
                result = ReadResult(signals: [:])
            }
            for note in await cache.takeOverBudget() {
                waveformEnumLogger.info("enum type at \(note, privacy: .public) is over the \(SlangEnumValues.defaultMaxMemberHovers) member hover budget of a scope read: its values show without names")
            }
            return result
        }
        reads[key] = task
        Task { @MainActor in
            let result = await task.value
            // Superseded by a save or reload while it ran (markStale dropped it): leave the entry stale.
            guard reads[key] == task else { return }
            reads[key] = nil
            if result.refused {
                // Still stale: read after a save, or retried after `emptyScopeLifetime`.
                refusedAt[key] = Date()
                scopes[key] = (result.signals, scopes[key]?.at ?? Date(), true)
            } else {
                refusedAt[key] = nil
                scopes[key] = (result.signals, Date(), false)
            }
        }
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
}
