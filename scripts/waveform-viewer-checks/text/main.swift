// Text-breakpoint checks (run.sh text): Resources/vaporview/cmux-textmatch.js (and the formatter
// bundle cmux-formats.js it uses) in a bare JavaScriptCore context: the viewer's texts, the match
// rules, register names, ASCII, the linear-time formatters against the viewer's, and refusals.
// Usage: text <cmux-formats.js> <cmux-textmatch.js> <cases.js>
import Foundation
import JavaScriptCore

let args = CommandLine.arguments
guard args.count == 4, let context = JSContext() else { print("usage: text <cmux-formats.js> <cmux-textmatch.js> <cases.js>"); exit(2) }
var thrown: String?
context.exceptionHandler = { _, error in thrown = error?.toString() }
context.evaluateScript("var self = this;")
for path in args[1...] {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { print("cannot read", path); exit(2) }
    context.evaluateScript(source, withSourceURL: URL(fileURLWithPath: path))
    if let error = thrown { print("FAIL loading", path, error); print("TEXT CHECKS FAILED: 1"); exit(1) }
}
let lines = context.evaluateScript("runTextCases()")?.toArray() as? [String] ?? ["FAIL no results"]
if let error = thrown { print("FAIL", error) }
lines.forEach { print($0) }
let failures = lines.filter { $0.hasPrefix("FAIL") }.count + (thrown == nil ? 0 : 1)
let passes = lines.filter { $0.hasPrefix("ok") }.count
print(failures == 0 ? "TEXT CHECKS PASSED (\(passes) ok)" : "TEXT CHECKS FAILED: \(failures)")
exit(failures == 0 ? 0 : 1)
