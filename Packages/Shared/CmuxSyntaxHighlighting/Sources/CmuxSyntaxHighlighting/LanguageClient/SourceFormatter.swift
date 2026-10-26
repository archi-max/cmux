import Foundation

/// Errors thrown by `SourceFormatter`.
public enum SourceFormatterError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The formatter exited with a nonzero status. `stderr` holds its last lines.
    case failed(status: Int32, stderr: String)
    /// The formatter succeeded but wrote nothing.
    case emptyOutput
    /// The formatter did not finish within the timeout and was killed.
    case timedOut

    public var description: String {
        switch self {
        case .failed(let status, let stderr):
            return "Formatter exited with status \(status)" + (stderr.isEmpty ? "" : ": \(stderr)")
        case .emptyOutput:
            return "Formatter produced no output"
        case .timedOut:
            return "Formatter timed out"
        }
    }
}

/// Runs a stdin-to-stdout source formatter such as `verible-verilog-format -`.
public enum SourceFormatter {
    /// Pipes text through the formatter and returns the result. Throws on nonzero exit, empty output, or timeout (default 10 s).
    ///
    /// Launch failures throw `LanguageServerError.launchFailed` (or
    /// `.unsupportedPlatform` on iOS); everything else throws `SourceFormatterError`.
    ///
    /// When Verible rejects the text, it is retried once wrapped in a module,
    /// since `` `include `` fragments such as testbench bodies hold module
    /// items with no `module ... endmodule`. If that also fails, the original
    /// error is thrown, so real syntax errors still surface.
    public static func format(_ text: String, using launch: LanguageToolLaunch, timeout: TimeInterval = 10) async throws -> String {
        do {
            return try await run(text, using: launch, timeout: timeout)
        } catch SourceFormatterError.failed(let status, let stderr) {
            let original = SourceFormatterError.failed(status: status, stderr: stderr)
            guard let indentation = VeribleFragment.indentation(for: launch),
                  let wrapped = try? await run(VeribleFragment.wrap(text), using: launch, timeout: timeout),
                  let unwrapped = VeribleFragment.unwrap(wrapped, indentation: indentation) else {
                throw original
            }
            return unwrapped
        }
    }

    private static func run(_ text: String, using launch: LanguageToolLaunch, timeout: TimeInterval) async throws -> String {
        let tool = try LanguageToolProcess.spawn(launch)
        tool.write(Data(text.utf8))
        tool.closeStdin()

        let result: (status: Int32, output: Data)? = try await withThrowingTaskGroup(
            of: (status: Int32, output: Data)?.self
        ) { group in
            group.addTask {
                var output = Data()
                for await chunk in tool.stdout {
                    output.append(chunk)
                }
                var status: Int32 = -1
                for await value in tool.exit {
                    status = value
                }
                return (status, output)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }

        guard let result else {
            tool.terminate()
            tool.kill()
            throw SourceFormatterError.timedOut
        }
        guard result.status == 0 else {
            throw SourceFormatterError.failed(status: result.status, stderr: tool.stderrTail.text)
        }
        guard !result.output.isEmpty else {
            throw SourceFormatterError.emptyOutput
        }
        return String(decoding: result.output, as: UTF8.self)
    }
}

/// Formats a Verible fragment by wrapping it in a throwaway module.
enum VeribleFragment {
    static let header = "module __cmux_fmt_wrap;"
    static let footer = "endmodule"
    static let defaultIndentation = 2

    /// Spaces per indent level when `launch` runs verible-verilog-format, else nil.
    static func indentation(for launch: LanguageToolLaunch) -> Int? {
        let words: [String]
        switch launch {
        case .local(let executablePath, let arguments), .remote(let executablePath, let arguments):
            // A remote launch carries the tool inside a shell command argument.
            words = ([executablePath] + arguments).flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        case .ssh(_, _, let remoteCommand):
            words = remoteCommand.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        guard words.contains(where: { ($0 as NSString).lastPathComponent == "verible-verilog-format" }) else { return nil }
        for (index, word) in words.enumerated() {
            let value: String
            if word.hasPrefix("--indentation_spaces=") {
                value = String(word.dropFirst("--indentation_spaces=".count))
            } else if word == "--indentation_spaces", index + 1 < words.count {
                value = words[index + 1]
            } else {
                continue
            }
            return Int(value.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))) ?? defaultIndentation
        }
        return defaultIndentation
    }

    static func wrap(_ text: String) -> String {
        header + "\n" + text + "\n" + footer + "\n"
    }

    /// Drops the wrapper lines and one indent level, or nil if the output is not the wrapped module.
    static func unwrap(_ formatted: String, indentation: Int) -> String? {
        var lines = formatted.components(separatedBy: "\n")
        let isBlank = { (line: String) in line.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = lines.firstIndex(where: { !isBlank($0) }),
              let last = lines.lastIndex(where: { !isBlank($0) }),
              first < last,
              lines[first].trimmingCharacters(in: .whitespaces) == header,
              lines[last].trimmingCharacters(in: .whitespaces) == footer else { return nil }
        lines = Array(lines[(first + 1)..<last])
        while let line = lines.last, isBlank(line) {
            lines.removeLast()
        }
        let indent = String(repeating: " ", count: indentation)
        let body = lines.map { line in
            line.hasPrefix(indent) ? String(line.dropFirst(indentation)) : line
        }
        return body.joined(separator: "\n") + "\n"
    }
}
