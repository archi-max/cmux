// Machine-state core checks (run.sh machine-core): Resources/vaporview/cmux-machine-core.js (commit
// stream detection, the commit table, the state index's replay rules, gdb commands) and the `$` names
// of cmux-expr.js, in a bare JavaScriptCore context. The synthetic generator (make-rvfi-vcd.js) gives
// its own expected state; the fixture cores (fixtures/<core>) are checked against Spike's replay of
// the same ELF (spike.log). Usage: machine-core <fixtures dir> <script.js>...
import Foundation
import JavaScriptCore

let args = CommandLine.arguments
guard args.count >= 3, let context = JSContext() else { print("usage: machine-core <fixtures dir> <script.js>..."); exit(2) }
var thrown: String?
context.exceptionHandler = { _, error in
  let stack = error?.objectForKeyedSubscript("stack")?.toString() ?? ""
  thrown = (error?.toString() ?? "?") + " " + stack
}
let readFile: @convention(block) (String) -> String? = { path in try? String(contentsOfFile: path, encoding: .utf8) }
let readBytes: @convention(block) (String) -> [UInt8]? = { path in (try? Data(contentsOf: URL(fileURLWithPath: path))).map { Array($0) } }
let now: @convention(block) () -> Double = { Date().timeIntervalSince1970 * 1000 }
context.setObject(readFile, forKeyedSubscript: "readFile" as NSString)
context.setObject(readBytes, forKeyedSubscript: "readBytes" as NSString)
context.setObject(now, forKeyedSubscript: "nowMs" as NSString)
// The page's scripts publish on `window`.
context.evaluateScript("var window = this;")
for path in args[2...] {
  guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { print("cannot read", path); exit(2) }
  context.evaluateScript(source, withSourceURL: URL(fileURLWithPath: path))
  if let error = thrown { print("FAIL loading", path, error); print("MACHINE CORE CHECKS FAILED: 1"); exit(1) }
}
let only = ProcessInfo.processInfo.environment["MACHINE_ONLY"] ?? ""
let lines = context.evaluateScript("runMachineCases(\(String(reflecting: args[1])), \(String(reflecting: only)))")?.toArray() as? [String] ?? ["FAIL no results"]
if let error = thrown { print("FAIL", error) }
lines.forEach { print($0) }
let failures = lines.filter { $0.hasPrefix("FAIL") }.count + (thrown == nil ? 0 : 1)
let passes = lines.filter { $0.hasPrefix("ok") }.count
print(failures == 0 ? "MACHINE CORE CHECKS PASSED (\(passes))" : "MACHINE CORE CHECKS FAILED: \(failures) of \(passes + failures)")
exit(failures == 0 ? 0 : 1)
