// Commit-breakpoint checks (run.sh commit-breakpoints): Resources/vaporview/cmux-debugger-commits.js
// (with the text-breakpoint judging it shares) in a bare JavaScriptCore context, against a mock of
// cmux-machine.js's commit index (window.cmuxWaveform.commits): PC, instruction-text and write hits,
// channels, x pcs, several commits in one cycle, program order vs time order, the caches, the
// address and location syntax, and what is said when there is no commit stream.
// Usage: commit-breakpoints <page script>... <cases.js> (cmux-formats.js, cmux-textmatch.js, cmux-debugger-text.js,
// cmux-debugger-commits.js, and for sequence breakpoints cmux-expr.js and cmux-sequence.js)
import Foundation
import JavaScriptCore

let args = CommandLine.arguments
guard args.count >= 3, let context = JSContext() else { print("usage: commit-breakpoints <scripts>... <cases.js>"); exit(2) }
var thrown: String?
context.exceptionHandler = { _, error in thrown = error?.toString() }
// The page globals the modules read; no Worker here, so judging runs on this thread.
context.evaluateScript("var self = this; var window = this; window.cmuxWaveform = { strings: {} };")
for path in args[1...] {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { print("cannot read", path); exit(2) }
    context.evaluateScript(source, withSourceURL: URL(fileURLWithPath: path))
    if let error = thrown { print("FAIL loading", path, error); print("COMMIT BREAKPOINT CHECKS FAILED: 1"); exit(1) }
}
// Promise jobs run before evaluateScript returns.
context.evaluateScript("var __out = null; runCommitCases().then((r) => { __out = r; }, (e) => { __out = ['FAIL threw ' + e + ' ' + (e && e.stack)]; });")
let lines = context.evaluateScript("__out")?.toArray() as? [String] ?? ["FAIL the cases did not finish"]
if let error = thrown { print("FAIL", error) }
lines.forEach { print($0) }
let failures = lines.filter { $0.hasPrefix("FAIL") }.count + (thrown == nil ? 0 : 1)
let passes = lines.filter { $0.hasPrefix("ok") }.count
print(failures == 0 ? "COMMIT BREAKPOINT CHECKS PASSED (\(passes) ok)" : "COMMIT BREAKPOINT CHECKS FAILED: \(failures)")
exit(failures == 0 ? 0 : 1)
