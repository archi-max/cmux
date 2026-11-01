import AppKit
import CmuxSyntaxHighlighting

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
    /// Enum signals per (session, design instance), with when they were read.
    private static var scopes: [String: (signals: [String: SlangEnumSignal], at: Date)] = [:]
    /// A scope read with no enum in it (or before the design compiled) is asked again after this.
    private static let emptyScopeLifetime: TimeInterval = 10
    /// Enum signals per waveform and dump instance, as the editor's last refresh found them:
    /// every caller of `inlineValues` for that instance formats alike.
    private static var inlineEnums: [ObjectIdentifier: [String: [String: SlangEnumSignal]]] = [:]
    /// Table labels given out per waveform: a label names one table only.
    private static var labels: [ObjectIdentifier: [String: String]] = [:]
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

    /// The design changed (an edit, a new top level): types are read again.
    static func invalidate(_ session: LanguageServerSession) {
        let prefix = "\(ObjectIdentifier(session).hashValue)|"
        scopes = scopes.filter { !$0.key.hasPrefix(prefix) }
        if let entry = caches[ObjectIdentifier(session)] {
            Task { await entry.cache.removeAll() }
        }
    }

    /// The waveform closed or opened its file again.
    static func waveformReset(_ waveform: FilePreviewPanel) {
        inlineEnums.removeValue(forKey: ObjectIdentifier(waveform))
        labels.removeValue(forKey: ObjectIdentifier(waveform))
    }

    /// The enum-typed signals of design instance `designInstance`, by name ([:] when slang
    /// can't say).
    static func enumSignals(designInstance: String, session: LanguageServerSession) async -> [String: SlangEnumSignal] {
        let key = "\(ObjectIdentifier(session).hashValue)|\(designInstance)"
        if let entry = scopes[key], !entry.signals.isEmpty || Date().timeIntervalSince(entry.at) < emptyScopeLifetime {
            return entry.signals
        }
        let signals = (try? await session.slangEnumSignals(inScope: designInstance, cache: cache(for: session))) ?? [:]
        scopes[key] = (signals, Date())
        return signals
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

    /// `values` read with `raw` set for the enum names: each enum's bits as its member's name.
    static func named(_ values: [String?], names: [String], enums: [String: SlangEnumSignal]) -> [Value?] {
        zip(names, values).map { name, value in
            guard let value else { return nil }
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
                        "label": label(for: type, id: id, waveform: waveform),
                        "width": type.width,
                        "members": type.members.map { [$0.name, $0.bits] },
                    ] as [String: Any]
                },
                "signals": signals,
            ]
            _ = await waveform.nativeViewSessions.waveform.callEnums("define", argument: answer)
        }
    }

    /// One table per distinct type: its name, width and members.
    static func tableId(_ type: SlangEnumType) -> String {
        var hasher = Hasher()
        hasher.combine(type.members)
        return "\(type.name)|\(type.width)|\(UInt(bitPattern: hasher.finalize()))"
    }

    /// The name the viewer's Alias menu shows: the type's, with its width when another table
    /// of this waveform has the name already.
    private static func label(for type: SlangEnumType, id: String, waveform: FilePreviewPanel) -> String {
        let key = ObjectIdentifier(waveform)
        var given = labels[key] ?? [:]
        if let existing = given.first(where: { $0.value == id })?.key { return existing }
        var label = type.name
        if given[label] != nil { label = "\(type.name) [\(type.width)]" }
        var suffix = 2
        while given[label] != nil {
            label = "\(type.name) [\(type.width)] \(suffix)"
            suffix += 1
        }
        given[label] = id
        labels[key] = given
        return label
    }
}
