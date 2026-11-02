// Expression checks (run.sh expr): Resources/vaporview/cmux-expr.js, the waveform debugger's
// SystemVerilog expression evaluator (Evaluate, watches, condition breakpoints), in a bare
// JavaScriptCore context: the grammar, precedence, 4-state values, widths, selects, errors, caps.
// Usage: expr <cmux-expr.js> <cases.js> [fuzz-regressions.js]
import Foundation
import JavaScriptCore

let args = CommandLine.arguments
guard args.count == 3 || args.count == 4, let context = JSContext() else { print("usage: expr <cmux-expr.js> <cases.js> [fuzz-regressions.js]"); exit(2) }
var thrown: String?
context.exceptionHandler = { _, error in thrown = error?.toString() }
for path in args[1...] {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { print("cannot read", path); exit(2) }
    context.evaluateScript(source, withSourceURL: URL(fileURLWithPath: path))
    if let error = thrown { print("FAIL loading", path, error); print("EXPR CHECKS FAILED: 1"); exit(1) }
}
let lines = context.evaluateScript("runExprCases()")?.toArray() as? [String] ?? ["FAIL no results"]
if let error = thrown { print("FAIL", error) }
lines.forEach { print($0) }
let failures = lines.filter { $0.hasPrefix("FAIL") }.count + (thrown == nil ? 0 : 1)
print(failures == 0 ? "EXPR CHECKS PASSED" : "EXPR CHECKS FAILED: \(failures)")
exit(failures == 0 ? 0 : 1)
