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
      openFresh { self.phaseA() }
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
      // A reload is done once the viewer's context is back (its Restore answer);
      // a fixed wait is not enough on a loaded machine.
      + "const reloaded = async () => { const t = Date.now(); while (!C.sessionSnapshot().state && Date.now() - t < 8000) { await sleep(50); } await sleep(300); };\n"
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
          check(r["reloaded"] as? Int == 1, "an undo during the reload changes nothing (rows drawn \(r["reloaded"] ?? "nil"))")
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
        await sleep(1500);
        R.afterReload = box().checked;
        window.cmuxWaveform.open(\(json));
        await sleep(1500);
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
          check(r["reloaded"] as? Int == 1, "an undo while the restore resolves changes nothing (rows drawn \(r["reloaded"] ?? "nil"))")
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
DispatchQueue.main.asyncAfter(deadline: .now() + 180) { print("CHECK FAILED: timeout"); exit(2) }
app.run()
