// Driver-trace checks (run.sh trace): Resources/vaporview/cmux-trace.js, the active-driver engine,
// with cmux-expr.js, in a bare JavaScriptCore context, over checked-in trace models (cmux-sv-model
// output, models/) and dumps (VCS and Icarus VCDs of designs/, dumps/). See cases.js.
// Usage: trace <cmux-expr.js> <cmux-trace.js> <this folder>
import Foundation
import JavaScriptCore

let args = CommandLine.arguments
guard args.count == 4, let context = JSContext() else { print("usage: trace <cmux-expr.js> <cmux-trace.js> <folder>"); exit(2) }
let folder = URL(fileURLWithPath: args[3])
var thrown: String?
context.exceptionHandler = { _, error in thrown = error?.toString() }

func files(in sub: String, ext: String) -> [String: String] {
    let dir = folder.appendingPathComponent(sub)
    var out: [String: String] = [:]
    for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(ext) {
        out[String(name.dropLast(ext.count))] = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }
    return out
}
var designs: [String: String] = [:]
for (name, text) in files(in: "designs", ext: ".sv") { designs[name + ".sv"] = text }
context.setObject(["designs": designs, "models": files(in: "models", ext: ".json"), "dumps": files(in: "dumps", ext: ".vcd"), "loadOracle": files(in: "oracle-loads", ext: ".json")],
                  forKeyedSubscript: "traceFiles" as NSString)
for path in [args[1], args[2], folder.appendingPathComponent("vcd.js").path, folder.appendingPathComponent("cases.js").path] {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { print("cannot read", path); exit(2) }
    context.evaluateScript(source, withSourceURL: URL(fileURLWithPath: path))
    if let error = thrown { print("FAIL loading", path, error); print("TRACE CHECKS FAILED: 1"); exit(1) }
}
let started = Date()
context.evaluateScript("runTraceChecks()")
// The checks are async over in-memory dumps: their promises settle as the script's microtasks run.
var done = context.evaluateScript("globalThis.__traceDone")
while done?.isUndefined ?? true, Date().timeIntervalSince(started) < 300 {
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    done = context.evaluateScript("globalThis.__traceDone")
}
if let error = thrown { print("FAIL", error) }
let lines = done?.forProperty("lines")?.toArray() as? [String] ?? ["FAIL no results (timed out)"]
lines.forEach { print($0) }
let failures = lines.filter { $0.hasPrefix("FAIL") }.count + (thrown == nil ? 0 : 1)
let cases = lines.filter { $0.hasPrefix("ok ") || $0.hasPrefix("FAIL ") }.count
print(String(format: "%d case runs, %.1f s", cases, Date().timeIntervalSince(started)))
print(failures == 0 ? "TRACE CHECKS PASSED" : "TRACE CHECKS FAILED: \(failures)")
exit(failures == 0 ? 0 : 1)
