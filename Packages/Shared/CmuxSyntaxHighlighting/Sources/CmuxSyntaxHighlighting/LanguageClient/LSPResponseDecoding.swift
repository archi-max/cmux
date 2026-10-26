import Foundation

/// Normalizes the several shapes LSP allows for each response into the
/// public client types.
enum LSPResponseDecoding {
    static func position(_ value: JSONValue?) -> LSPPosition? {
        guard let line = value?["line"]?.intValue, let character = value?["character"]?.intValue else {
            return nil
        }
        return LSPPosition(line: line, character: character)
    }

    static func range(_ value: JSONValue?) -> LSPRange? {
        guard let start = position(value?["start"]), let end = position(value?["end"]) else { return nil }
        return LSPRange(start: start, end: end)
    }

    /// Hover `contents` may be MarkupContent, a MarkedString, or an array of MarkedStrings.
    static func hoverText(_ result: JSONValue) -> String? {
        guard let contents = result["contents"] else { return nil }
        let text = markedText(contents).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func markedText(_ value: JSONValue) -> String {
        switch value {
        case .string(let text):
            return text
        case .array(let items):
            return items.map(markedText).filter { !$0.isEmpty }.joined(separator: "\n\n")
        case .object:
            let text = value["value"]?.stringValue ?? ""
            if let language = value["language"]?.stringValue {
                return "```\(language)\n\(text)\n```"
            }
            return text
        default:
            return ""
        }
    }

    /// Definition results may be null, a Location, Location[], or LocationLink[].
    static func locations(_ result: JSONValue, uriMapper: (String) -> URL?) -> [LSPLocation] {
        let items: [JSONValue]
        switch result {
        case .array(let array): items = array
        case .object: items = [result]
        default: return []
        }
        return items.compactMap { item in
            if let uri = item["uri"]?.stringValue, let range = range(item["range"]) {
                return uriMapper(uri).map { LSPLocation(uri: $0, range: range) }
            }
            if let uri = item["targetUri"]?.stringValue,
               let range = range(item["targetSelectionRange"]) ?? range(item["targetRange"]) {
                return uriMapper(uri).map { LSPLocation(uri: $0, range: range) }
            }
            return nil
        }
    }

    /// Completion results may be null, CompletionItem[], or a CompletionList.
    static func completionItems(_ result: JSONValue) -> [LSPCompletionItem] {
        let items = result.arrayValue ?? result["items"]?.arrayValue ?? []
        return items.compactMap { item in
            guard let label = item["label"]?.stringValue else { return nil }
            let detail = item["detail"]?.stringValue
                ?? item["labelDetails"]?["detail"]?.stringValue.map { $0.trimmingCharacters(in: .whitespaces) }
            let insertText = item["insertText"]?.stringValue ?? item["textEdit"]?["newText"]?.stringValue
            return LSPCompletionItem(label: label, detail: detail, insertText: insertText, kind: item["kind"]?.intValue)
        }
    }

    static func diagnostics(_ value: JSONValue?) -> [LSPDiagnostic] {
        (value?.arrayValue ?? []).compactMap { item in
            guard let range = range(item["range"]), let message = item["message"]?.stringValue else { return nil }
            let severity = item["severity"]?.intValue.flatMap(LSPDiagnosticSeverity.init(rawValue:)) ?? .error
            let code: String?
            switch item["code"] {
            case .string(let value): code = value
            case .int(let value): code = String(value)
            default: code = nil
            }
            return LSPDiagnostic(
                range: range,
                severity: severity,
                message: message,
                code: code,
                source: item["source"]?.stringValue
            )
        }
    }
}
