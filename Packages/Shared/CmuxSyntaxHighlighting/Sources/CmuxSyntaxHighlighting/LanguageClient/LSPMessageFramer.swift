import Foundation

/// Incremental decoder for `Content-Length` framed JSON-RPC messages.
///
/// Feed it raw bytes as they arrive; it buffers partial input and returns
/// every complete message body, so split and coalesced reads both work.
struct LSPMessageFramer: Sendable {
    private var buffer: [UInt8] = []
    private static let headerTerminator: [UInt8] = Array("\r\n\r\n".utf8)

    /// Appends `data` and returns the bodies of all messages now complete.
    mutating func append(_ data: Data) -> [Data] {
        buffer.append(contentsOf: data)
        var messages: [Data] = []
        var consumed = 0
        while let headerEnd = Self.find(Self.headerTerminator, in: buffer, from: consumed) {
            let headerBytes = buffer[consumed..<headerEnd]
            let bodyStart = headerEnd + Self.headerTerminator.count
            guard let length = Self.contentLength(in: headerBytes) else {
                // Malformed header: drop it and resynchronize on the next one.
                consumed = bodyStart
                continue
            }
            guard buffer.count - bodyStart >= length else { break }
            messages.append(Data(buffer[bodyStart..<(bodyStart + length)]))
            consumed = bodyStart + length
        }
        if consumed > 0 {
            buffer.removeFirst(consumed)
        }
        return messages
    }

    /// Encodes `body` with a `Content-Length` header.
    static func frame(_ body: Data) -> Data {
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        return data
    }

    private static func contentLength(in header: ArraySlice<UInt8>) -> Int? {
        let text = String(decoding: header, as: UTF8.self)
        for line in text.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
            else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard haystack.count >= needle.count, start <= haystack.count - needle.count else { return nil }
        var index = start
        while index <= haystack.count - needle.count {
            if haystack[index] == needle[0], haystack[index..<(index + needle.count)].elementsEqual(needle) {
                return index
            }
            index += 1
        }
        return nil
    }
}
