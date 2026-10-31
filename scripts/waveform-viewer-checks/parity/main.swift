// Parity checks for the waveform viewer (reviews of c8a6575 and 15e8459), run
// through ./run.sh parity. Loads Resources/vaporview through the real
// WaveformViewerSchemeHandler in an off-screen, transparent, click-through
// WKWebView (never shown, never activated) and checks:
//   - WaveformTerminalLink (CmuxTerminalCore): file names are not instance
//     paths, times never start inside a word, 50,000-character lines stay fast;
//   - terminal-link commands report a miss (no signal, time past the end), so
//     the click falls through to cmux's file links;
//   - settings are type-checked and clamped to VaporView's ranges;
//   - the page never names a path to write, and a JSON file that isn't a
//     session is refused;
//   - a missing signal stays as a placeholder row;
//   - two back-to-back reloads end opened, with no error and the rows kept.
// Exits 0 and prints PARITY CHECKS PASSED, or prints CHECK FAILED and exits 2.
// Usage: parity <assetRoot> <parity.vcd>
import AppKit
import Foundation
import WebKit

let args = CommandLine.arguments
let assetRoot = URL(fileURLWithPath: args[1], isDirectory: true)
let waveURL = URL(fileURLWithPath: args[2])

func check(_ ok: Bool, _ message: String) {
  if !ok { print("CHECK FAILED:", message); exit(2) }
}

// ---- WaveformTerminalLink, the matcher behind ⌘-click (same table as the package test) ----
func link(_ line: String, at target: String, tops: [String] = ["top", "tb"], instancePaths: Bool = true) -> WaveformTerminalLink? {
  let column = (line as NSString).range(of: target).location
  return WaveformTerminalLink.detect(in: line, column: column, topScopes: tops, instancePaths: instancePaths)
}
check(link("UVM_INFO @ 50000: reporter", at: "50000") == .time(50000, units: nil), "uvm time")
check(link("error at 1,250 ns in", at: "250") == .time(1250, units: "ns"), "1,250 ns")
check(link("at 3.5us done", at: "3.5") == .time(3.5, units: "us"), "3.5us")
check(link("at 12.5 μs done", at: "12.5") == .time(12.5, units: "us"), "greek mu")
check(link("at 12.5 µs done", at: "µs") == .time(12.5, units: "us"), "micro sign")
check(link("signal top.core.alu.acc[15:0] bad", at: "core") == .instancePath("top.core.alu.acc[15:0]"), "instance path")
check(link("tb.dut.pc: mismatch", at: "dut") == .instancePath("tb.dut.pc"), "path before colon")
for (line, target) in [
  ("Error: tb.sv:42: syntax error", "tb.sv"), ("vlog rtl/top.sv rtl/top_pkg.sv", "top.sv"),
  ("Compiling top.v", "top.v"), ("/tmp/top.core.a", "core"), ("~/top.core.a", "core"),
  ("see xtop.core.a", "core"), ("see foo.top.core.a", "core"), ("Error: tb.sv:42: syntax error", "42"),
] {
  check(link(line, at: target) == nil, "file name \(line) at \(target)")
}
for (line, target) in [
  ("vcs -f files.f -o sim_100ns", "100ns"), ("tests/test_10ms.py::test_ok PASSED", "10ms"),
  ("run_5us.log", "5us"), ("1. s", "1"), ("a .s b", ".s"), ("v1.5ns", "1.5"),
] {
  check(link(line, at: target) == nil, "time inside a word: \(line)")
}
check(link("signal top.core.acc", at: "core", instancePaths: false) == nil, "setting off")
check(WaveformTerminalLink.detect(in: String(repeating: "9", count: 400) + " ns", column: 399, topScopes: [], instancePaths: false) == nil,
      "non-finite or cut time")
for filler in ["1", ".", ",", "1 "] {
  let line = String(repeating: filler, count: 50_000)
  let start = Date()
  for column in [0, 25_000, 49_999] {
    _ = WaveformTerminalLink.detect(in: line, column: column, topScopes: ["top"], instancePaths: true)
  }
  let seconds = Date().timeIntervalSince(start)
  check(seconds < 0.5, "50k '\(filler)' line took \(seconds) s")
}
print("terminal link checks passed")

// ---- the page ----
@MainActor
final class Harness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1200, height: 500),
                        styleMask: [.borderless], backing: .buffered, defer: false)
  let scheme = WaveformViewerSchemeHandler(assetRoot: assetRoot)
  var web: WKWebView!
  var opened = 0
  var errors: [String] = []
  var native: [[String: Any]] = []
  var onOpened: (() -> Void)?

  func start() {
    let cfg = WKWebViewConfiguration()
    cfg.setURLSchemeHandler(scheme, forURLScheme: WaveformViewerSchemeHandler.scheme)
    cfg.userContentController.add(self, name: "cmuxWaveform")
    // Never visible: off-screen, transparent, click-through, never ordered front.
    window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    web = WKWebView(frame: window.contentView!.bounds, configuration: cfg)
    web.navigationDelegate = self
    window.contentView!.addSubview(web)
    web.load(URLRequest(url: WaveformViewerSchemeHandler.indexURL))
  }

  func size() -> Int {
    (try? FileManager.default.attributesOfItem(atPath: waveURL.path)[.size] as? NSNumber)?.intValue ?? 0
  }

  func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
    guard let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
    native.append(body)
    switch type {
    case "ready":
      guard opened == 0, native.filter({ $0["type"] as? String == "ready" }).count == 1 else { return }
      let strings: [String: String] = [
        "loading": "Loading", "openFailed": "Could not open", "netlist": "Netlist",
        "messageSignalNotFound": "Signal not found: %@", "messageSessionLoadFailed": "Failed: %@",
        "messageNotASession": "not a session", "messageSessionMismatch": "mismatch",
      ]
      let argument: [String: Any] = [
        "url": scheme.serve(fileURL: waveURL).absoluteString, "size": size(), "format": "vcd",
        "path": "/work/sim/parity.vcd", "strings": strings, "settings": [String: Any](),
      ]
      let json = String(data: try! JSONSerialization.data(withJSONObject: argument), encoding: .utf8)!
      web.evaluateJavaScript("cmuxWaveform.open(\(json))")
      onOpened = { self.phaseA() }
    case "opened":
      opened += 1
      let next = onOpened
      onOpened = nil
      next?()
    case "error":
      errors.append(body["message"] as? String ?? "?")
    default:
      break
    }
  }

  func js(_ body: String, _ then: @escaping ([String: Any]) -> Void) {
    let wrapped = "const sleep = (ms) => new Promise((r) => setTimeout(r, ms));\n"
      + "const C = window.cmuxCommands, H = window.cmuxWaveform.host, R = {};\n"
      + "const toasts = () => document.querySelectorAll('.cmux-toast').length;\n"
      + body + "\nreturn JSON.stringify(R);"
    web.callAsyncJavaScript(wrapped, arguments: [:], in: nil, in: .page) { result in
      switch result {
      case .success(let value):
        let object = (value as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
        guard let object else { check(false, "js returned \(String(describing: value))"); return }
        print("js:", object)
        then(object)
      case .failure(let error):
        check(false, "js failed: \(error)")
      }
    }
  }

  // Terminal-link commands and settings.
  func phaseA() {
    js("""
    R.addExisting = await C.run('waveformViewer.addVariable', { instancePath: 'top.core.acc', quiet: true });
    await sleep(300);
    const before = toasts();
    R.addMissing = await C.run('waveformViewer.addVariable', { instancePath: 'top.nope', quiet: true });
    R.missingToasted = toasts() > before;
    R.markerIn = await C.run('waveformViewer.setMarker', { time: 50, units: 'ns', markerType: 0 });
    R.markerOut = await C.run('waveformViewer.setMarker', { time: 5, units: 'us', markerType: 0 });
    R.markerTicks = await C.run('waveformViewer.setMarker', { time: 50, markerType: 0 });
    C.updateSetting('userPixelRatio', 0); R.pixelRatio = C.settings().userPixelRatio;
    C.updateSetting('animationDuration', 9999); R.animationDuration = C.settings().animationDuration;
    C.updateSetting('bogusKey', 1); R.bogus = C.settings().bogusKey === undefined;
    C.updateSetting('enableAnimations', 'yes'); R.animType = typeof C.settings().enableAnimations;
    await C.run('waveformViewer.addVariable', { instancePath: 'top.clk', quiet: true });
    await sleep(600);
    R.rows = C.sessionSnapshot().state.displayedSignals.length;
    """) { r in
      check(r["addExisting"] as? Bool == true, "addVariable of an existing signal reports true")
      check(r["addMissing"] as? Bool == false, "addVariable of a missing signal reports false")
      check(r["missingToasted"] as? Bool == false, "a quiet miss shows no toast")
      check(r["markerIn"] as? Bool == true, "setMarker in range reports true")
      check(r["markerOut"] as? Bool == false, "setMarker past the end reports false")
      check(r["markerTicks"] as? Bool == true, "setMarker in dump ticks")
      check((r["pixelRatio"] as? Double) == 0.1, "userPixelRatio clamped to 0.1")
      check((r["animationDuration"] as? Double) == 500, "animationDuration clamped to 500")
      check(r["bogus"] as? Bool == true, "unknown setting ignored")
      check(r["animType"] as? String == "boolean", "a boolean setting keeps its type")
      check(r["rows"] as? Int == 2, "two rows shown")
      self.phaseB()
    }
  }

  // Sessions: no write path from the page; a non-session file is refused.
  func phaseB() {
    js("""
    await C.run('vaporview.saveViewerSession');
    await sleep(100);
    const before = toasts();
    C.applySessionFile({ text: '{"name": "a testbench config"}', path: '/work/sim/parity.json' });
    await sleep(400);
    R.refusedToast = toasts() > before;
    R.rows = C.sessionSnapshot().state.displayedSignals.length;
    """) { r in
      let saves = self.native.filter { $0["type"] as? String == "saveSession" }
      check(saves.count == 1, "one saveSession message")
      check(saves.allSatisfy { $0["path"] == nil }, "saveSession names no path")
      let text = saves.first?["text"] as? String ?? ""
      let file = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
      check(file?["displayedSignals"] is [Any], "the saved text is a session")
      check(self.native.filter { $0["type"] as? String == "sessionState" }.allSatisfy { $0["sessionPath"] == nil },
            "sessionState names no path")
      check(r["refusedToast"] as? Bool == true, "a JSON file that isn't a session is refused with a toast")
      check(r["rows"] as? Int == 2, "a refused file leaves the viewer alone")
      self.phaseC()
    }
  }

  // A missing signal stays as a placeholder row.
  func phaseC() {
    js("""
    const session = { displayedSignals: [
      { dataType: 'netlist-variable', name: 'top.clk' },
      { dataType: 'netlist-variable', name: 'top.gone.sig' },
      { dataType: 'netlist-variable', name: 'top.core.acc' } ], selectedSignal: { name: 'top.clk' } };
    C.applySessionFile({ text: JSON.stringify(session), path: '/work/sim/parity.json' });
    await sleep(800);
    const rows = C.sessionSnapshot().state.displayedSignals;
    R.rows = rows.length;
    R.names = rows.map((s) => s.name);
    R.placeholder = rows.length > 1 && rows[1].netlistId === undefined;
    """) { r in
      check(r["rows"] as? Int == 3, "the missing row is kept (rows \(r["rows"] ?? "nil"))")
      check(r["placeholder"] as? Bool == true, "the kept row has no netlistId")
      check((r["names"] as? [String])?[1] == "top.gone.sig", "the kept row keeps its name")
      self.phaseD()
    }
  }

  // Two reloads back to back, each with a new file token as the panel serves one.
  func phaseD() {
    let errorsBefore = errors.count
    let first = scheme.serve(fileURL: waveURL)
    web.evaluateJavaScript("cmuxWaveform.reload({ url: '\(first.absoluteString)', size: \(size()) })")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
      let second = self.scheme.serve(fileURL: waveURL)
      self.web.evaluateJavaScript("cmuxWaveform.reload({ url: '\(second.absoluteString)', size: \(self.size()) })")
      self.onOpened = {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
          check(self.errors.count == errorsBefore, "no error after two reloads: \(self.errors)")
          self.js("""
          R.rows = C.sessionSnapshot().state.displayedSignals.length;
          R.metadata = !!H.doc.metadata;
          R.marker = await C.run('waveformViewer.setMarker', { time: 20, units: 'ns', markerType: 0 });
          """) { r in
            check(r["metadata"] as? Bool == true, "the reloaded file is open")
            check(r["rows"] as? Int == 3, "rows kept across two reloads (rows \(r["rows"] ?? "nil"))")
            check(r["marker"] as? Bool == true, "the reloaded viewer takes a marker")
            print("PARITY CHECKS PASSED")
            exit(0)
          }
        }
      }
    }
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let harness = MainActor.assumeIsolated { Harness() }
MainActor.assumeIsolated { harness.start() }
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { print("CHECK FAILED: timeout"); exit(2) }
app.run()
