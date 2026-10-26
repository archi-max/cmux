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
    public static func format(_ text: String, using launch: LanguageToolLaunch, timeout: TimeInterval = 10) async throws -> String {
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
