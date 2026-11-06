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
//   - two back-to-back reloads end opened, with no error and the rows kept;
//   - a session applied as a reload starts is dropped, not applied to the
//     reloaded viewer;
//   - a late <dump>.json is offered only while the user hasn't changed the view;
//   - a kept restore survives a reload during it, and an interrupted user load
//     keeps the unsaved marker and says it was interrupted (by a reload or by
//     opening another file), also when the reload comes right after the apply;
//   - undo and redo of the first signal added to a new viewer;
//   - no stale viewer context while the viewer reloads.
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
check(link("mismatch on tb.dut.c now", at: "dut") == .instancePath("tb.dut.c"), "signal named c")
check(link("check tb.u_fifo.do here", at: "u_fifo") == .instancePath("tb.u_fifo.do"), "signal named do")
check(link("read tb.mem[3][2] =", at: "mem") == .instancePath("tb.mem[3][2]"), "multi-dim index")
check(link("at tb.dut.pc.", at: "dut") == .instancePath("tb.dut.pc"), "sentence period")
check(link("see top.core.alu/x", at: "core") == nil, "prefix of a path")
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
  var strings: [String: String] = [:]

  /// Opens the file in a new viewer frame with no state to restore, as a new panel does.
  func openFresh(restore: [String: Any]? = nil, then: @escaping () -> Void) {
    var argument: [String: Any] = [
      "url": scheme.serve(fileURL: waveURL).absoluteString, "size": size(), "format": "vcd",
      "path": "/work/sim/parity.vcd", "strings": strings, "settings": [String: Any](),
    ]
    argument["restore"] = restore
    let json = String(data: try! JSONSerialization.data(withJSONObject: argument), encoding: .utf8)!
    onOpened = then
    web.evaluateJavaScript("cmuxWaveform.open(\(json))")
  }

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
      self.strings = strings
      // PARITY_FROM=AQ runs from that phase on (for iterating; the full run is the check).
      let from: [String: () -> Void] = ["P": phaseP, "AO": phaseAO, "AQ": phaseAQ, "AR": phaseAR, "AS": phaseAS, "AT": phaseAT]
      if let name = ProcessInfo.processInfo.environment["PARITY_FROM"], let phase = from[name] { phase() } else { openFresh { self.phaseA() } }
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
      // Polls a condition until it holds or the deadline passes (a loaded machine can
      // outrun a fixed sleep); the check that follows says what was missing.
      + "const until = async (f, ms = 5000) => { const t = Date.now(); let ok; while (!(ok = await f()) && Date.now() - t < ms) { await sleep(50); } return ok; };\n"
      // A reload is done once the viewer's context is back (its Restore answer);
      // a fixed wait is not enough on a loaded machine.
      // isRestoring (newer pages): until the restore itself has come back, which a
      // first non-Restore context can precede on a loaded machine.
      + "const reloaded = async () => { const t = Date.now(); const busy = () => !C.sessionSnapshot().state || (C.isRestoring && C.isRestoring()); while (busy() && Date.now() - t < 30000) { await sleep(50); } await sleep(300); };\n"
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
            self.phaseE()
          }
        }
      }
    }
  }
}

extension Harness {
  // A session applied while a reload starts must not land in the reloaded
  // viewer: its rows were resolved against the closed backend.
  func phaseE() {
    let errorsBefore = errors.count
    onOpened = {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        check(self.errors.count == errorsBefore, "no error after a reload during a restore: \(self.errors)")
        self.js("R.rows = C.sessionSnapshot().state.displayedSignals.length;") { r in
          check(r["rows"] as? Int == 3, "a session applied as a reload starts is dropped (rows \(r["rows"] ?? "nil"))")
          self.phaseF()
        }
      }
    }
    web.evaluateJavaScript("""
    (() => {
      window.cmuxCommands.applySessionFile({ text: JSON.stringify({ displayedSignals: [
        { dataType: 'netlist-variable', name: 'top.clk' } ] }), path: '/work/sim/one.json' });
      window.cmuxWaveform.reload({});
      return 1;
    })()
    """)
  }

  static let sessionText = #"{"displayedSignals":[{"dataType":"netlist-variable","name":"top.core.acc"}]}"#

  // <dump>.json read late (from an SSH host) is not offered once the user changed the view.
  func phaseF() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js("""
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(500);
        C.setSessionFile({ path: '/work/sim/parity.json', text: \(Self.jsString(Self.sessionText)) });
        await sleep(400);
        R.dialog = !!document.querySelector('.cmux-dialog-backdrop');
        R.rows = C.sessionSnapshot().state.displayedSignals.length;
        """) { r in
          check(r["dialog"] as? Bool == false, "a late session file is not offered after a user change")
          check(r["rows"] as? Int == 1, "the user's rows stay")
          self.phaseG()
        }
      }
    }
  }

  // On a viewer the user hasn't touched, the same late file is offered.
  func phaseG() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js("""
        C.setSessionFile({ path: '/work/sim/parity.json', text: \(Self.jsString(Self.sessionText)) });
        await sleep(400);
        R.dialog = !!document.querySelector('.cmux-dialog-backdrop');
        """) { r in
          check(r["dialog"] as? Bool == true, "a late session file is offered on an untouched viewer")
          self.phaseH()
        }
      }
    }
  }

  // The state cmux kept (a page reload after a WebContent crash) survives a
  // reload that lands while its rows are still resolving.
  func phaseH() {
    let restore: [String: Any] = ["dirty": false, "state": ["displayedSignals": [
      ["dataType": "netlist-variable", "name": "top.clk"],
      ["dataType": "netlist-variable", "name": "top.core.acc"],
    ]]]
    web.evaluateJavaScript("""
    (() => {
      const C = window.cmuxCommands, original = C.restoreState;
      C.restoreState = (m) => {
        C.restoreState = original;
        const pending = original(m);
        window.cmuxWaveform.reload({});
        return pending;
      };
      return 1;
    })()
    """)
    openFresh(restore: restore) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        self.js("const st = C.sessionSnapshot().state; R.rows = st ? st.displayedSignals.length : 0;") { r in
          check(r["rows"] as? Int == 2, "a kept restore survives a reload during it (rows \(r["rows"] ?? "nil"))")
          self.phaseI()
        }
      }
    }
  }

  // A load the user started that a reload overtakes leaves the unsaved marker
  // alone and says the load didn't happen.
  func phaseI() {
    strings["messageSessionLoadInterrupted"] = "INTERRUPTED"
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js("""
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(500);
        R.dirtyBefore = !document.getElementById('status-unsaved').hidden;
        C.applySessionFile({ text: \(Self.jsString(Self.sessionText)), path: '/work/sim/parity.json' });
        window.cmuxWaveform.reload({});
        await sleep(1500);
        R.dirtyAfter = !document.getElementById('status-unsaved').hidden;
        R.toast = Array.from(document.querySelectorAll('.cmux-toast')).some((t) => t.textContent === 'INTERRUPTED');
        """) { r in
          check(r["dirtyBefore"] as? Bool == true, "a user change marks the view unsaved")
          check(r["dirtyAfter"] as? Bool == true, "an interrupted load keeps the unsaved marker")
          check(r["toast"] as? Bool == true, "an interrupted load says so")
          self.phaseJ()
        }
      }
    }
  }

  // A reload right after the kept restore's apply-state is posted, before the
  // viewer's context comes back, still brings the rows back.
  func phaseJ() {
    let restore: [String: Any] = ["dirty": false, "state": ["displayedSignals": [
      ["dataType": "netlist-variable", "name": "top.clk"],
      ["dataType": "netlist-variable", "name": "top.core.acc"],
    ]]]
    web.evaluateJavaScript("""
    (() => {
      const host = window.cmuxWaveform.host, original = host.toWebview;
      host.toWebview = (m) => {
        original(m);
        if (m && m.command === 'apply-state' && m.stateChangeType === 1) {
          host.toWebview = original;
          // After restoreState's continuation (microtasks), before the frame's
          // contextUpdate comes back (a message event, a later task).
          let p = Promise.resolve();
          for (let i = 0; i < 20; i++) { p = p.then(() => {}); }
          p.then(() => {
            // As if the frame had no saved state of its own (a new page after a
            // WebContent crash): only cmux's kept restore can bring the rows back.
            const C = window.cmuxCommands, restoreState = C.restoreState;
            C.restoreState = (m) => { C.restoreState = restoreState; return restoreState(Object.assign({}, m, { state: undefined })); };
            window.cmuxWaveform.reload({});
          });
        }
      };
      return 1;
    })()
    """)
    let nativeBefore = native.count
    openFresh(restore: restore) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        // cmux's kept copy (sessionState) must never become the empty context
        // of the gap: a WebContent crash then would lose the rows.
        let posted = self.native[nativeBefore...].filter { $0["type"] as? String == "sessionState" }
        let rowCounts = posted.map { (($0["state"] as? [String: Any])?["displayedSignals"] as? [Any])?.count ?? -1 }
        check(!rowCounts.isEmpty && rowCounts.allSatisfy { $0 == 2 },
              "cmux's kept copy always holds the restored rows (sessionState rows \(rowCounts))")
        // The rows the viewer draws, not cmux's view of its context.
        self.js("R.rows = document.getElementById('viewer').contentDocument.querySelectorAll('.waveform-label').length;") { r in
          check(r["rows"] as? Int == 2, "a reload just after the restore was posted keeps it (rows drawn \(r["rows"] ?? "nil"))")
          self.phaseK()
        }
      }
    }
  }

  // A load the user started that the panel's opening another file overtakes
  // says another file opened, not that the file reloaded.
  func phaseK() {
    strings["messageSessionLoadInterruptedByOpen"] = "OTHER FILE"
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        let argument: [String: Any] = [
          "url": self.scheme.serve(fileURL: waveURL).absoluteString, "size": self.size(), "format": "vcd",
          "path": "/work/sim/other.vcd", "strings": self.strings, "settings": [String: Any](),
        ]
        let json = String(data: try! JSONSerialization.data(withJSONObject: argument), encoding: .utf8)!
        self.js("""
        C.applySessionFile({ text: \(Self.jsString(Self.sessionText)), path: '/work/sim/parity.json' });
        window.cmuxWaveform.open(\(json));
        await sleep(1500);
        const texts = Array.from(document.querySelectorAll('.cmux-toast')).map((t) => t.textContent);
        R.open = texts.includes('OTHER FILE');
        R.reload = texts.includes('INTERRUPTED');
        """) { r in
          check(r["open"] as? Bool == true, "an open that interrupts a load says another file opened")
          check(r["reload"] as? Bool == false, "and doesn't say the file reloaded")
          self.phaseL()
        }
      }
    }
  }

  // Undo and redo of the first signal added to a new viewer (VaporView's
  // document starts with an empty context, so that change is undoable).
  func phaseL() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js("""
        const drawn = () => document.getElementById('viewer').contentDocument.querySelectorAll('.waveform-label').length;
        R.start = drawn();
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(600);
        R.added = drawn();
        await C.run('cmux.undo');
        await sleep(800);
        R.undone = drawn();
        await C.run('cmux.redo');
        await sleep(800);
        R.redone = drawn();
        """) { r in
          check(r["start"] as? Int == 0 && r["added"] as? Int == 1, "a new viewer shows the added signal")
          check(r["undone"] as? Int == 0, "undo removes the first added signal (rows drawn \(r["undone"] ?? "nil"))")
          check(r["redone"] as? Int == 1, "redo brings it back (rows drawn \(r["redone"] ?? "nil"))")
          self.phaseM()
        }
      }
    }
  }

  // While the viewer reloads, cmux holds no copy of its old context: what it
  // reports (and saves) matches what the viewer draws.
  func phaseM() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js("""
        const drawn = () => document.getElementById('viewer').contentDocument.querySelectorAll('.waveform-label').length;
        const rows = () => { const st = C.sessionSnapshot().state; return st ? st.displayedSignals.length : 0; };
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(600);
        window.cmuxWaveform.reload({});
        R.during = rows();
        await reloaded();
        R.after = [rows(), drawn()];
        """) { r in
          check(r["during"] as? Int == 0, "no stale context while the viewer reloads (rows \(r["during"] ?? "nil"))")
          check((r["after"] as? [Int]) == [1, 1], "after the reload the context matches the viewer (\(r["after"] ?? "nil"))")
          self.phaseN()
        }
      }
    }
  }

  // Undo during a reload's gap, while the viewer has no rows, doesn't touch the
  // undo history: afterwards undo and redo still go to the views around the add.
  func phaseN() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js("""
        const drawn = () => document.getElementById('viewer').contentDocument.querySelectorAll('.waveform-label').length;
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(600);
        window.cmuxWaveform.reload({});
        await C.run('cmux.undo');
        await reloaded();
        R.reloaded = drawn();
        await C.run('cmux.undo');
        await sleep(800);
        R.undone = drawn();
        await C.run('cmux.redo');
        await sleep(800);
        R.redone = drawn();
        """) { r in
          check(r["reloaded"] as? Int == 0, "an undo during the reload waits for it, then takes back the add (rows drawn \(r["reloaded"] ?? "nil"))")
          check(r["undone"] as? Int == 0, "after the reload, undo removes the added signal (rows drawn \(r["undone"] ?? "nil"))")
          check(r["redone"] as? Int == 1, "and redo brings it back (rows drawn \(r["redone"] ?? "nil"))")
          self.phaseO()
        }
      }
    }
  }

  // Undo and redo with an expanded group that has a child shown. The viewer's
  // applyState removes every visible row, group and child alike, recursively:
  // the child must be disposed once, not twice.
  func phaseO() {
    let restore: [String: Any] = ["dirty": false, "state": ["displayedSignals": [
      ["dataType": "signal-group", "groupName": "grp", "collapseState": 2, "children": [
        ["dataType": "netlist-variable", "name": "top.clk"],
      ]],
    ]]]
    openFresh(restore: restore) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js("""
        const frame = document.getElementById('viewer').contentWindow;
        const errors = [];
        const consoleError = frame.console.error;
        frame.console.error = (...a) => { errors.push(a.map(String).join(' ')); consoleError.apply(frame.console, a); };
        frame.addEventListener('error', (e) => errors.push(String(e.message)));
        const drawn = () => frame.document.querySelectorAll('.waveform-label').length;
        R.start = drawn();
        await C.run('waveformViewer.addVariable', { instancePath: 'top.core.acc' });
        await sleep(600);
        R.added = drawn();
        await C.run('cmux.undo');
        await sleep(800);
        R.undone = drawn();
        await C.run('cmux.redo');
        await sleep(800);
        R.redone = drawn();
        R.errors = errors;
        """) { r in
          let start = r["start"] as? Int ?? -1, added = r["added"] as? Int ?? -1
          check(start >= 1 && added == start + 1, "the group's child is shown and the add draws a row (\(start) → \(added))")
          check((r["errors"] as? [String])?.isEmpty == true, "undo/redo with an expanded group raise no viewer error (\(r["errors"] ?? "nil"))")
          check(r["undone"] as? Int == start, "undo with an expanded group goes back to its rows (rows drawn \(r["undone"] ?? "nil"), want \(start))")
          check(r["redone"] as? Int == added, "redo brings the added row back (rows drawn \(r["redone"] ?? "nil"), want \(added))")
          self.phaseP()
        }
      }
    }
  }

  static let reloadProbe = """
  const vd = () => document.getElementById('viewer').contentDocument;
  const drawn = () => vd().querySelectorAll('.waveform-label').length;
  const rows = () => { const st = C.sessionSnapshot().state; return st ? st.displayedSignals.length : 0; };
  const sent = [];
  const toNative = H.toNative;
  H.toNative = (m) => { sent.push(m); return toNative(m); };
  const reloads = () => sent.filter((m) => m.type === 'reload').length;
  const bar = () => !document.getElementById('status-reload').hidden;
  """

  // An update the old viewer sends just after a reload starts (here, Auto
  // Reload switched on) doesn't bring the old context back. A file change
  // during the reload still reloads. A change made just before the reload
  // reaches cmux's kept copy.
  func phaseP() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.reloadProbe + """
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(600);
        await C.run('waveformViewer.addVariable', { instancePath: 'top.core.acc' });
        await sleep(50);
        const before = sent.length;
        window.cmuxWaveform.reload({});
        const kept = sent.slice(before).filter((m) => m.type === 'sessionState').pop();
        R.flushed = kept ? kept.state.displayedSignals.length : 0;
        vd().getElementById('autoReload').click();
        R.during = rows();
        await reloaded();
        await until(() => drawn() >= 2);
        R.reloaded = drawn();
        window.cmuxWaveform.reload({});
        const reloadsBefore = reloads();
        C.fileChanged();
        await reloaded();
        R.gapReloads = reloads() - reloadsBefore;
        R.bar = bar();
        await C.run('cmux.undo');
        await sleep(800);
        R.undoAdd = drawn();
        await C.run('cmux.undo');
        await sleep(800);
        R.undoFirst = drawn();
        """) { r in
          check(r["flushed"] as? Int == 2, "a change just before a reload reaches cmux's kept copy (rows \(r["flushed"] ?? "nil"))")
          check(r["during"] as? Int == 0, "an update from the old viewer during a reload doesn't bring its context back (rows \(r["during"] ?? "nil"))")
          check(r["reloaded"] as? Int == 2, "the reload brings the rows back (rows drawn \(r["reloaded"] ?? "nil"))")
          check(r["gapReloads"] as? Int == 1, "with Auto Reload on, a file change during a reload reloads (\(r["gapReloads"] ?? "nil"))")
          check(r["bar"] as? Bool == false, "and shows no reload bar")
          // Switching Auto Reload is not an undoable change (VaporView sends it as None).
          check(r["undoAdd"] as? Int == 1 && r["undoFirst"] as? Int == 0,
                "undo after the reload takes back the adds (rows drawn \(r["undoAdd"] ?? "nil") / \(r["undoFirst"] ?? "nil"))")
          self.phaseQ()
        }
      }
    }
  }

  // Save Viewer Session during a reload saves the view from before it, not an
  // empty one. Two reloads in a row keep the undo history.
  func phaseQ() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.reloadProbe + """
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(600);
        window.cmuxWaveform.reload({});
        await C.run('vaporview.saveViewerSession');
        const save = sent.filter((m) => m.type === 'saveSession').pop();
        const file = save ? JSON.parse(save.text) : null;
        R.saved = file ? file.displayedSignals.length : -1;
        R.selected = file && file.selectedSignal ? file.selectedSignal.name : null;
        await reloaded();
        window.cmuxWaveform.reload({});
        await sleep(30);
        window.cmuxWaveform.reload({});
        await reloaded();
        R.reloaded = drawn();
        await C.run('cmux.undo');
        await sleep(800);
        R.undone = drawn();
        await C.run('cmux.redo');
        await sleep(800);
        R.redone = drawn();
        """) { r in
          check(r["saved"] as? Int == 1, "a save during a reload holds the rows from before it (rows \(r["saved"] ?? "nil"))")
          check(r["selected"] as? String == "top.clk", "and its selected signal (\(r["selected"] ?? "nil"))")
          check(r["reloaded"] as? Int == 1, "two reloads in a row bring the row back (rows drawn \(r["reloaded"] ?? "nil"))")
          check(r["undone"] as? Int == 0 && r["redone"] as? Int == 1,
                "and undo/redo still work (rows drawn \(r["undone"] ?? "nil") / \(r["redone"] ?? "nil"))")
          self.phaseR()
        }
      }
    }
  }

  // After a reload that fails (a half-written file), Auto Reload still
  // reloads on the next file change.
  func phaseR() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.reloadProbe + """
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(600);
        if (!vd().getElementById('autoReload').checked) { vd().getElementById('autoReload').click(); }
        await sleep(400);
        R.auto = C.sessionSnapshot().state.autoReload;
        window.cmuxWaveform.reload({ url: 'cmux-waveform://local/missing.vcd', size: 10 });
        await sleep(1500);
        const before = reloads();
        C.fileChanged();
        R.reloads = reloads() - before;
        R.bar = bar();
        """) { r in
          check(r["auto"] as? Bool == true, "Auto Reload is on")
          check(r["reloads"] as? Int == 1, "after a failed reload, a file change still reloads (\(r["reloads"] ?? "nil"))")
          check(r["bar"] as? Bool == false, "and shows no reload bar")
          self.phaseS()
        }
      }
    }
  }

  // Auto Reload belongs to the file: it survives a reload, but another file
  // opened in the panel starts from the defaultAutoReload setting (off here).
  func phaseS() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        let argument: [String: Any] = [
          "url": self.scheme.serve(fileURL: waveURL).absoluteString, "size": self.size(), "format": "vcd",
          "path": "/work/sim/other.vcd", "strings": self.strings, "settings": [String: Any](),
        ]
        let json = String(data: try! JSONSerialization.data(withJSONObject: argument), encoding: .utf8)!
        self.js("""
        const box = () => document.getElementById('viewer').contentDocument.getElementById('autoReload');
        if (!box().checked) { box().click(); }
        await sleep(300);
        window.cmuxWaveform.reload({});
        await reloaded();
        await until(() => box() && box().checked);
        R.afterReload = box().checked;
        // The new file's viewer: its own document, once its restore is in.
        const oldDoc = document.getElementById('viewer').contentDocument;
        window.cmuxWaveform.open(\(json));
        await until(() => document.getElementById('viewer').contentDocument !== oldDoc && box());
        await reloaded();
        await until(() => box() && !box().checked);
        R.afterOpen = box().checked;
        """) { r in
          check(r["afterReload"] as? Bool == true, "Auto Reload survives a reload")
          check(r["afterOpen"] as? Bool == false, "another file opened in the panel starts with Auto Reload off (the setting)")
          self.phaseT()
        }
      }
    }
  }

  // A data request the old viewer sends just after a reload starts (a queued
  // add, a restore's rows) reaches a backend that is still opening. It must
  // not fail the reload: the old viewer is gone, and the reloaded one asks
  // again for what it shows.
  func phaseT() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        let errorsBefore = self.errors.count
        self.js("""
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(600);
        window.cmuxWaveform.reload({});
        window.cmuxWaveform.fromWebview({ command: 'fetchDataFromFile', requestList: [{ type: 'signal', signalId: 0 }] });
        await sleep(1500);
        R.rows = document.getElementById('viewer').contentDocument.querySelectorAll('.waveform-label').length;
        """) { r in
          check(self.errors.count == errorsBefore, "a request during a reload's open fails nothing (\(self.errors.suffix(from: errorsBefore)))")
          check(r["rows"] as? Int == 1, "and the reload brings the row back (rows drawn \(r["rows"] ?? "nil"))")
          self.phaseU()
        }
      }
    }
  }

  // An Undo just after the reloaded viewer asked for its state, before the
  // restore's apply-state is posted, would land first and be overwritten by
  // it: it waits, and the history stays as it was.
  func phaseU() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js("""
        const drawn = () => document.getElementById('viewer').contentDocument.querySelectorAll('.waveform-label').length;
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(600);
        const restoreState = C.restoreState;
        C.restoreState = (m) => {
          C.restoreState = restoreState;
          const p = restoreState(m);
          C.run('cmux.undo');
          return p;
        };
        window.cmuxWaveform.reload({});
        await reloaded();
        R.reloaded = drawn();
        await C.run('cmux.undo');
        await sleep(800);
        R.undone = drawn();
        await C.run('cmux.redo');
        await sleep(800);
        R.redone = drawn();
        """) { r in
          check(r["reloaded"] as? Int == 0, "an undo while the restore resolves waits for it, then takes back the add (rows drawn \(r["reloaded"] ?? "nil"))")
          check(r["undone"] as? Int == 0 && r["redone"] as? Int == 1,
                "afterwards undo/redo still work (rows drawn \(r["undone"] ?? "nil") / \(r["redone"] ?? "nil"))")
          self.phaseV()
        }
      }
    }
  }

  // After a failed reload, the unloaded viewer still sends updates (here,
  // Auto Reload switched), with no rows. They don't empty the view kept from
  // before the reload, so Save still writes its rows.
  func phaseV() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.reloadProbe + """
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(600);
        window.cmuxWaveform.reload({ url: 'cmux-waveform://local/missing.vcd', size: 10 });
        await sleep(1500);
        let seen = null;
        const onContextUpdate = C.onContextUpdate;
        C.onContextUpdate = (m) => { seen = (m.displayedSignals || []).length; return onContextUpdate(m); };
        vd().getElementById('autoReload').click();
        await sleep(300);
        C.onContextUpdate = onContextUpdate;
        R.sent = seen;
        await C.run('vaporview.saveViewerSession');
        const save = sent.filter((m) => m.type === 'saveSession').pop();
        R.saved = save ? JSON.parse(save.text).displayedSignals.length : -1;
        """) { r in
          check(r["sent"] as? Int == 0, "the unloaded viewer sends an update with no rows (\(r["sent"] ?? "nil"))")
          check(r["saved"] as? Int == 1, "a save after it still holds the rows from before the reload (rows \(r["saved"] ?? "nil"))")
          self.phaseW()
        }
      }
    }
  }

  // Undoing a new viewer's first change goes back to VaporView's empty
  // WebviewState: no marker, zoom 1, scroll 0, pixel time 1, Auto Reload from
  // the setting. The time unit is the file's.
  func phaseW() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js("""
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(600);
        let applied = null;
        const toWebview = H.toWebview;
        H.toWebview = (m) => { if (m && m.command === 'apply-state') { applied = m.state; } return toWebview(m); };
        await C.run('cmux.undo');
        await sleep(300);
        H.toWebview = toWebview;
        R.state = applied;
        R.unit = H.doc.metadata.timeUnit;
        """) { r in
          let st = r["state"] as? [String: Any] ?? [:]
          check(st["markerTime"] is NSNull && st["altMarkerTime"] is NSNull && st["selectedSignal"] is NSNull,
                "the empty view has no marker or selection (\(st))")
          check(st["zoomRatio"] as? Double == 1 && st["scrollLeft"] as? Double == 0 && st["defaultPixelTime"] as? Double == 1,
                "the empty view has zoom 1, scroll 0 and pixel time 1 (\(st))")
          check(st["autoReload"] as? Bool == false, "the empty view's Auto Reload is the setting (off)")
          check(st["displayTimeUnit"] as? String == r["unit"] as? String, "the empty view's time unit is the file's (\(st["displayTimeUnit"] ?? "nil"))")
          self.phaseX()
        }
      }
    }
  }

  // The reload bar a file change showed goes away when Auto Reload is switched
  // on, which reloads.
  func phaseX() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.reloadProbe + """
        if (vd().getElementById('autoReload').checked) { vd().getElementById('autoReload').click(); await sleep(300); }
        C.fileChanged();
        R.barShown = bar();
        vd().getElementById('autoReload').click();
        await sleep(300);
        R.reloads = reloads();
        R.barAfter = bar();
        """) { r in
          check(r["barShown"] as? Bool == true, "a file change with Auto Reload off shows the reload bar")
          check(r["reloads"] as? Int == 1, "switching Auto Reload on then reloads (\(r["reloads"] ?? "nil"))")
          check(r["barAfter"] as? Bool == false, "and hides the bar")
          self.phaseY()
        }
      }
    }
  }

  // A netlist search, a point query or a signal read while a reload opens the
  // file again fails nothing and doesn't break the reload.
  func phaseY() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        let errorsBefore = self.errors.count
        self.js("""
        const drawn = () => document.getElementById('viewer').contentDocument.querySelectorAll('.waveform-label').length;
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(600);
        window.cmuxWaveform.reload({});
        const input = document.querySelector('#netlist-search input');
        input.value = 'clk';
        input.dispatchEvent(new Event('input'));
        const calls = [
          Promise.resolve().then(() => H.valuesAtTime(10, ['top.clk'])),
          Promise.resolve().then(() => H.signalChanges({ signalId: 0 })),
          Promise.resolve().then(() => H.search('acc')),
        ].map((p) => p.then(() => 'ok', (e) => (e && e.cmuxClosed) ? 'closed' : String((e && e.message) || e)));
        R.calls = await Promise.all(calls);
        await reloaded();
        R.rows = drawn();
        input.value = '';
        input.dispatchEvent(new Event('input'));
        """) { r in
          check(self.errors.count == errorsBefore, "calls during a reload's open fail nothing (\(self.errors.suffix(from: errorsBefore)))")
          check((r["calls"] as? [String])?.allSatisfy { $0 == "ok" || $0 == "closed" } == true,
                "they answer or are dropped quietly (\(r["calls"] ?? "nil"))")
          check(r["rows"] as? Int == 1, "and the reload brings the row back (rows drawn \(r["rows"] ?? "nil"))")
          self.phaseZ()
        }
      }
    }
  }

  // After a failed reload, what the empty viewer sends (a marker set, Auto
  // Reload switched) leaves the kept view and the undo history alone; only
  // its Auto Reload counts.
  func phaseZ() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.reloadProbe + """
        if (vd().getElementById('autoReload').checked) { vd().getElementById('autoReload').click(); await sleep(300); }
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(600);
        window.cmuxWaveform.reload({ url: 'cmux-waveform://local/missing.vcd', size: 10 });
        await sleep(1500);
        H.toWebview({ command: 'setMarker', time: 20, markerType: 0 });
        await sleep(300);
        vd().getElementById('autoReload').click();
        await sleep(300);
        await C.run('vaporview.saveViewerSession');
        const save = sent.filter((m) => m.type === 'saveSession').pop();
        const file = save ? JSON.parse(save.text) : null;
        R.saved = file ? file.displayedSignals.length : -1;
        R.marker = file ? file.markerTime : 'none';
        const before = reloads();
        C.fileChanged();
        R.reloads = reloads() - before;
        """) { r in
          check(r["saved"] as? Int == 1, "the empty viewer's updates don't empty the kept view (rows \(r["saved"] ?? "nil"))")
          check(!(r["marker"] is Int) || r["marker"] as? Int != 20, "nor set its marker (\(r["marker"] ?? "nil"))")
          check(r["reloads"] as? Int == 1, "but Auto Reload switched on there counts (\(r["reloads"] ?? "nil"))")
          self.phaseZ2()
        }
      }
    }
  }

  // A second reload while the first one's restore resolves keeps the selected
  // signal for a save during it.
  func phaseZ2() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.reloadProbe + """
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(600);
        let saved = null;
        const restoreState = C.restoreState;
        C.restoreState = (m) => {
          C.restoreState = restoreState;
          const p = restoreState(m);
          window.cmuxWaveform.reload({});
          C.run('vaporview.saveViewerSession').then(() => {
            const save = sent.filter((x) => x.type === 'saveSession').pop();
            saved = save ? JSON.parse(save.text) : null;
          });
          return p;
        };
        window.cmuxWaveform.reload({});
        await sleep(2500);
        R.rows = saved ? saved.displayedSignals.length : -1;
        R.selected = saved && saved.selectedSignal ? saved.selectedSignal.name : null;
        """) { r in
          check(r["rows"] as? Int == 1, "a save in the second reload holds the rows (\(r["rows"] ?? "nil"))")
          check(r["selected"] as? String == "top.clk", "and the selected signal (\(r["selected"] ?? "nil"))")
          self.phaseZ3()
        }
      }
    }
  }

  // A remove-all the old viewer handles just before it unloads is part of the
  // view kept through the reload: a save during it writes no rows.
  func phaseZ3() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.reloadProbe + """
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(600);
        await C.run('waveformViewer.addVariable', { instancePath: 'top.core.acc' });
        await sleep(600);
        // Save right after cmux takes the old viewer's answer to the remove-all,
        // while the reload's gap is still open.
        let saving = null;
        const onContextUpdate = C.onContextUpdate;
        C.onContextUpdate = (m) => {
          const out = onContextUpdate(m);
          if (!saving && (m.displayedSignals || []).length === 0) {
            C.onContextUpdate = onContextUpdate;
            saving = C.run('vaporview.saveViewerSession');
          }
          return out;
        };
        H.toWebview({ command: 'apply-state', stateChangeType: 5, state: { displayedSignals: [] } });
        window.cmuxWaveform.reload({});
        await sleep(300);
        C.onContextUpdate = onContextUpdate;
        await saving;
        const save = sent.filter((m) => m.type === 'saveSession').pop();
        R.saved = save ? JSON.parse(save.text).displayedSignals.length : -1;
        await reloaded();
        R.rows = drawn();
        """) { r in
          check(r["saved"] as? Int == 0, "a remove-all just before a reload is kept through it (rows saved \(r["saved"] ?? "nil"))")
          check(r["rows"] as? Int == 0, "and the reload shows no rows (rows drawn \(r["rows"] ?? "nil"))")
          self.phaseAA()
        }
      }
    }
  }

  // What the emptied viewer does during a reload (a marker set, Auto Reload
  // switched) also goes into its own saved state. The reload must still bring
  // back the view from before it, also after a failed reload.
  func phaseAA() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.reloadProbe + """
        if (vd().getElementById('autoReload').checked) { vd().getElementById('autoReload').click(); await sleep(300); }
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(600);
        const frameUnloaded = C.frameUnloaded;
        C.frameUnloaded = () => {
          C.frameUnloaded = frameUnloaded;
          frameUnloaded();
          H.toWebview({ command: 'setMarker', time: 20, markerType: 0 });
        };
        window.cmuxWaveform.reload({});
        await reloaded();
        R.afterMarker = drawn();
        const good = H.config.url, goodSize = H.config.size;
        window.cmuxWaveform.reload({ url: 'cmux-waveform://local/missing.vcd', size: 10 });
        await sleep(1500);
        vd().getElementById('autoReload').click();
        await sleep(300);
        window.cmuxWaveform.reload({ url: good, size: goodSize });
        await reloaded();
        R.afterFailed = drawn();
        """) { r in
          check(r["afterMarker"] as? Int == 1, "a marker set in the emptied viewer doesn't empty the reload (rows drawn \(r["afterMarker"] ?? "nil"))")
          check(r["afterFailed"] as? Int == 1, "Auto Reload switched after a failed reload doesn't empty the next one (rows drawn \(r["afterFailed"] ?? "nil"))")
          self.phaseAE()
        }
      }
    }
  }

  // A second reload while the first one's kept view is being restored keeps
  // that view: here a remove-all the old viewer handled just before the first
  // reload, so no rows come back.
  func phaseAE() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.reloadProbe + """
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(600);
        await C.run('waveformViewer.addVariable', { instancePath: 'top.core.acc' });
        await sleep(600);
        const restoreState = C.restoreState;
        C.restoreState = (m) => {
          C.restoreState = restoreState;
          const p = restoreState(m);
          window.cmuxWaveform.reload({});
          return p;
        };
        H.toWebview({ command: 'apply-state', stateChangeType: 5, state: { displayedSignals: [] } });
        window.cmuxWaveform.reload({});
        await sleep(300);
        await reloaded();
        R.rows = drawn();
        R.kept = rows();
        """) { r in
          check(r["rows"] as? Int == 0 && r["kept"] as? Int == 0,
                "a second reload during the first one's restore keeps the remove-all (rows drawn \(r["rows"] ?? "nil"), kept \(r["kept"] ?? "nil"))")
          self.phaseAB()
        }
      }
    }
  }

  // A restoreState from a viewer that a newer reload superseded is dropped:
  // it would end the reload's gap early and resolve rows against a cleared
  // netlist ("missing signals").
  func phaseAB() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.reloadProbe + """
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(600);
        const logs = () => sent.filter((m) => m.type === 'log' && /top\\.clk/.test(m.message)).length;
        const toastsBefore = toasts(), logsBefore = logs();
        window.cmuxWaveform.reload({});
        window.cmuxWaveform.fromWebview({ command: 'restoreState', state: { displayedSignals: [{ dataType: 'netlist-variable', name: 'top.clk' }] } });
        await reloaded();
        R.toasts = toasts() - toastsBefore;
        R.logs = logs() - logsBefore;
        R.rows = drawn();
        """) { r in
          check(r["toasts"] as? Int == 0 && r["logs"] as? Int == 0,
                "a superseded restoreState is dropped (toasts \(r["toasts"] ?? "nil"), logs \(r["logs"] ?? "nil"))")
          check(r["rows"] as? Int == 1, "and the reload brings the row back (rows drawn \(r["rows"] ?? "nil"))")
          self.phaseAC()
        }
      }
    }
  }

  // A netlist search typed before a reload shows its results again after it.
  func phaseAC() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js("""
        const input = document.querySelector('#netlist-search input');
        const results = () => document.getElementById('netlist-results').textContent;
        input.value = 'clk';
        input.dispatchEvent(new Event('input'));
        await sleep(500);
        R.before = results().includes('clk');
        window.cmuxWaveform.reload({});
        await reloaded();
        for (let i = 0; i < 40 && !results().includes('clk'); i++) { await sleep(50); }
        R.after = results().includes('clk');
        input.value = '';
        input.dispatchEvent(new Event('input'));
        """) { r in
          check(r["before"] as? Bool == true, "the search finds top.clk")
          check(r["after"] as? Bool == true, "and shows it again after a reload")
          self.phaseAD()
        }
      }
    }
  }

  // Each gate on its own: the host's netlist gate during a reload, and the
  // wellen worker's "not open" before a file is loaded.
  func phaseAD() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        let errorsBefore = self.errors.count
        self.js("""
        const quiet = (p) => Promise.resolve().then(p).then(() => 'ok', (e) => (e && e.cmuxClosed) ? 'closed' : String((e && e.message) || e));
        const top = H.doc.netlist[0];
        window.cmuxWaveform.reload({});
        R.children = await quiet(() => H.getChildren({ kind: 'scope', name: top.name, id: top.id, type: top.type, scopePath: [] }));
        await reloaded();
        const worker = new Worker('wellen-worker.js');
        let next = 1;
        const call = (method, args) => new Promise((resolve) => {
          const id = next++;
          const onMessage = (e) => { if (e.data.type === 'result' && e.data.id === id) { worker.removeEventListener('message', onMessage); resolve(e.data.error || 'ok'); } };
          worker.addEventListener('message', onMessage);
          worker.postMessage({ id, method, args });
        });
        const early = call('getchildren', { id: 0, startIndex: 0 });
        const init = call('init', { wasmUrl: 'filehandler.wasm' });
        R.beforeInit = await early;
        R.init = await init;
        R.beforeLoad = await call('searchnetlist', { query: 'clk', scopeId: 0xFFFFFFFF });
        R.values = await call('getvaluesattime', { time: 0, paths: 'top.clk' });
        worker.terminate();
        """) { r in
          check(r["children"] as? String == "closed", "the netlist is closed while a reload opens the file (\(r["children"] ?? "nil"))")
          check(self.errors.count == errorsBefore, "with no error (\(self.errors.suffix(from: errorsBefore)))")
          check(r["init"] as? String == "ok", "the worker starts")
          check(r["beforeInit"] as? String == "not open" && r["beforeLoad"] as? String == "not open" && r["values"] as? String == "not open",
                "and answers \"not open\" before a file is loaded (\(r["beforeInit"] ?? "nil"), \(r["beforeLoad"] ?? "nil"), \(r["values"] ?? "nil"))")
          self.phaseAF()
        }
      }
    }
  }

  // A reload while a kept restore hasn't reached the viewer (it had no context
  // of its own), with a marker set in the emptied viewer: the frame's own
  // saved state is then empty, and the kept restore must still win.
  func phaseAF() {
    let restore: [String: Any] = ["dirty": false, "state": ["displayedSignals": [
      ["dataType": "netlist-variable", "name": "top.clk"],
    ]]]
    // The restore's apply-state is held back, as if the reload overtook it.
    web.evaluateJavaScript("""
    (() => {
      const host = window.cmuxWaveform.host, original = host.toWebview;
      host.toWebview = (m) => {
        if (m && m.command === 'apply-state' && m.stateChangeType === 1) { host.toWebview = original; return; }
        original(m);
      };
      return 1;
    })()
    """)
    openFresh(restore: restore) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.reloadProbe + """
        const frameUnloaded = C.frameUnloaded;
        C.frameUnloaded = () => {
          C.frameUnloaded = frameUnloaded;
          frameUnloaded();
          H.toWebview({ command: 'setMarker', time: 20, markerType: 0 });
        };
        let frameState = null;
        const restoreState = C.restoreState;
        C.restoreState = (m) => { C.restoreState = restoreState; frameState = m.state ? (m.state.displayedSignals || []).length : null; return restoreState(m); };
        window.cmuxWaveform.reload({});
        await reloaded();
        R.frameState = frameState;
        R.rows = drawn();
        """) { r in
          check(r["frameState"] as? Int == 0, "the emptied viewer's own state has no rows (\(r["frameState"] ?? "nil"))")
          check(r["rows"] as? Int == 1, "a kept restore wins over the emptied viewer's own state (rows drawn \(r["rows"] ?? "nil"))")
          self.phaseAG()
        }
      }
    }
  }

  // A second reload after the frame has emptied: what it sends before it
  // handles that reload's unload is still the emptied viewer's.
  func phaseAG() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.reloadProbe + """
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(600);
        const frameUnloaded = C.frameUnloaded;
        C.frameUnloaded = () => {
          C.frameUnloaded = frameUnloaded;
          frameUnloaded();
          window.cmuxWaveform.reload({});
          window.cmuxWaveform.fromWebview({ command: 'contextUpdate', stateChangeType: 5, displayedSignals: [], markerTime: 20 });
        };
        window.cmuxWaveform.reload({});
        await sleep(300);
        await reloaded();
        R.rows = drawn();
        """) { r in
          check(r["rows"] as? Int == 1, "the emptied viewer stays ignored through a second reload (rows drawn \(r["rows"] ?? "nil"))")
          self.phaseAH()
        }
      }
    }
  }

  // An Undo waiting on a reload is forgotten when that reload fails, or when
  // the reload is of another path: it would apply to a view the user didn't
  // see when pressing it.
  func phaseAH() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.reloadProbe + """
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(600);
        const good = H.config.url, size = H.config.size, path = H.config.path;
        window.cmuxWaveform.reload({ url: 'cmux-waveform://local/missing.vcd', size: 10 });
        await C.run('cmux.undo');
        await sleep(1500);
        window.cmuxWaveform.reload({ url: good, size });
        await reloaded();
        R.afterFailed = drawn();
        window.cmuxWaveform.reload({});
        await C.run('cmux.undo');
        window.cmuxWaveform.reload({ path: '/work/sim/renamed.vcd' });
        await sleep(300);
        await reloaded();
        R.afterPath = drawn();
        H.config.path = path;
        """) { r in
          check(r["afterFailed"] as? Int == 1, "an Undo waiting on a reload that failed is forgotten (rows drawn \(r["afterFailed"] ?? "nil"))")
          check(r["afterPath"] as? Int == 1, "and one overtaken by a reload of another path (rows drawn \(r["afterPath"] ?? "nil"))")
          self.phaseAI()
        }
      }
    }
  }

  // Two Undos waiting on a reload, with other contexts from the viewer in
  // between (a debugger tick, a quiet Locals edit): the second runs only after
  // the viewer answered the first, so the redo history stays right.
  func phaseAI() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.reloadProbe + """
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(600);
        await C.run('waveformViewer.addVariable', { instancePath: 'top.core.acc' });
        await sleep(600);
        let pokes = 0;
        const onContextUpdate = C.onContextUpdate;
        C.onContextUpdate = (m) => {
          const out = onContextUpdate(m);
          if (pokes < 4 && m.stateChangeType !== 0 && C.isRestoring && !C.isRestoring()) { pokes++; H.toWebview({ command: 'getContext' }); }
          return out;
        };
        window.cmuxWaveform.reload({});
        await C.run('cmux.undo');
        await C.run('cmux.undo');
        await reloaded();
        await sleep(1500);
        C.onContextUpdate = onContextUpdate;
        R.afterUndos = drawn();
        await C.run('cmux.redo');
        await sleep(800);
        await C.run('cmux.redo');
        await sleep(800);
        R.afterRedos = drawn();
        await C.run('cmux.undo');
        await sleep(800);
        R.undoAgain = drawn();
        """) { r in
          check(r["afterUndos"] as? Int == 0, "both waiting Undos apply after the reload (rows drawn \(r["afterUndos"] ?? "nil"))")
          check(r["afterRedos"] as? Int == 2, "two Redos bring both rows back (rows drawn \(r["afterRedos"] ?? "nil"))")
          check(r["undoAgain"] as? Int == 1, "and the redo history held each view once (rows drawn \(r["undoAgain"] ?? "nil"))")
          self.phaseAJ()
        }
      }
    }
  }

  // Undo pressed after a reload failed (the viewer shows the failure, not a
  // view to undo) is dropped, not applied after the next good reload.
  func phaseAJ() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.reloadProbe + """
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(600);
        const good = H.config.url, size = H.config.size;
        window.cmuxWaveform.reload({ url: 'cmux-waveform://local/missing.vcd', size: 10 });
        await sleep(1500);
        await C.run('cmux.undo');
        window.cmuxWaveform.reload({ url: good, size });
        await reloaded();
        await sleep(800);
        R.rows = drawn();
        """) { r in
          check(r["rows"] as? Int == 1, "an Undo pressed after a failed reload is dropped (rows drawn \(r["rows"] ?? "nil"))")
          self.phaseAK()
        }
      }
    }
  }

  // A reload of another path is another document: the old file's history
  // doesn't apply to it, whether Undo is pressed during or after the reload.
  func phaseAK() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.reloadProbe + """
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(600);
        window.cmuxWaveform.reload({ path: '/work/sim/other.vcd' });
        await C.run('cmux.undo');
        await reloaded();
        await sleep(800);
        R.during = drawn();
        window.cmuxWaveform.reload({ path: '/work/sim/third.vcd' });
        await reloaded();
        await C.run('cmux.undo');
        await sleep(800);
        R.after = drawn();
        """) { r in
          check(r["during"] as? Int == 1, "an Undo during a reload of another path doesn't undo the old file's change (rows drawn \(r["during"] ?? "nil"))")
          check(r["after"] as? Int == 1, "nor one after it (rows drawn \(r["after"] ?? "nil"))")
          self.phaseAL()
        }
      }
    }
  }

  // A posted view the viewer never answers (here dropped on the way) keeps the
  // waiting Undo from running in that load; it must not carry into the next
  // reload and apply there, long after it was pressed.
  func phaseAL() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.reloadProbe + """
        await C.run('waveformViewer.addVariable', { instancePath: 'top.clk' });
        await sleep(600);
        const restoreState = C.restoreState;
        C.restoreState = (m) => {
          C.restoreState = restoreState;
          const p = restoreState(m);
          const toWebview = H.toWebview;
          H.toWebview = (x) => { if (x && x.command === 'apply-state' && x.stateChangeType === 2) { H.toWebview = toWebview; return; } return toWebview(x); };
          C.run('waveformViewer.loadViewerState', { state: { displayedSignals: [{ dataType: 'netlist-variable', name: 'top.clk' }] } });
          C.run('cmux.undo');
          return p;
        };
        window.cmuxWaveform.reload({});
        await reloaded();
        await sleep(1500);
        R.stuck = drawn();
        window.cmuxWaveform.reload({});
        await reloaded();
        await sleep(1500);
        R.next = drawn();
        """) { r in
          check(r["stuck"] as? Int == 1, "an Undo behind an unanswered view doesn't run (rows drawn \(r["stuck"] ?? "nil"))")
          check(r["next"] as? Int == 1, "nor in the next reload (rows drawn \(r["next"] ?? "nil"))")
          self.phaseAM()
        }
      }
    }
  }



  static let rowsProbe = """
  const tr = () => { const out = []; const walk = (l, p) => (l || []).forEach((d) => {
    if (d.dataType === 'signal-group') { out.push(p + '[' + d.groupName + ']'); walk(d.children, p + d.groupName + '/'); }
    else if (d.name) { out.push(p + d.name); } });
    walk(H.viewerContext.webview && H.viewerContext.webview.displayedSignals, ''); return out.join(','); };
  const selected = () => H.viewerContext.webview && H.viewerContext.webview.selectedSignal;
  const tree = document.getElementById('tree');
  const rowOf = (item) => Array.from(tree.querySelectorAll('.row')).find((r) => r._item && r._item.netlistId === item.netlistId);
  const removeAll = (v) => H.toWebview({ command: 'remove-signal', netlistId: v.netlistId, rowId: undefined, removeAllSelected: false });
  const byName = (path) => C.run('waveformViewer.addVariable', { instancePath: path });
  const clk = await H.findLinkItem(['top', 'clk'], true);
  const acc = await H.findLinkItem(['top', 'core', 'acc'], true);
  const core = await H.findLinkItem(['top', 'core'], false);
  const d = window.cmuxWaveform.debugger;
  """

  // Adds of a shown signal. Bulk adds (Add All in Scope, from the netlist menu
  // or the editor, and the debugger's Locals) leave out what is shown. An
  // explicit add of one signal (double-click, Enter, a drop into a group, the
  // API by id) adds another row, as VaporView does. A pick by name or the
  // editor's Add to Waveform selects the shown row (VaporView's reveal).
  // Locals leaves out signals shown outside it, so adding the scope Locals
  // shows pins its signals once.
  func phaseAM() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.rowsProbe + """
        const n = (name) => tr().split(',').filter((x) => x === name).length;
        window.cmuxNetlist.reveal(clk);
        await sleep(300);
        rowOf(clk).dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
        await sleep(600);
        rowOf(clk).dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
        await sleep(600);
        R.dbl = n('top.clk');
        rowOf(clk).dispatchEvent(new MouseEvent('mousedown', { bubbles: true, button: 0 }));
        tree.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
        await sleep(600);
        R.key = n('top.clk');
        removeAll(clk);
        await sleep(400);
        await byName('top.clk');
        await sleep(600);
        await byName('top.clk');
        await sleep(600);
        R.name = n('top.clk'); R.nameSel = selected() === clk.netlistId;
        await window.cmuxWaveform.link.addSignal(['top', 'clk']);
        await sleep(600);
        R.linkSignal = n('top.clk');
        await C.run('vaporview.addAllInScopeShallow', core);
        await sleep(600);
        await C.run('vaporview.addAllInScopeShallow', core);
        await sleep(600);
        R.menu = n('top.core.acc');
        await C.run('waveformViewer.addVariable', { netlistId: acc.netlistId });
        await sleep(600);
        R.api = n('top.core.acc');
        removeAll(acc);
        await sleep(400);
        H.toWebview({ command: 'newSignalGroup', groupName: 'Mine', groupPath: undefined, parentGroupId: undefined,
          eventRowId: undefined, moveSelected: false, showRenameInput: false });
        await sleep(400);
        C.handleDrop({ resourceUriList: [{ cmuxNetlistId: clk.netlistId }], groupPath: ['Mine'], dropIndex: 0 });
        await sleep(600);
        R.drop = tr();
        removeAll(clk);
        await sleep(400);
        await byName('top.clk');
        await sleep(600);
        await d.step({ by: 1 });
        await d.setLocals({ path: ['top', 'core'] });
        await sleep(600);
        R.locals = tr();
        // The user's path: the editor's right-click Add All Signals in Scope (WaveformSourceLink -> link.addScope).
        await window.cmuxWaveform.link.addScope({ path: ['top', 'core'] });
        await sleep(800);
        R.pinned = tr();
        C.run('cmux.undo');
        await sleep(800);
        R.undone = tr();
        C.run('cmux.redo');
        await sleep(800);
        R.redone = tr();
        removeAll(acc);
        await sleep(800);
        R.unpinned = tr();
        await C.run('vaporview.addAllInScopeShallow', core);
        await sleep(800);
        R.menuPin = tr();
        await d.setLocals({ path: ['top'] });
        await sleep(800);
        R.top = tr();
        """) { r in
          let s = { (k: String) in r[k] as? String ?? "nil" }
          let i = { (k: String) in r[k] as? Int ?? -1 }
          let rows = { (k: String) in s(k).components(separatedBy: ",") }
          let accRows = { (k: String) in rows(k).filter { $0.hasSuffix("top.core.acc") } }
          check(i("dbl") == 2, "a second double-click adds a second row, as VaporView does: \(i("dbl"))")
          check(i("key") == 3, "so does Enter: \(i("key"))")
          check(i("name") == 1 && r["nameSel"] as? Bool == true, "a pick by name selects the shown row: \(i("name"))")
          check(i("linkSignal") == 1, "so does the editor's Add to Waveform: \(i("linkSignal"))")
          check(i("menu") == 1, "Add All in Scope twice adds each signal once: \(i("menu"))")
          check(i("api") == 2, "the API's add by id adds a second row: \(i("api"))")
          check(rows("drop").contains("Mine/top.clk") && rows("drop").contains("top.clk"),
                "dropping a shown signal into a group adds a second row there: \(s("drop"))")
          check(rows("locals").contains("Locals/top.core.acc"), "Locals shows the scope: \(s("locals"))")
          check(accRows("pinned") == ["top.core.acc"],
                "the editor's Add All Signals in Scope on the Locals scope pins its signals once, outside Locals: \(s("pinned"))")
          check(accRows("undone") == ["Locals/top.core.acc"], "Undo of the pin gives the signal back to Locals, once: \(s("undone"))")
          check(accRows("redone") == ["top.core.acc"], "Redo pins it again: \(s("redone"))")
          check(accRows("unpinned") == ["Locals/top.core.acc"], "a removed pinned signal goes back to Locals: \(s("unpinned"))")
          check(accRows("menuPin") == ["top.core.acc"], "the netlist menu's Add All in Scope pins once too: \(s("menuPin"))")
          check(rows("top").filter { $0.hasSuffix("top.clk") } == ["top.clk"], "Locals leaves out a signal already shown: \(s("top"))")
          self.phaseAN()
        }
      }
    }
  }

  // Locals respects a row the user deleted until the pinned set changes. Add
  // All counts and caps only what isn't shown. A lost add doesn't swallow
  // the next one. A reload starts with no viewer context, and a reload that
  // starts during another drops the Undo queued for it. A failure during a
  // reload that then succeeds leaves Undo working.
  func phaseAN() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.rowsProbe + Self.reloadProbe + """
        const vdoc = () => document.getElementById('viewer').contentDocument;
        const rowContextOf = (el) => JSON.parse(el.getAttribute('data-vscode-context').replace(/%x20/g, ' '));
        await byName('top.clk');
        await sleep(600);
        await d.step({ by: 1 });
        await d.setLocals({ path: ['top', 'core'] });
        await sleep(600);
        const group = Array.from(vdoc().querySelectorAll('.waveform-group')).find((e) => e.querySelector('p').textContent === 'Locals');
        const child = group && group.querySelector(':scope > .labels-group > .waveform-label');
        if (child) { H.toWebview({ command: 'remove-signal', rowId: rowContextOf(child).rowId, removeAllSelected: false }); }
        await sleep(1000);
        R.deleted = tr();
        await window.cmuxWaveform.link.addScope({ path: ['top', 'core'] });
        await sleep(800);
        removeAll(acc);
        await sleep(800);
        R.back = tr();
        // A scope whose first 128 signals are shown already: no warning, and the next one is added.
        removeAll(acc);
        await sleep(400);
        await d.setLocals({ path: null });
        await sleep(400);
        const fake = { kind: 'scope', name: 'fake', scopePath: ['top'], children: new Array(128).fill(clk).concat([acc]) };
        // An earlier phase's dialog may still be open on this page: count new ones.
        const dialogs = () => Array.from(document.querySelectorAll('.cmux-dialog-backdrop'));
        const open = dialogs();
        const adding = C.run('vaporview.addAllInScopeShallow', fake);
        await sleep(800);
        const fresh = dialogs().filter((e) => !open.includes(e));
        R.warned = fresh.length > 0;
        const no = fresh.length ? fresh[0].querySelector('button') : null;
        if (no) { no.click(); }
        await adding;
        await sleep(600);
        R.capped = tr();
        // An add the viewer never got (here dropped on its way) doesn't block the next one.
        removeAll(clk);
        await sleep(400);
        const w = document.getElementById('viewer').contentWindow;
        const post = w.postMessage.bind(w);
        w.postMessage = (m, o) => { if (m && m.command === 'add-variable') { w.postMessage = post; return; } return post(m, o); };
        await window.cmuxWaveform.link.addScope({ path: ['top'] });
        w.postMessage = post;
        await C.run('waveformViewer.loadViewerState', { state: { displayedSignals: [{ dataType: 'netlist-variable', name: 'top.core.acc' }] } });
        await sleep(400);
        await window.cmuxWaveform.link.addScope({ path: ['top'] });
        await sleep(600);
        R.readd = tr();
        // A reload starts without the old viewer's context.
        window.cmuxWaveform.reload({});
        R.ctx = H.viewerContext.webview === null;
        await reloaded();
        await sleep(800);
        // An Undo queued in a reload's gap doesn't carry into a reload started before it ran.
        await C.run('waveformViewer.addVariable', { netlistId: clk.netlistId });
        await sleep(600);
        R.before = tr();
        window.cmuxWaveform.reload({});
        C.run('cmux.undo');
        window.cmuxWaveform.reload({});
        await reloaded();
        await sleep(1500);
        R.queued = tr();
        // A failure during a reload that then succeeds leaves Undo working.
        if (!tr().split(',').includes('top.clk')) { await C.run('waveformViewer.addVariable', { netlistId: clk.netlistId }); await sleep(600); }
        window.cmuxWaveform.reload({});
        H.fail(new Error('probe'));
        await reloaded();
        await sleep(800);
        removeAll(clk);
        await sleep(600);
        R.preUndo = tr();
        C.run('cmux.undo');
        await sleep(800);
        R.undo = tr();
        """) { r in
          let s = { (k: String) in r[k] as? String ?? "nil" }
          let rows = { (k: String) in s(k).components(separatedBy: ",") }
          check(!rows("deleted").contains("Locals/top.core.acc"), "a Locals row the user deleted stays deleted: \(s("deleted"))")
          check(rows("back").contains("Locals/top.core.acc"), "until the pinned set changes: \(s("back"))")
          check(r["warned"] as? Bool == false, "Add All doesn't count shown signals toward its warning")
          check(rows("capped").contains("top.core.acc"), "nor toward its 128 cap: \(s("capped"))")
          check(rows("readd").contains("top.clk"), "a lost add doesn't swallow the next one: \(s("readd"))")
          check(r["ctx"] as? Bool == true, "a reload starts with no viewer context")
          check(s("queued") == s("before"), "a reload started in another's gap drops its queued Undo: \(s("before")) -> \(s("queued"))")
          check(rows("undo").contains("top.clk") && !rows("preUndo").contains("top.clk"),
                "Undo works after a reload that failed on the way and then succeeded: \(s("preUndo")) -> \(s("undo"))")
          self.phaseAO()
        }
      }
    }
  }

  // The old viewer's context, sent after a reload started, doesn't come back
  // as the shown rows for the reload's gap. An add dropped into Locals
  // doesn't block a following Add All. An add made while an Undo resolves
  // its rows lands after the Undo, not under it.
  func phaseAO() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.rowsProbe + """
        await byName('top.clk');
        await sleep(600);
        const restoreState = C.restoreState;
        C.restoreState = async (m) => { C.restoreState = restoreState; await sleep(2000); return restoreState(m); };
        // The old viewer answers this with a context after the reload began.
        H.toWebview({ command: 'setSelectedSignal', netlistId: clk.netlistId });
        window.cmuxWaveform.reload({});
        let stale = 0;
        const t = Date.now();
        await sleep(20);
        while (C.isRestoring() && Date.now() - t < 20000) {
          const w = H.viewerContext.webview;
          if (w && (w.displayedSignals || []).length) { stale++; }
          await sleep(20);
        }
        R.stale = stale;
        await reloaded();
        await sleep(600);
        R.afterReload = tr();
        // Drop top.clk into Locals, then Add All of top: it is pinned.
        removeAll(clk);
        await sleep(400);
        await d.step({ by: 1 });
        await d.setLocals({ path: ['top', 'core'] });
        await sleep(600);
        C.handleDrop({ resourceUriList: [{ cmuxNetlistId: clk.netlistId }], groupPath: ['Locals'], dropIndex: 0 });
        await sleep(600);
        R.dropped = tr();
        R.addAll = JSON.stringify(await window.cmuxWaveform.link.addScope({ path: ['top'] }));
        await sleep(600);
        R.pinned = tr();
        // An add during an Undo's row lookup.
        await d.setLocals({ path: null });
        await sleep(400);
        removeAll(acc);
        await sleep(400);
        removeAll(clk);
        await sleep(400);
        await byName('top.clk');
        await sleep(600);
        removeAll(clk);
        await sleep(600);
        const findItem = H.findItem;
        H.findItem = async (...a) => { await sleep(800); return findItem(...a); };
        C.run('cmux.undo');
        await sleep(100);
        await window.cmuxWaveform.link.addScope({ path: ['top', 'core'] });
        await sleep(2000);
        H.findItem = findItem;
        R.undoAdd = tr();
        """) { r in
          let s = { (k: String) in r[k] as? String ?? "nil" }
          let rows = { (k: String) in s(k).components(separatedBy: ",") }
          check(r["stale"] as? Int == 0, "the old viewer's late context isn't the shown rows during the reload (\(r["stale"] ?? "nil") samples)")
          check(rows("afterReload") == ["top.clk"], "the reloaded viewer's rows are: \(s("afterReload"))")
          check(rows("dropped").contains("Locals/top.clk"), "top.clk dropped into Locals: \(s("dropped"))")
          check(s("addAll").contains(#""added":1"#), "a following Add All isn't blocked by it: \(s("addAll")) -> \(s("pinned"))")
          check(rows("undoAdd").contains("top.clk") && rows("undoAdd").contains("top.core.acc"),
                "an add during an Undo's row lookup lands after the Undo: \(s("undoAdd"))")
          self.phaseAP()
        }
      }
    }
  }

  // Add All counts and caps only what isn't shown: with 130 of a scope's 140
  // signals shown, it adds the other 10 without asking.
  func phaseAP() {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("parity-wide-\(getpid()).vcd")
    var text = "$timescale 1ns $end\n$scope module top $end\n$scope module wide $end\n"
    let ids = (0..<140).map { "w\($0)" }
    for (i, id) in ids.enumerated() { text += "$var wire 1 \(id) s\(i) $end\n" }
    text += "$upscope $end\n$upscope $end\n$enddefinitions $end\n#0\n"
    for id in ids { text += "0\(id)\n" }
    text += "#10\n"
    for id in ids { text += "1\(id)\n" }
    try! text.write(to: url, atomically: true, encoding: .utf8)
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    let argument: [String: Any] = ["url": scheme.serve(fileURL: url).absoluteString, "size": size, "format": "vcd",
                                   "path": url.path, "strings": strings, "settings": [String: Any]()]
    let json = String(data: try! JSONSerialization.data(withJSONObject: argument), encoding: .utf8)!
    onOpened = {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.rowsProbe.replacingOccurrences(of: "const clk", with: "const clk0").replacingOccurrences(of: "const acc", with: "const acc0").replacingOccurrences(of: "const core", with: "const core0") + """
        const wide = await H.findLinkItem(['top', 'wide'], false);
        const names = [];
        for (let i = 0; i < 130; i++) { names.push({ dataType: 'netlist-variable', name: 'top.wide.s' + i }); }
        await C.run('waveformViewer.loadViewerState', { state: { displayedSignals: names } });
        await sleep(1500);
        R.before = tr().split(',').length;
        const dialogs = () => Array.from(document.querySelectorAll('.cmux-dialog-backdrop'));
        const open = dialogs();
        const adding = C.run('vaporview.addAllInScopeShallow', wide);
        await sleep(1500);
        const fresh = dialogs().filter((e) => !open.includes(e));
        R.warned = fresh.length > 0;
        const no = fresh.length ? fresh[0].querySelector('button') : null;
        if (no) { no.click(); }
        await adding;
        await sleep(1500);
        const all = tr().split(',');
        R.after = all.length;
        R.distinct = new Set(all).size;
        """) { r in
          try? FileManager.default.removeItem(at: url)
          check(r["before"] as? Int == 130, "130 of the 140 shown: \(r["before"] ?? "nil")")
          check(r["warned"] as? Bool == false, "Add All doesn't ask: only 10 would be added")
          check(r["after"] as? Int == 140 && r["distinct"] as? Int == 140, "and adds them once each: \(r["after"] ?? "nil") rows, \(r["distinct"] ?? "nil") distinct")
          self.phaseAQ()
        }
      }
    }
    web.evaluateJavaScript("cmuxWaveform.open(\(json))")
  }

  // An add made while an Undo or a reload's restore looks up its rows is
  // checked against the rows that view brings back, not the ones it replaces:
  // Add All and a pick by name leave a signal it restores once. An add held
  // for a view that a reload then overtakes is dropped, and Add All says so.
  func phaseAQ() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.rowsProbe + """
        const n = (name) => tr().split(',').filter((x) => x === name).length;
        const link = window.cmuxWaveform.link;
        const findItem = H.findItem;
        const slow = (ms) => { H.findItem = async (...a) => { await sleep(ms); return findItem(...a); }; };
        await byName('top.clk');
        await sleep(600);
        removeAll(clk);
        await sleep(600);
        // Add All of top while the Undo that brings top.clk back resolves.
        slow(800);
        C.run('cmux.undo');
        await sleep(100);
        R.undoScope = JSON.stringify(await link.addScope({ path: ['top'] }));
        await sleep(1500);
        H.findItem = findItem;
        R.undoScopeRows = tr(); R.undoScopeClk = n('top.clk');
        // Back to one top.clk row, whatever the step before left.
        removeAll(clk);
        await sleep(400);
        await byName('top.clk');
        await sleep(600);
        // A pick by name (link.addSignal: reveal) during the same Undo.
        removeAll(clk);
        await sleep(600);
        slow(800);
        C.run('cmux.undo');
        await sleep(100);
        await link.addSignal(['top', 'clk']);
        await sleep(1500);
        H.findItem = findItem;
        R.undoPickRows = tr(); R.undoPickClk = n('top.clk');
        // Back to one top.clk row, whatever the step before left.
        removeAll(clk);
        await sleep(400);
        await byName('top.clk');
        await sleep(600);
        // Add All of top while a reload's restore (top.clk) resolves.
        const restoreState = C.restoreState;
        let during = null;
        C.restoreState = async (m) => {
          C.restoreState = restoreState;
          slow(800);
          const p = restoreState(m);
          await sleep(100);
          during = link.addScope({ path: ['top'] });
          await p;
          H.findItem = findItem;
        };
        window.cmuxWaveform.reload({});
        await reloaded();
        await sleep(1000);
        R.reloadScope = JSON.stringify(await during);
        R.reloadRows = tr(); R.reloadClk = n('top.clk');
        // Back to one top.clk row, whatever the step before left.
        removeAll(clk);
        await sleep(400);
        await byName('top.clk');
        await sleep(600);
        // An add held for an Undo that a reload overtakes is dropped.
        removeAll(clk);
        await sleep(600);
        slow(2500);
        C.run('cmux.undo');
        await sleep(100);
        const held = link.addScope({ path: ['top', 'core'] });
        await sleep(100);
        window.cmuxWaveform.reload({});
        R.heldScope = JSON.stringify(await held);
        H.findItem = findItem;
        await reloaded();
        await sleep(800);
        R.heldRows = tr();
        // An Undo whose lookup never settles holds adds only until a reload.
        await byName('top.clk');
        await sleep(600);
        removeAll(clk);
        await sleep(600);
        H.findItem = () => new Promise(() => {});
        C.run('cmux.undo');
        await sleep(100);
        const stuck = link.addScope({ path: ['top', 'core'] });
        await sleep(100);
        H.findItem = findItem;
        window.cmuxWaveform.reload({});
        const pending = () => sleep(5000).then(() => 'pending');
        R.stuckScope = JSON.stringify(await Promise.race([stuck, pending()]));
        await reloaded();
        await sleep(600);
        R.afterStuck = JSON.stringify(await Promise.race([link.addScope({ path: ['top', 'core'] }), pending()]));
        await sleep(600);
        R.afterStuckRows = tr();
        // An Undo of the load before that settles during the reload's restore
        // doesn't end the restore's hold.
        removeAll(acc);
        await sleep(400);
        await byName('top.clk');
        await sleep(600);
        await byName('top.core.acc');
        await sleep(600);
        R.lateBefore = tr();
        slow(2500);
        let late = null;
        C.restoreState = async (m) => {
          C.restoreState = restoreState;
          const p = restoreState(m);
          await sleep(100);
          R.lateRestoreAt = Date.now() - lateStart;
          late = link.addScope({ path: ['top'] });
          await p;
        };
        const lateStart = Date.now();
        C.run('cmux.undo');
        await sleep(100);
        window.cmuxWaveform.reload({});
        await reloaded();
        R.lateScope = JSON.stringify(await late);
        H.findItem = findItem;
        await sleep(800);
        R.lateRows = tr();
        // A reload's restore whose lookups never settle (an SSH host gone
        // quiet) holds an Add All and a pick by name only for the hold limit;
        // then they run (verify-parity-fu H1).
        const holdCap = C.holdLimitMs, settleCap = C.settleTimeoutMs;
        C.holdLimitMs = 1500; C.settleTimeoutMs = 1000;
        let never = null;
        C.restoreState = async (m) => {
          C.restoreState = restoreState;
          H.findItem = () => new Promise(() => {});
          restoreState(m);
          await sleep(100);
          never = link.addScope({ path: ['top', 'core'] });
          await link.addSignal(['top', 'clk']);
        };
        const neverStart = Date.now();
        window.cmuxWaveform.reload({});
        while (!never && Date.now() - neverStart < 10000) { await sleep(50); }
        R.neverScope = JSON.stringify(never ? await Promise.race([never, sleep(6000).then(() => 'pending')]) : 'no restore');
        R.neverMs = Date.now() - neverStart;
        await sleep(400);
        R.neverRows = tr();
        H.findItem = findItem;
        // The limit counts from when the lookup started: an Add All alone in
        // such a restore waits the hold limit in all, not its settle wait and
        // then the hold limit again.
        C.holdLimitMs = 3000; C.settleTimeoutMs = 2000;
        let alone = null, aloneStart = 0;
        C.restoreState = async (m) => {
          C.restoreState = restoreState;
          aloneStart = Date.now();
          H.findItem = () => new Promise(() => {});
          restoreState(m);
          await sleep(100);
          alone = link.addScope({ path: ['top', 'core'] });
        };
        const aloneT0 = Date.now();
        window.cmuxWaveform.reload({});
        while (!alone && Date.now() - aloneT0 < 10000) { await sleep(50); }
        R.aloneScope = JSON.stringify(alone ? await Promise.race([alone, sleep(9000).then(() => 'pending')]) : 'no restore');
        R.aloneMs = Date.now() - aloneStart;
        await sleep(400);
        R.aloneRows = tr();
        H.findItem = findItem;
        C.holdLimitMs = holdCap; C.settleTimeoutMs = settleCap;
        """) { r in
          let s = { (k: String) in r[k] as? String ?? "nil" }
          check(r["undoScopeClk"] as? Int == 1, "Add All during an Undo that restores top.clk leaves it once: \(s("undoScopeRows"))")
          check(s("undoScope").contains(#""added":0"#), "and says it added none: \(s("undoScope"))")
          check(r["undoPickClk"] as? Int == 1, "a pick by name during that Undo leaves top.clk once: \(s("undoPickRows"))")
          check(r["reloadClk"] as? Int == 1, "Add All during a reload's restore leaves top.clk once: \(s("reloadRows"))")
          check(s("reloadScope").contains(#""added":0"#), "and says it added none: \(s("reloadScope"))")
          check(!s("heldRows").contains("top.core.acc"), "an add held for an Undo a reload overtook is dropped: \(s("heldRows"))")
          check(s("heldScope").contains(#""added":0"#), "and Add All says it added none: \(s("heldScope"))")
          check(s("stuckScope").contains(#""added":0"#), "Add All held by an Undo that never settles answers once a reload drops it: \(s("stuckScope"))")
          check(s("afterStuck").contains(#""added":1"#) && s("afterStuckRows").contains("top.core.acc"),
                "and adds after the reload aren't held: \(s("afterStuck")) -> \(s("afterStuckRows"))")
          check(s("lateBefore") == "top.clk,top.core.acc" && s("lateScope").contains(#""added":0"#) && s("lateRows") == "top.clk,top.core.acc",
                "an old load's Undo settling during the restore doesn't release the restore's held add: \(s("lateBefore")) -> \(s("lateScope")) -> \(s("lateRows"))")
          let neverMs = r["neverMs"] as? Int ?? -1
          check(s("neverScope").contains(#""added":1"#) && neverMs < 6000 && s("neverRows").contains("top.core.acc") && s("neverRows").contains("top.clk"),
                "a restore whose lookups never settle holds Add All and a pick by name only for the hold limit: \(s("neverScope")) after \(neverMs) ms -> \(s("neverRows"))")
          let aloneMs = r["aloneMs"] as? Int ?? -1
          check(s("aloneScope").contains(#""added":1"#) && aloneMs >= 2500 && aloneMs < 4200 && s("aloneRows").contains("top.core.acc"),
                "the hold limit counts from the lookup's start, not after Add All's settle wait: \(s("aloneScope")) after \(aloneMs) ms (limit 3000, settle 2000) -> \(s("aloneRows"))")
          self.phaseAR()
        }
      }
    }
  }

  // A context the viewer posted before an add reached it, showing the signal
  // only in Locals, doesn't end that add's wait: a second Add All of the
  // scope, made on that context, doesn't add it again at the top level.
  func phaseAR() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.rowsProbe + """
        await d.step({ by: 1 });
        await d.setLocals({ path: ['top', 'core'] });
        await sleep(800);
        R.locals = tr();
        const before = JSON.parse(JSON.stringify(H.viewerContext.webview));
        R.first = JSON.stringify(await window.cmuxWaveform.link.addScope({ path: ['top', 'core'] }));
        await window.cmuxWaveform.fromWebview(Object.assign({}, before, { command: 'contextUpdate' }));
        R.second = JSON.stringify(await window.cmuxWaveform.link.addScope({ path: ['top', 'core'] }));
        await sleep(800);
        R.rows = tr(); R.accRows = tr().split(',').filter((x) => x === 'top.core.acc').length;
        await d.setLocals({ path: null });
        await sleep(400);
        """) { r in
          let s = { (k: String) in r[k] as? String ?? "nil" }
          check(s("locals") == "[Locals],Locals/top.core.acc", "top.core.acc in Locals: \(s("locals"))")
          check(s("first").contains(#""added":1"#), "Add All of top.core adds it at the top level: \(s("first"))")
          check(s("second").contains(#""added":0"#) && r["accRows"] as? Int == 1,
                "a second Add All on a context from before the add doesn't add it again: \(s("second")) -> \(s("rows"))")
          self.phaseAS()
        }
      }
    }
  }

  // Opening a file: a context the old viewer sends after the open began is
  // not the new viewer's shown rows (host.js takes contexts only after init).
  func phaseAS() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.rowsProbe + """
        await byName('top.clk');
        await sleep(600);
        const frame = document.querySelector('iframe');
        frame.contentWindow.cmuxOldFrame = true;
        // The contexts the old frame sends from here on.
        const fromOld = new Set();
        const listener = (m) => { try { if (frame.contentWindow.cmuxOldFrame) { fromOld.add(m); } } catch (e) {} };
        H.contextListeners.push(listener);
        H.toWebview({ command: 'setSelectedSignal', netlistId: clk.netlistId });
        window.cmuxWaveform.open(Object.assign({}, H.config, { restore: null }));
        let stale = 0;
        const t = Date.now();
        while (Date.now() - t < 3000) {
          if (fromOld.has(H.viewerContext.webview)) { stale++; }
          await sleep(10);
        }
        H.contextListeners.splice(H.contextListeners.indexOf(listener), 1);
        R.stale = stale; R.oldContexts = fromOld.size;
        """) { r in
          check(r["oldContexts"] as? Int ?? 0 > 0, "the old viewer sent a context after the open began")
          check(r["stale"] as? Int == 0, "the old viewer's context after an open isn't the shown rows (\(r["stale"] ?? "nil") samples)")
          self.phaseAT()
        }
      }
    }
  }

  // verify-parity-fu N1: an Add All during an Undo that removes a signal adds it
  // (its candidates are the rows the Undo leaves, not the rows before it), from
  // link.addScope and from the netlist menu. N2: an add into Locals still on its
  // way doesn't keep Add All from pinning that signal.
  func phaseAT() {
    openFresh {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.js(Self.rowsProbe + """
        const n = (name) => tr().split(',').filter((x) => x === name).length;
        const link = window.cmuxWaveform.link;
        const findItem = H.findItem;
        const slow = (ms) => { H.findItem = async (...a) => { await sleep(ms); return findItem(...a); }; };
        const top = await H.findLinkItem(['top'], false);
        await byName('top.core.acc'); await sleep(600);
        await byName('top.clk'); await sleep(600);
        R.before = tr();
        // The Undo takes top.clk out while it looks up its rows (slowly).
        slow(1500); C.run('cmux.undo'); await sleep(100);
        R.scope = JSON.stringify(await link.addScope({ path: ['top'] }));
        await sleep(2000); H.findItem = findItem;
        R.afterScope = tr();
        // The Undo of that Add All takes it out again: the netlist menu's Add All during it.
        slow(1500); C.run('cmux.undo'); await sleep(100);
        await C.run('vaporview.addAllInScopeShallow', top);
        await sleep(2000); H.findItem = findItem;
        R.afterMenu = tr();
        removeAll(clk); removeAll(acc); await sleep(600);
        // N2: a drop of top.clk into Locals, then Add All of top at once.
        await d.step({ by: 1 });
        await d.setLocals({ path: ['top', 'core'] });
        await sleep(600);
        C.handleDrop({ resourceUriList: [{ cmuxNetlistId: clk.netlistId }], groupPath: ['Locals'], dropIndex: 0 });
        R.localsScope = JSON.stringify(await link.addScope({ path: ['top'] }));
        await sleep(800);
        R.afterLocals = tr();
        R.pinnedClk = n('top.clk');
        // A pinned drop of top.clk still on its way, then a drop of it into Locals, then Add All:
        // the Locals add doesn't hide the pinned one, so it is pinned once.
        removeAll(clk); await sleep(800);
        R.clearedClk = n('top.clk');
        C.handleDrop({ resourceUriList: [{ cmuxNetlistId: clk.netlistId }], groupPath: [], dropIndex: 0 });
        C.handleDrop({ resourceUriList: [{ cmuxNetlistId: clk.netlistId }], groupPath: ['Locals'], dropIndex: 0 });
        R.pendingScope = JSON.stringify(await link.addScope({ path: ['top'] }));
        await sleep(800);
        R.afterPending = tr();
        R.pinnedAfterPending = n('top.clk');
        await d.setLocals({ path: null }); await sleep(400);
        // W1: a view whose rows never come back (a lookup that doesn't answer) holds Add All for at
        // most the settle cap, then it reads the rows as they are.
        const cap = C.settleTimeoutMs; C.settleTimeoutMs = 1000;
        slow(60000); C.run('cmux.undo'); await sleep(100);
        const started = Date.now();
        R.cappedScope = JSON.stringify(await link.addScope({ path: ['top'] }));
        R.cappedMs = Date.now() - started;
        H.findItem = findItem; C.settleTimeoutMs = cap;
        """) { r in
          let s = { (k: String) in r[k] as? String ?? "nil" }
          check(s("before") == "top.core.acc,top.clk", "AT setup: \(s("before"))")
          check(s("scope") == #"{"added":1,"total":1}"# && s("afterScope") == "top.core.acc,top.clk",
                "Add All during an Undo that takes top.clk out adds it back: \(s("scope")) → \(s("afterScope"))")
          check(s("afterMenu") == "top.core.acc,top.clk", "the netlist menu's Add All during such an Undo too: \(s("afterMenu"))")
          check(s("localsScope") == #"{"added":1,"total":1}"# && r["pinnedClk"] as? Int == 1,
                "Add All right after a drop into Locals pins the signal once: \(s("localsScope")), pinned \(r["pinnedClk"] ?? "nil"): \(s("afterLocals"))")
          check(r["clearedClk"] as? Int == 0 && s("pendingScope") == #"{"added":0,"total":0}"# && r["pinnedAfterPending"] as? Int == 1,
                "a drop into Locals doesn't hide a pinned drop still on its way: Add All \(s("pendingScope")), pinned \(r["clearedClk"] ?? "nil") → \(r["pinnedAfterPending"] ?? "nil"): \(s("afterPending"))")
          let cappedMs = r["cappedMs"] as? Int ?? -1
          check(s("cappedScope") != "nil" && s("cappedScope") != "null" && cappedMs >= 900 && cappedMs < 4000,
                "Add All while a view's rows never come back answers after the settle cap: \(s("cappedScope")) in \(cappedMs) ms")
          print("PARITY CHECKS PASSED")
          exit(0)
        }
      }
    }
  }
  static func jsString(_ s: String) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)!.dropFirst().dropLast().description
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let harness = MainActor.assumeIsolated { Harness() }
MainActor.assumeIsolated { harness.start() }
DispatchQueue.main.asyncAfter(deadline: .now() + 900) { print("CHECK FAILED: timeout"); exit(2) }
app.run()
