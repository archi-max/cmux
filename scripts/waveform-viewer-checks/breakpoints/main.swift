// Waveform debugger breakpoint checks (run.sh breakpoints): loads Resources/vaporview through
// the real WaveformViewerSchemeHandler in an off-screen WKWebView, opens breakpoints.vcd (from
// make-vcd.py) and drives window.cmuxWaveform.debugger's breakpoints as cmux would: change and
// equals breakpoints, continue and reverse continue, where a hit lands, play stopping at a hit,
// the list in the page and the waveform row's menu items.
// Usage: breakpoints <assetRoot> <breakpoints.vcd> <out.png>
import AppKit
import WebKit

let args = CommandLine.arguments
let assetRoot = URL(fileURLWithPath: args[1], isDirectory: true)
let waveURL = URL(fileURLWithPath: args[2])
let out = URL(fileURLWithPath: args[3])
var failures = 0

@MainActor
final class Harness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 600),
                        styleMask: [.titled], backing: .buffered, defer: false)
  let scheme = WaveformViewerSchemeHandler(assetRoot: assetRoot)
  var web: WKWebView!
  var lineEvents: [[String: Any]] = []
  var listEvents: [[[String: Any]]] = []
  var movedEvents: [[String: Any]] = []
  var openedCount = 0
  var watchEvents: [[String]] = []

  func call(_ js: String) async -> Any? {
    do { return try await web.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page) }
    catch { print("JS ERROR", js, error); return nil }
  }

  func expect(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }

  func sleep(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

  /// The marker once the viewer reports it (a move is posted to the viewer frame first).
  func marker(_ expected: Int? = nil) async -> Int? {
    var value: Int?
    for _ in 0..<40 {
      value = await call("return cmuxWaveform.viewerContext.webview.markerTime ?? null") as? Int
      if expected == nil || value == expected { return value }
      await sleep(50)
    }
    return value
  }

  func dbg(_ expression: String) async -> [String: Any]? {
    await call("return await cmuxWaveform.debugger.\(expression)") as? [String: Any]
  }

  func list() async -> [[String: Any]] {
    await call("return cmuxWaveform.debugger.breakpoints()") as? [[String: Any]] ?? []
  }

  func toasts() async -> [String] {
    await call("return Array.from(document.querySelectorAll('.cmux-toast')).map((t) => t.textContent)") as? [String] ?? []
  }

  func clearToasts() async { _ = await call("document.querySelectorAll('.cmux-toast').forEach((t) => t.remove()); return null") }

  /// continue({ dir }) then the marker it moved to: [hit time, landed, marker].
  func go(_ dir: Int, expect landed: Int?) async -> (hit: [String: Any]?, marker: Int?) {
    let result = await dbg("continue({ dir: \(dir) })")
    let hit = result?["hit"] as? [String: Any]
    return (hit, await marker(landed))
  }

  func runChecks() async {
    // No breakpoints: F5 keeps Play/Pause; reverse continue says there are none.
    let none = await dbg("continue({ dir: 1, orTogglePlay: true })")
    expect(none?["playing"] as? Bool == true, "no breakpoints: F5 plays: \(String(describing: none))")
    _ = await dbg("pause()")
    await clearToasts()
    let noneBack = await dbg("continue({ dir: -1 })")
    expect(noneBack?["hit"] is NSNull && noneBack?["reason"] as? String == "none", "no breakpoints: reverse continue finds none: \(String(describing: noneBack))")
    expect(await toasts().contains("No breakpoints are enabled."), "and says so: \(await toasts())")
    _ = await dbg("jump({ to: 'first' })")
    expect(await marker(5) == 5, "marker on the first posedge")

    // A change breakpoint on a registered signal: each hit lands on the posedge it changed at.
    let state = await call("return cmuxWaveform.debugger.addBreakpoint({ path: ['top', 'state'], kind: 'change' })") as? [String: Any]
    let stateId = state?["id"] as? Int
    expect(stateId != nil && state?["enabled"] as? Bool == true, "change breakpoint added: \(String(describing: state))")
    var landed: [Int] = []
    for expected in [95, 195, 295, 395] {
      let (hit, at) = await go(1, expect: expected)
      landed.append(at ?? -1)
      expect(hit?["time"] as? Int == expected && hit?["landed"] as? Int == expected && hit?["id"] as? Int == stateId,
             "continue: state changes at \(expected), lands there: \(String(describing: hit)), marker \(String(describing: at))")
    }
    let end = await dbg("continue({ dir: 1 })")
    expect(end?["hit"] is NSNull && end?["reason"] as? String == "end", "no change after 395: \(String(describing: end))")
    expect(await marker(395) == 395, "the marker stays at 395")
    expect(await toasts().contains("No breakpoint hit before the end."), "and says so: \(await toasts())")
    for expected in [295, 195, 95] {
      let (hit, at) = await go(-1, expect: expected)
      expect(hit?["landed"] as? Int == expected && at == expected, "reverse continue lands on \(expected): \(String(describing: hit)), \(String(describing: at))")
    }
    let start = await dbg("continue({ dir: -1 })")
    expect(start?["hit"] is NSNull && start?["reason"] as? String == "start", "the dump's first value is not a change: \(String(describing: start))")
    expect(await toasts().contains("No breakpoint hit before the start."), "and says so: \(await toasts())")

    // A change between posedges lands on the first posedge at or after it; the message has the exact time.
    _ = await call("cmuxWaveform.debugger.setBreakpointEnabled({ id: \(stateId ?? -1), enabled: false }); return null")
    let irq = await call("return cmuxWaveform.debugger.addBreakpoint({ path: ['top', 'irq'], kind: 'change' })") as? [String: Any]
    let irqId = irq?["id"] as? Int
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    await clearToasts()
    var (hit, at) = await go(1, expect: 55)
    expect(hit?["time"] as? Int == 52 && hit?["landed"] as? Int == 55 && at == 55 && hit?["cycle"] as? Int == 6,
           "irq rises at 52: lands on 55, cycle 6: \(String(describing: hit)), \(String(describing: at))")
    let message = await toasts()
    expect(message.contains("Breakpoint: top.irq changes at 52 ns (cycle 6)"), "the hit message has the exact time: \(message)")
    (hit, at) = await go(1, expect: 705)
    expect(hit?["time"] as? Int == 702 && at == 705, "its fall at 53 lands on 55 too, so the next hit is 702 at 705: \(String(describing: hit))")
    (hit, at) = await go(-1, expect: 55)
    expect(hit?["time"] as? Int == 53 && at == 55, "reverse from 705: the fall at 53, on 55: \(String(describing: hit))")
    let before = await dbg("continue({ dir: -1 })")
    expect(before?["reason"] as? String == "start", "reverse from 55: nothing before it: \(String(describing: before))")
    _ = await call("cmuxWaveform.link.setMarker(50); return null")
    _ = await marker(50)
    (hit, at) = await go(1, expect: 55)
    expect(hit?["time"] as? Int == 52 && at == 55, "from mid-cycle 50: the rise at 52, on 55: \(String(describing: hit))")
    _ = await call("cmuxWaveform.debugger.setBreakpointEnabled({ id: \(irqId ?? -1), enabled: false }); return null")

    // Equals: hex, decimal, '?' for any bit, x; the dump's first value counts when it matches.
    func equals(_ value: String) async -> Int? {
      let bp = await call("return cmuxWaveform.debugger.addBreakpoint({ path: ['top', 'data'], kind: 'equals', value: \"\(value)\" })") as? [String: Any]
      return bp?["id"] as? Int
    }
    func only(_ id: Int?) async {
      _ = await call("""
        for (const b of cmuxWaveform.debugger.breakpoints()) {
          cmuxWaveform.debugger.setBreakpointEnabled({ id: b.id, enabled: b.id === \(id ?? -1) });
        }
        return null
      """)
    }
    for (value, expected) in [("'h5a", 605), ("8'h5A", 605), ("165", 305), ("8'b????_0101", 305), ("'b1010_0101", 305)] {
      let id = await equals(value)
      expect(id != nil, "equals \(value) added")
      await only(id)
      _ = await dbg("jump({ to: 'first' })")
      _ = await marker(5)
      let (hit, at) = await go(1, expect: expected)
      expect(hit?["time"] as? Int == expected && at == expected, "data == \(value): first at \(expected): \(String(describing: hit)), \(String(describing: at))")
      _ = await call("cmuxWaveform.debugger.removeBreakpoint({ id: \(id ?? -1) }); return null")
    }
    let x = await equals("x")
    await only(x)
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    (hit, at) = await go(1, expect: 505)
    expect(hit?["time"] as? Int == 505, "data == x after the first posedge: 505: \(String(describing: hit))")
    (hit, at) = await go(-1, expect: 5)
    expect(hit?["time"] as? Int == 0 && at == 5, "reverse: x from the start (time 0), on the first posedge: \(String(describing: hit)), \(String(describing: at))")
    _ = await call("cmuxWaveform.debugger.removeBreakpoint({ id: \(x ?? -1) }); return null")
    await clearToasts()
    let bad = await call("return cmuxWaveform.debugger.addBreakpoint({ path: ['top', 'data'], kind: 'equals', value: 'zq' })")
    expect(bad is NSNull, "an unreadable value is not added: \(String(describing: bad))")
    let wide = await call("return cmuxWaveform.debugger.addBreakpoint({ path: ['top', 'data'], kind: 'equals', value: \"'h1ff\" })")
    expect(wide is NSNull, "a value wider than the signal is not added: \(String(describing: wide))")
    expect(await toasts().count == 2, "both say why: \(await toasts())")
    let busy = await call("return cmuxWaveform.debugger.addBreakpoint({ path: ['top', 'busy'], kind: 'change' })") as? [String: Any]
    await only(busy?["id"] as? Int)
    let never = await dbg("continue({ dir: 1 })")
    expect(never?["reason"] as? String == "end", "a signal that never changes: no hit: \(String(describing: never))")

    // Several enabled: the nearest wins.
    _ = await call("""
      for (const b of cmuxWaveform.debugger.breakpoints()) {
        cmuxWaveform.debugger.setBreakpointEnabled({ id: b.id, enabled: b.id === \(stateId ?? -1) || b.id === \(irqId ?? -1) });
      }
      return null
    """)
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    var hits: [Int] = []
    for expected in [55, 95, 195, 295, 395, 705] {
      let (hit, _) = await go(1, expect: expected)
      hits.append(hit?["landed"] as? Int ?? -1)
    }
    expect(hits == [55, 95, 195, 295, 395, 705], "state and irq: the nearest each time: \(hits)")

    // F5 with breakpoints continues instead of playing.
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    let f5 = await dbg("continue({ dir: 1, orTogglePlay: true })")
    expect((f5?["hit"] as? [String: Any])?["landed"] as? Int == 55 && f5?["playing"] as? Bool != true,
           "F5 with breakpoints continues: \(String(describing: f5))")

    // Play stops at the first hit it crosses, even when a tick skips cycles.
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    _ = await dbg("play({ rate: 500 })")
    var playing = true
    for _ in 0..<60 where playing {
      await sleep(50)
      playing = (await dbg("state()"))?["playing"] as? Bool ?? false
    }
    let stop1 = await marker(55)
    expect(!playing && stop1 == 55, "play at 500 cycles/s stops on 55, irq's first hit: \(String(describing: stop1))")
    _ = await dbg("play({ rate: 500 })")
    playing = true
    for _ in 0..<60 where playing {
      await sleep(50)
      playing = (await dbg("state()"))?["playing"] as? Bool ?? false
    }
    let stop2 = await marker(95)
    expect(!playing && stop2 == 95, "played on from there: stops on 95 (state): \(String(describing: stop2))")

    // The list in the page: one row each, a checkbox to enable, a button to remove.
    let rows = await call("""
      const list = document.getElementById('cmux-breakpoints');
      if (!list || !list.closest('#netlist')) { return null; }
      return Array.from(list.querySelectorAll('.cmux-breakpoint')).map((r) => [r.querySelector('.label').textContent, r.querySelector('input').checked]);
    """) as? [[Any]]
    let labels = rows?.compactMap { $0.first as? String } ?? []
    expect(labels == ["top.state changes", "top.irq changes", "top.busy changes"], "the list in the netlist pane: \(String(describing: rows))")
    _ = await call("document.querySelector('#cmux-breakpoints .cmux-breakpoint input').click(); return null")
    expect((await list()).first?["enabled"] as? Bool == false, "its checkbox disables the first: \(await list())")
    _ = await call("document.querySelector('#cmux-breakpoints .cmux-breakpoint .remove').click(); return null")
    expect((await list()).map { $0["id"] as? Int } == [irqId, busy?["id"] as? Int], "its remove button removes it: \(await list())")
    let hitMark = await call("return Array.from(document.querySelectorAll('#cmux-breakpoints .cmux-breakpoint')).map((r) => r.classList.contains('hit'))") as? [Bool]
    expect(hitMark == [false, false], "the last hit (state) was removed, so none is marked: \(String(describing: hitMark))")

    // The waveform row's menu: Break When Changes and Break When Equals… for the row's signal.
    let menu = await call("""
      const v = await cmuxWaveform.host.findLinkItem(['top', 'data'], true);
      const items = window.cmuxDebugger.rowMenuItems({ webviewSection: 'signal', netlistId: v.netlistId });
      const labels = items.map((i) => i.label);
      const change = items.find((i) => i.label === 'Break When Changes');
      if (change) { await change.run(); }
      return labels;
    """) as? [String]
    expect(menu == ["Break When Changes", "Break When Equals…", "Add Watch"], "the row menu items: \(String(describing: menu))")
    let added = (await list()).last
    expect(added?["path"] as? [String] == ["top", "data"] && added?["kind"] as? String == "change",
           "Break When Changes adds one for the row's signal: \(String(describing: added))")
    let notSignal = await call("return window.cmuxDebugger.rowMenuItems({ webviewSection: 'signal-separator' }).length") as? Int
    expect(notSignal == 0, "no items on a separator row")

    // ... in the viewer's own context menu on a signal row.
    _ = await call("""
      const v = await cmuxWaveform.host.findLinkItem(['top', 'state'], true);
      cmuxWaveform.host.addVariables([v]);
      return null
    """)
    var shown: [String]?
    for _ in 0..<40 {
      shown = await call("""
        const d = document.getElementById('viewer').contentDocument;
        const row = Array.from(d.querySelectorAll('[data-vscode-context]')).find((el) => /"webviewSection":"signal"/.test(el.getAttribute('data-vscode-context').replace(/%x20/g, ' ')));
        if (!row) { return null; }
        row.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 20, clientY: 20 }));
        const labels = Array.from(document.querySelectorAll('.cmux-menu-item .label')).map((l) => l.textContent);
        window.cmuxUI.closeMenus();
        return labels;
      """) as? [String]
      if shown != nil { break }
      await sleep(100)
    }
    expect(shown?.contains("Break When Changes") == true && shown?.contains("Break When Equals…") == true,
           "a signal row's context menu has both: \(String(describing: shown))")

    await runReviewChecks()
    await runEvaluateChecks()
    await runConditionChecks()
    await runReview42Checks()
    await runLineChecks()
    print(failures == 0 ? "BREAKPOINT CHECKS PASSED" : "BREAKPOINT CHECKS FAILED: \(failures)")
    snap()
  }

  func removeAll() async {
    _ = await call("for (const b of cmuxWaveform.debugger.breakpoints()) { cmuxWaveform.debugger.removeBreakpoint({ id: b.id }); } return null")
  }

  func add(_ name: String, _ kind: String = "change", value: String? = nil) async -> Int? {
    let v = value.map { ", value: \"\($0)\"" } ?? ""
    let bp = await call("return cmuxWaveform.debugger.addBreakpoint({ path: ['top', '\(name)'], kind: '\(kind)'\(v) })") as? [String: Any]
    return bp?["id"] as? Int
  }

  func setMarker(_ time: Int) async {
    _ = await call("cmuxWaveform.link.setMarker(\(time)); return null")
    _ = await marker(time)
  }

  func waitForPause(_ tries: Int) async -> Bool {
    var playing = true
    for _ in 0..<tries where playing {
      await sleep(50)
      playing = (await dbg("state()"))?["playing"] as? Bool ?? false
    }
    return !playing
  }

  /// The B1 review's checks: landings from mid-cycle both ways, Play waiting for the editors,
  /// equals hitting only when it becomes equal, the wellen change cap, play never moving back,
  /// a hit after the last posedge, the clock with no edges, and what is said or kept once.
  func runReviewChecks() async {
    await removeAll()
    // Reverse from mid-cycle 50: pulse rose at 41, which lands on 45 (the posedge before the marker).
    _ = await add("pulse")
    await setMarker(50)
    var (hit, at) = await go(-1, expect: 45)
    expect(hit?["time"] as? Int == 41 && at == 45, "reverse from mid-cycle 50: the rise at 41, on 45: \(String(describing: hit)), \(String(describing: at))")
    await removeAll()
    // Forward from 54, past the change at 52 but before the posedge it lands on: still 55.
    _ = await add("irq")
    await setMarker(54)
    (hit, at) = await go(1, expect: 55)
    expect(hit?["time"] as? Int == 52 && at == 55, "forward from 54: the rise at 52 lands ahead, on 55: \(String(describing: hit)), \(String(describing: at))")

    // Play waiting for the editors (the app's default) stops at a hit too; Stop clears the hit mark.
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    _ = await call("cmuxWaveform.debugger.setRtlStatus({ wait: true, ok: true, text: '' }); return null")
    _ = await dbg("play({ rate: 50 })")
    let paused = await waitForPause(100)
    let waited = await marker(55)
    expect(paused && waited == 55, "play waiting for the editors stops on 55, irq's first hit: \(String(describing: waited))")
    expect((await list()).first?["hit"] as? Bool == true, "and marks irq as hit: \(await list())")
    _ = await call("cmuxWaveform.debugger.setRtlStatus({ wait: false, ok: true, text: '' }); return null")
    _ = await dbg("stop()")
    expect((await list()).allSatisfy { $0["hit"] as? Bool == false }, "Stop clears the hit mark: \(await list())")
    await removeAll()

    // Equals hits when the value becomes equal, not on each change that stays equal: mode == 'b?1
    // is 1 at 105, 3 at 205 (still equal), 2 at 305, 1 at 405.
    let mode = await add("mode", "equals", value: "'b?1")
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    var landed: [Int] = []
    for expected in [105, 405] {
      let (h, _) = await go(1, expect: expected)
      landed.append(h?["time"] as? Int ?? -1)
    }
    let afterMode = await dbg("continue({ dir: 1 })")
    expect(landed == [105, 405] && afterMode?["reason"] as? String == "end", "mode == 'b?1: 105 and 405 only: \(landed), \(String(describing: afterMode?["reason"]))")
    // The same value written another way is the same breakpoint.
    let again = await add("mode", "equals", value: "2'b?1")
    let data1 = await add("data", "equals", value: "'h5a")
    let data2 = await add("data", "equals", value: "90")
    expect(again == mode && data1 != nil && data2 == data1, "equal values are one breakpoint: \(String(describing: [mode, again, data1, data2]))")
    await removeAll()

    // The wellen backend honours the cap: a signal past it is not built (or sent) at all.
    let capped = await call("""
      const v = await cmuxWaveform.host.findLinkItem(['top', 'clk'], true);
      const few = await cmuxWaveform.host.signalChanges(v, 10);
      const all = await cmuxWaveform.host.signalChanges(v, 1000);
      return [few === null, Array.isArray(all) ? all.length : -1];
    """) as? [Any]
    expect(capped?.first as? Bool == true && (capped?.last as? Int ?? 0) > 200, "clk's 201 changes: null past a cap of 10, all of them under 1000: \(String(describing: capped))")

    // No changes yet (the backend not ready) is not "changes too often", and is asked again.
    _ = await add("state")
    _ = await call("""
      const real = cmuxWaveform.host.signalChanges;
      cmuxWaveform.host.signalChanges = (v, m) => { cmuxWaveform.host.signalChanges = real; return Promise.resolve(undefined); };
      return null
    """)
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    await clearToasts()
    _ = await dbg("continue({ dir: 1 })")
    expect(!(await toasts()).contains { $0.contains("too often") }, "no changes yet is not too many: \(await toasts())")
    (hit, _) = await go(1, expect: 95)
    expect(hit?["time"] as? Int == 95, "and they are read on the next continue: \(String(describing: hit))")

    // Play never moves back: a stop found after play has passed it is not jumped back to.
    await removeAll()
    _ = await call("""
      const real = cmuxWaveform.host.signalChanges;
      window.cmuxRealSignalChanges = real;
      cmuxWaveform.host.signalChanges = (v, m) => new Promise((r) => setTimeout(r, 250)).then(() => real(v, m));
      return null
    """)
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    movedEvents.removeAll()
    _ = await dbg("play({ rate: 100 })")
    _ = await add("state")
    let stopped = await waitForPause(100)
    _ = await call("cmuxWaveform.host.signalChanges = window.cmuxRealSignalChanges; return null")
    let back = movedEvents.filter { ($0["movedTo"] as? Int ?? 0) < ($0["left"] as? Int ?? 0) }
    let end = await marker()
    expect(stopped && back.isEmpty && (end ?? 0) > 95, "play never moves back to a hit it passed: \(back), ended at \(String(describing: end))")
    await removeAll()

    // A change after the last posedge has no cycle to land on: said so.
    _ = await add("late")
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    await clearToasts()
    let late = await dbg("continue({ dir: 1 })")
    expect(late?["reason"] as? String == "afterLastEdge", "a change at 1000, after the last posedge (995): \(String(describing: late?["reason"]))")
    expect((await toasts()).contains("Breakpoint: top.late changes at 1,000 ns, after the last clock edge."), "and says so: \(await toasts())")

    // A clock that never rises: said as that, not as no clock.
    _ = await dbg("setClock({ path: ['top', 'busy'] })")
    let flat = await dbg("continue({ dir: 1 })")
    expect(flat?["reason"] as? String == "noEdges", "a clock with no edges: \(String(describing: flat?["reason"]))")
    _ = await dbg("setClock({ path: ['top', 'clk'] })")
    await removeAll()

    // Break When Equals… whose prompt fails leaves no unhandled rejection.
    let unhandled = await call("""
      const reasons = [];
      const onRejection = (e) => { reasons.push(String(e.reason)); e.preventDefault(); };
      window.addEventListener('unhandledrejection', onRejection);
      const prompt = window.cmuxUI.prompt;
      window.cmuxUI.prompt = () => Promise.reject(new Error('prompt failed'));
      const v = await cmuxWaveform.host.findLinkItem(['top', 'data'], true);
      const item = window.cmuxDebugger.rowMenuItems({ webviewSection: 'signal', netlistId: v.netlistId }).find((i) => i.label === 'Break When Equals…');
      item.run();
      await new Promise((r) => setTimeout(r, 100));
      window.cmuxUI.prompt = prompt;
      window.removeEventListener('unhandledrejection', onRejection);
      return reasons;
    """) as? [String]
    expect(unhandled == [], "a failed prompt is caught: \(String(describing: unhandled))")
  }

  func evaluate(_ expr: String, scope: [String]? = nil) async -> [String: Any]? {
    let scopeJS = scope.map { "[" + $0.map { "'\($0)'" }.joined(separator: ", ") + "]" } ?? "undefined"
    let escaped = expr.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return await dbg("evaluate({ expr: \"\(escaped)\", scope: \(scopeJS) })")
  }

  func watchRows() async -> [[String]] {
    await call("""
      const list = document.getElementById('cmux-watches');
      if (!list || !list.closest('#netlist') || list.hidden) { return []; }
      return Array.from(list.querySelectorAll('.cmux-watch')).map((r) => [r.querySelector('.label').textContent,
        r.querySelector('.value').textContent, r.classList.contains('changed') ? 'changed' : '']);
    """) as? [[String]] ?? []
  }

  /// Rows once they show `expected` (watches refresh after the marker moves).
  func watchRows(becoming expected: [[String]]) async -> [[String]] {
    var rows: [[String]] = []
    for _ in 0..<40 {
      rows = await watchRows()
      if rows == expected { return rows }
      await sleep(50)
    }
    return rows
  }

  /// Evaluate (an expression at the marker, in the shown instance) and watches.
  func runEvaluateChecks() async {
    await removeAll()
    _ = await dbg("setLocals({ path: ['top'] })")
    await setMarker(305)
    var r = await evaluate("data")
    expect(r?["value"] as? String == "8'ha5" && r?["width"] as? Int == 8, "data at 305 in the shown instance: \(String(describing: r))")
    r = await evaluate("data + 1")
    expect(r?["value"] as? String == "32'h000000a6", "data + 1: \(String(describing: r?["value"]))")
    r = await evaluate("state == 3 && mode[1]")
    expect(r?["value"] as? String == "1'h1", "state == 3 && mode[1]: \(String(describing: r?["value"]))")
    r = await evaluate("top.data[7:4]")
    expect(r?["value"] as? String == "4'ha", "an absolute path and a select: \(String(describing: r?["value"]))")
    r = await evaluate("irq", scope: ["top"])
    // irq's row is shown in the viewer (binary, as 1-bit rows are): its row's radix.
    expect(r?["value"] as? String == "1'b0" && (r?["bits"] as? String) == "0", "a scope given with the call, in the row's radix: \(String(describing: r))")
    r = await evaluate("nope + 1")
    expect(r?["error"] as? String == "unknownName" && r?["message"] as? String == "nope is not in this waveform (column 1)",
           "an unknown name: \(String(describing: r))")
    r = await evaluate("data +")
    expect(r?["message"] as? String == "Unexpected text (column 7)", "a syntax error says where: \(String(describing: r?["message"]))")
    await setMarker(505)
    r = await evaluate("data")
    expect(r?["value"] as? String == "8'hxx", "x at 505: \(String(describing: r?["value"]))")
    r = await evaluate("data == 0")
    expect(r?["value"] as? String == "1'hx", "x compares as x: \(String(describing: r?["value"]))")

    // The strip's field: Enter evaluates; up and down go through what was evaluated.
    _ = await dbg("step({ by: 0 })")
    await setMarker(305)
    let field = await call("""
      const input = document.querySelector('#status-cycle .cmux-eval input');
      const result = document.querySelector('#status-cycle .cmux-eval .result');
      if (!input || !result) { return null; }
      const key = (k) => input.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true }));
      const enter = async (text) => {
        input.value = text;
        key('Enter');
        for (let i = 0; i < 40 && result.dataset.expr !== text; i++) { await new Promise((r) => setTimeout(r, 25)); }
        return result.textContent;
      };
      const first = await enter('data');
      const second = await enter('mode');
      input.value = '';
      key('ArrowUp');
      const up1 = input.value;
      key('ArrowUp');
      const up2 = input.value;
      key('ArrowDown');
      const down = input.value;
      key('ArrowDown');
      const back = input.value;
      return [first, second, up1, up2, down, back, input.placeholder];
    """) as? [String]
    expect(field == ["= 8'ha5 (width 8)", "= 2'h2 (width 2)", "mode", "data", "mode", "", "Evaluate"],
           "the field evaluates and keeps a history: \(String(describing: field))")

    // Watches: listed under the breakpoints, refreshed when the marker moves, changes marked.
    watchEvents.removeAll()
    await setMarker(295)
    _ = await dbg("addWatch({ expr: 'data' })")
    _ = await dbg("addWatch({ expr: 'state + 1' })")
    _ = await dbg("addWatch({ expr: 'data +' })")
    var rows = await watchRows(becoming: [["data", "8'h00", ""], ["state + 1", "32'h00000004", ""], ["data +", "Unexpected text (column 7)", ""]])
    expect(rows == [["data", "8'h00", ""], ["state + 1", "32'h00000004", ""], ["data +", "Unexpected text (column 7)", ""]],
           "watches listed with their values: \(rows)")
    _ = await dbg("step({ by: 1 })")
    rows = await watchRows(becoming: [["data", "8'ha5", "changed"], ["state + 1", "32'h00000004", ""], ["data +", "Unexpected text (column 7)", ""]])
    expect(rows.first == ["data", "8'ha5", "changed"] && rows.dropFirst().first == ["state + 1", "32'h00000004", ""],
           "a step refreshes them; the one that changed is marked: \(rows)")
    _ = await dbg("step({ by: 1 })")
    rows = await watchRows(becoming: [["data", "8'ha5", ""], ["state + 1", "32'h00000004", ""], ["data +", "Unexpected text (column 7)", ""]])
    expect(rows.first == ["data", "8'ha5", ""], "and unmarked when it stays: \(rows)")
    expect(watchEvents.last == ["data", "state + 1", "data +"], "cmux is told the watches: \(String(describing: watchEvents.last))")
    let ids = (await call("return cmuxWaveform.debugger.watches().map((w) => w.id)") as? [Int]) ?? []
    _ = await dbg("editWatch({ id: \(ids.last ?? -1), expr: 'data + 1' })")
    _ = await call("document.querySelectorAll('#cmux-watches .cmux-watch .remove')[1].click(); return null")
    rows = await watchRows(becoming: [["data", "8'ha5", ""], ["data + 1", "32'h000000a6", ""]])
    expect(rows == [["data", "8'ha5", ""], ["data + 1", "32'h000000a6", ""]], "edited and removed: \(rows)")
    // The strip's + adds what is in the field.
    _ = await call("""
      const input = document.querySelector('#status-cycle .cmux-eval input');
      input.value = 'irq';
      document.querySelector('#status-cycle .cmux-eval .add').click();
      return null
    """)
    rows = await watchRows(becoming: [["data", "8'ha5", ""], ["data + 1", "32'h000000a6", ""], ["irq", "1'b0", ""]])
    expect(rows.last == ["irq", "1'b0", ""], "the field's + adds a watch: \(rows)")
    // A signal row's menu adds it as a watch, by its path from the top.
    let added = await call("""
      const d = document.getElementById('viewer').contentDocument;
      const contexts = Array.from(d.querySelectorAll('[data-vscode-context]'))
        .map((el) => { try { return JSON.parse(el.getAttribute('data-vscode-context').replace(/%x20/g, ' ')); } catch (e) { return null; } })
        .filter((c) => c && c.webviewSection === 'signal' && c.netlistId !== undefined);
      const before = cmuxWaveform.debugger.watches().length;
      for (const c of contexts) {
        const item = window.cmuxDebugger.rowMenuItems(c).find((i) => i.label === 'Add Watch');
        if (!item) { return 'no Add Watch item'; }
        await item.run();
        break;
      }
      const list = cmuxWaveform.debugger.watches();
      return list.length === before + 1 ? list[list.length - 1].expr : 'count ' + list.length;
    """) as? String
    expect(added?.hasPrefix("top.") == true, "a row's Add Watch adds its path: \(String(describing: added))")
    // Evaluate from cmux (the editor's Evaluate at Cycle): shown in the strip's field and remembered.
    let shownEval = await call("""
      await cmuxWaveform.debugger.evaluate({ expr: 'state', scope: ['top'], show: true });
      const input = document.querySelector('#status-cycle .cmux-eval input');
      const result = document.querySelector('#status-cycle .cmux-eval .result');
      input.value = '';
      input.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowUp', bubbles: true, cancelable: true }));
      return [result.textContent, input.value];
    """) as? [String]
    expect(shownEval == ["= 4'h3 (width 4)", "state"], "an evaluation from cmux shows in the strip and its history: \(String(describing: shownEval))")
    // The palette's Evaluate Expression… and Add Watch… ask in the page.
    let prompted = await call("""
      const real = window.cmuxUI.prompt;
      const asked = [];
      window.cmuxUI.prompt = async (o) => { asked.push(o.title); return asked.length === 1 ? 'state' : 'mode + 0'; };
      try {
        const r = await cmuxWaveform.debugger.promptEvaluate();
        const w = await cmuxWaveform.debugger.promptAddWatch();
        window.cmuxUI.prompt = async () => undefined;
        const cancelled = await cmuxWaveform.debugger.promptAddWatch();
        return [asked.join('|'), r && r.value, w && w.expr, cancelled === null ? 'null' : String(cancelled),
          document.querySelector('#status-cycle .cmux-eval .result').textContent];
      } finally { window.cmuxUI.prompt = real; }
    """) as? [String]
    expect(prompted == ["Evaluate|Add Watch", "4'h3", "mode + 0", "null", "= 4'h3 (width 4)"], "the palette's prompts: \(String(describing: prompted))")
    _ = await call("const w = cmuxWaveform.debugger.watches(); cmuxWaveform.debugger.removeWatch({ id: w[w.length - 1].id }); return null")
    // A session's watches come back in place of the page's.
    _ = await dbg("restoreWatches({ items: ['mode', 'state'] })")
    rows = await watchRows(becoming: [["mode", "2'h2", ""], ["state", "4'h3", ""]])
    expect(rows == [["mode", "2'h2", ""], ["state", "4'h3", ""]], "restored: \(rows)")
    _ = await dbg("restoreWatches({ items: [] })")
    expect((await watchRows()).isEmpty, "none: the section is hidden")
    _ = await dbg("stop()")
  }

  /// Review of 42ef706: M4 (sized equals values zero-extend), M5 (no raw changes kept; line paths capped).
  func runReview42Checks() async {
    await removeAll()
    _ = await dbg("stop()")
    // M4: 4'b?1 on the 8-bit data is 0000???1: 'ha5 (305) and 'h5a (605) do not match.
    let sized = await add("data", "equals", value: "4'b?1")
    await setMarker(0)
    let none = await dbg("continue({ dir: 1 })")
    expect(sized != nil && none?["reason"] as? String == "end", "4'b?1 zero-extends (no hit on 'ha5): \(String(describing: none?["hit"]))")
    await removeAll()
    // 4'bx1 is 0000xxx1, not all x: no hit where data is all x (505).
    _ = await add("data", "equals", value: "4'bx1")
    await setMarker(0)
    let xs = await dbg("continue({ dir: 1 })")
    expect(xs?["reason"] as? String == "end", "4'bx1 zero-extends: \(String(describing: xs?["hit"]))")
    await removeAll()
    // A decimal x digit is a value (4'dx); unsized 'hx fills the width.
    expect(await add("data", "equals", value: "4'dx") != nil, "4'dx is accepted")
    await removeAll()
    _ = await add("data", "equals", value: "'hx")
    await setMarker(0)
    let allX = await go(1, expect: 5)
    expect(allX.hit?["landed"] as? Int == 5 || allX.hit?["landed"] as? Int == 505, "'hx matches the all-x data: \(String(describing: allX.hit))")
    await removeAll()

    // M5: once a search has its hit times, the signals' raw changes are let go.
    _ = await add("mode")
    _ = await add("state")
    await setMarker(0)
    _ = await dbg("continue({ dir: 1 })")
    let cached = await call("return cmuxWaveform.debugger.cacheSizes()") as? [String: Any]
    expect(cached?["changes"] as? Int == 0, "no raw changes kept after the search: \(String(describing: cached))")
    await removeAll()
    // A line breakpoint watches at most 64 signals, and its row says so.
    let many = (0..<100).map { _ in "['top', 'mode']" }.joined(separator: ", ")
    _ = await dbg("setLineBreakpoints({ items: [{ key: 'big', label: 'core.sv:9', paths: [\(many)], enabled: true }] })")
    let capped = await call("""
      const b = cmuxWaveform.debugger.breakpoints()[0];
      const row = document.querySelector('#cmux-breakpoints .cmux-breakpoint .label');
      return [b.paths.length, row ? row.title : ''];
    """) as? [Any]
    expect(capped?.first as? Int == 64 && (capped?.last as? String)?.contains("64 of 100") == true, "line paths capped at 64, said: \(String(describing: capped))")
    _ = await dbg("setLineBreakpoints({ items: [] })")
  }

  /// Conditional breakpoints: a hit counts only when its condition is true at the posedge it lands on.
  func runConditionChecks() async {
    await removeAll()
    await clearToasts()
    _ = await dbg("stop()")
    // mode changes at 105, 205, 305, 405; state is 3 at 105 and 305 (5 at 205, 0 at 405).
    let mode = await call("return (await cmuxWaveform.debugger.addBreakpoint({ path: ['top', 'mode'], kind: 'change', condition: 'state == 3' })).id") as? Int
    var shown = await list()
    expect(shown.first?["condition"] as? String == "state == 3" && shown.first?["label"] as? String == "top.mode changes if state == 3",
           "the condition is listed: \(shown)")
    await setMarker(0)
    var r = await go(1, expect: 105)
    expect(r.hit?["landed"] as? Int == 105 && r.marker == 105, "the first change with state == 3: \(String(describing: r.hit))")
    r = await go(1, expect: 305)
    expect(r.hit?["landed"] as? Int == 305 && r.marker == 305, "205 skipped (state is 5 there): \(String(describing: r.hit))")
    let end = await dbg("continue({ dir: 1 })")
    expect(end?["reason"] as? String == "end", "405 skipped (state is 0): the end: \(String(describing: end?["reason"]))")
    r = await go(-1, expect: 105)
    expect(r.hit?["landed"] as? Int == 105, "reverse finds the earlier true one: \(String(describing: r.hit))")
    // An absolute name works as well as one in the signal's scope.
    _ = await dbg("setBreakpointCondition({ id: \(mode ?? -1), condition: 'top.state == 5' })")
    await setMarker(0)
    r = await go(1, expect: 205)
    expect(r.hit?["landed"] as? Int == 205, "an absolute name: \(String(describing: r.hit))")
    // A bad condition is refused and the old one kept.
    let bad = await dbg("setBreakpointCondition({ id: \(mode ?? -1), condition: 'state +' })")
    let kept = (await list()).first?["condition"] as? String
    expect(bad?["error"] as? String == "syntax" && kept == "top.state == 5",
           "a syntax error is refused: \(String(describing: bad))")
    expect((await toasts()).contains { $0.contains("Unexpected text (column 8)") }, "and says why: \(await toasts())")
    // Cleared: every change hits again.
    _ = await dbg("setBreakpointCondition({ id: \(mode ?? -1), condition: '' })")
    shown = await list()
    expect(shown.first?["condition"] is NSNull && shown.first?["label"] as? String == "top.mode changes", "cleared: \(shown)")
    await setMarker(0)
    r = await go(1, expect: 105)
    expect(r.hit?["landed"] as? Int == 105, "unconditional again: \(String(describing: r.hit))")
    await removeAll()

    // At the landing posedge, not at the change: irq's pulse at 52..53 lands on 55 where irq is 0 again;
    // the pulse at 702..707 lands on 705 while irq is still 1.
    _ = await call("return (await cmuxWaveform.debugger.addBreakpoint({ path: ['top', 'irq'], kind: 'change', condition: 'irq' })).id")
    await setMarker(0)
    r = await go(1, expect: 705)
    expect(r.hit?["landed"] as? Int == 705, "evaluated at the landing posedge: \(String(describing: r.hit))")
    await removeAll()

    // x is not true: data is 'ha5 at 305, x at 505.
    _ = await call("return (await cmuxWaveform.debugger.addBreakpoint({ path: ['top', 'data'], kind: 'change', condition: \"data == 8'ha5 || data === 8'bx\" })).id")
    await setMarker(0)
    r = await go(1, expect: 305)
    expect(r.hit?["landed"] as? Int == 305, "data == 'ha5: \(String(describing: r.hit))")
    r = await go(1, expect: 505)
    expect(r.hit?["landed"] as? Int == 505, "=== matches x exactly: \(String(describing: r.hit))")
    _ = await dbg("setBreakpointCondition({ id: (cmuxWaveform.debugger.breakpoints()[0] || {}).id, condition: 'data == 0 && data != 0' })")
    await setMarker(0)
    let never = await dbg("continue({ dir: 1 })")
    expect(never?["reason"] as? String == "end", "never true: no hit: \(String(describing: never?["reason"]))")
    await removeAll()

    // A name not in the waveform: said once, and the breakpoint does not hit.
    await clearToasts()
    _ = await call("return (await cmuxWaveform.debugger.addBreakpoint({ path: ['top', 'mode'], kind: 'change', condition: 'nope == 1' })).id")
    await setMarker(0)
    let unknown = await dbg("continue({ dir: 1 })")
    _ = await dbg("continue({ dir: 1 })")
    let unknownToasts = (await toasts()).filter { $0.contains("nope is not in this waveform") }
    expect(unknown?["hit"] is NSNull && unknownToasts.count == 1, "an unknown name: no hit, said once: \(String(describing: unknown?["reason"])) \(unknownToasts)")
    await removeAll()

    // Kept for the session, and restored.
    listEvents.removeAll()
    _ = await call("return (await cmuxWaveform.debugger.addBreakpoint({ path: ['top', 'mode'], kind: 'change', condition: 'state == 3' })).id")
    expect(listEvents.last?.first?["condition"] as? String == "state == 3", "cmux is told the condition: \(String(describing: listEvents.last))")
    _ = await dbg("restoreBreakpoints({ items: [{ path: ['top', 'mode'], kind: 'change', enabled: true, condition: 'state == 5' }] })")
    shown = await list()
    expect(shown.count == 1 && shown.first?["condition"] as? String == "state == 5", "restored with its condition: \(shown)")
    await setMarker(0)
    r = await go(1, expect: 205)
    expect(r.hit?["landed"] as? Int == 205, "the restored condition applies: \(String(describing: r.hit))")
    // The same signal with another condition is another breakpoint.
    _ = await call("return (await cmuxWaveform.debugger.addBreakpoint({ path: ['top', 'mode'], kind: 'change', condition: 'state == 3' })).id")
    expect((await list()).count == 2, "another condition, another breakpoint")

    // The list row's menu edits the condition.
    let menu = await call("""
      const row = document.querySelector('#cmux-breakpoints .cmux-breakpoint');
      if (!row) { return null; }
      row.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 20, clientY: 20 }));
      const labels = Array.from(document.querySelectorAll('.cmux-menu-item .label')).map((l) => l.textContent);
      window.cmuxUI.closeMenus();
      return labels;
    """) as? [String]
    expect(menu?.contains("Edit Condition…") == true, "the list row's menu: \(String(describing: menu))")
    await removeAll()

    // A line breakpoint's condition (cmux sends it with the line), in the line's instance.
    _ = await dbg("setLineBreakpoints({ items: [{ key: 'core.sv#3', label: 'core.sv:3', paths: [['top', 'mode']], enabled: true, condition: 'state == 5', scope: ['top'] }] })")
    await setMarker(0)
    r = await go(1, expect: 205)
    expect(r.hit?["landed"] as? Int == 205, "a line breakpoint's condition: \(String(describing: r.hit))")
    shown = await list()
    expect(shown.first?["label"] as? String == "core.sv:3 if state == 5", "listed with it: \(shown)")
    _ = await dbg("setLineBreakpoints({ items: [] })")
    _ = await dbg("stop()")
  }

  /// Line breakpoints (cmux sends them: the editor's gutter and F9): any of the line's signals changing hits.
  func runLineChecks() async {
    _ = await call("for (const b of cmuxWaveform.debugger.breakpoints()) { cmuxWaveform.debugger.removeBreakpoint({ id: b.id }); } return null")
    _ = await call("""
      return cmuxWaveform.debugger.setLineBreakpoints({ items: [
        { key: 'core.sv:4', label: 'core.sv:4', paths: [['top', 'state'], ['top', 'irq']], enabled: true },
        { key: 'core.sv:9', label: 'core.sv:9', paths: [], enabled: true },
      ] })
    """)
    let listed = await list()
    expect(listed.map { $0["kind"] as? String } == ["line", "line"] && listed.first?["key"] as? String == "core.sv:4"
           && listed.first?["label"] as? String == "core.sv:4", "line breakpoints listed: \(listed)")
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    var hits: [Int] = []
    for expected in [55, 95, 195] {
      let (hit, _) = await go(1, expect: expected)
      hits.append(hit?["landed"] as? Int ?? -1)
    }
    expect(hits == [55, 95, 195], "a line hits when any of its signals changes (irq, then state): \(hits)")
    let (back, _) = await go(-1, expect: 95)
    expect(back?["landed"] as? Int == 95, "and in reverse: \(String(describing: back))")
    let message = await toasts()
    expect(message.contains { $0.hasPrefix("Breakpoint: core.sv:4 at ") }, "the hit names the line: \(message)")
    let unplaced = await call("""
      const rows = Array.from(document.querySelectorAll('#cmux-breakpoints .cmux-breakpoint'));
      return rows.map((r) => r.querySelector('.label').title);
    """) as? [String]
    expect(unplaced?.last?.contains("not placed") == true, "a line with no signals in the waveform says so: \(String(describing: unplaced))")
    // The list's checkbox and remove button tell cmux, which owns line breakpoints.
    lineEvents.removeAll()
    _ = await call("document.querySelector('#cmux-breakpoints .cmux-breakpoint input').click(); return null")
    _ = await call("document.querySelectorAll('#cmux-breakpoints .cmux-breakpoint .remove')[1].click(); return null")
    await sleep(100)
    let told = lineEvents.map { "\($0["key"] as? String ?? "?"):\($0["enabled"] as? Bool ?? true):\($0["removed"] as? Bool ?? false)" }
    expect(told == ["core.sv:4:false:false", "core.sv:9:true:true"], "cmux is told: \(told)")
    expect((await list()).map { $0["enabled"] as? Bool } == [false], "and the page shows it: \(await list())")
    // A new set replaces the lines, and leaves signal breakpoints alone.
    _ = await call("return cmuxWaveform.debugger.addBreakpoint({ path: ['top', 'busy'], kind: 'change' })")
    _ = await call("return cmuxWaveform.debugger.setLineBreakpoints({ items: [{ key: 'core.sv:5', label: 'core.sv:5', paths: [['top', 'data']], enabled: true }] })")
    let replaced = (await list()).map { ($0["kind"] as? String ?? "") + ":" + ($0["label"] as? String ?? "") }
    expect(replaced == ["change:top.busy changes", "line:core.sv:5"], "lines replaced, the signal breakpoint kept: \(replaced)")
    await runRestoreChecks()
  }

  /// cmux keeps the signal breakpoints for the session: the page says when they change, and a
  /// new page gets them back (restoreBreakpoints) before its file is open.
  func runRestoreChecks() async {
    let last = listEvents.last ?? []
    let told = last.map { "\(($0["path"] as? [String] ?? []).joined(separator: ".")):\($0["kind"] as? String ?? ""):\($0["enabled"] as? Bool ?? false)" }
    expect(told == ["top.busy:change:true"], "the page tells cmux its signal breakpoints (not the lines): \(told)")
    _ = await call("""
      return cmuxWaveform.debugger.restoreBreakpoints({ items: [
        { path: ['top', 'data'], kind: 'equals', value: "'h5a", enabled: true },
        { path: ['top', 'state'], kind: 'change', enabled: false },
        { path: ['top', 'gone'], kind: 'change', enabled: true },
      ] })
    """)
    let restored = (await list()).map { ($0["label"] as? String ?? "") + ":" + String(describing: $0["enabled"] as? Bool ?? false) }
    expect(restored == ["top.data == 'h5a:true", "top.state changes:false", "top.gone changes:true", "core.sv:5:true"],
           "restored in place of the signal breakpoints, lines kept: \(restored)")
    _ = await call("""
      for (const b of cmuxWaveform.debugger.breakpoints()) {
        cmuxWaveform.debugger.setBreakpointEnabled({ id: b.id, enabled: b.label === "top.data == 'h5a" || b.label === 'top.gone changes' });
      }
      return null
    """)
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    await clearToasts()
    let (hit, _) = await go(1, expect: 605)
    expect(hit?["time"] as? Int == 605, "a restored equals breakpoint searches: \(String(describing: hit))")
    expect(await toasts().contains("top.gone is not in this waveform."), "a restored one whose signal is gone says so when searched: \(await toasts())")
    await clearToasts()
    _ = await dbg("continue({ dir: -1 })")
    expect(!(await toasts()).contains("top.gone is not in this waveform."), "once, not on every continue: \(await toasts())")

    // A reload clears the hit mark, and reads an equals value again for the signal's new width
    // (top.data is 16 bits in breakpoints-wide.vcd).
    _ = await go(1, expect: 605)
    let wide = waveURL.deletingLastPathComponent().appendingPathComponent("breakpoints-wide.vcd")
    let wideURL = scheme.serve(fileURL: wide)
    let wideSize = (try? FileManager.default.attributesOfItem(atPath: wide.path)[.size] as? NSNumber)?.intValue ?? 0
    let opened = openedCount
    _ = await call("cmuxWaveform.reload({ url: '\(wideURL.absoluteString)', size: \(wideSize) }); return null")
    for _ in 0..<100 where openedCount == opened { await sleep(50) }
    expect(openedCount > opened, "reloaded with the wide dump")
    expect((await list()).allSatisfy { $0["hit"] as? Bool == false }, "a reload clears the hit mark: \(await list())")
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    let (wideHit, _) = await go(1, expect: 605)
    expect(wideHit?["time"] as? Int == 605, "'h5a found in the 16-bit data: \(String(describing: wideHit))")
  }

  func start() {
    let cfg = WKWebViewConfiguration()
    cfg.setURLSchemeHandler(scheme, forURLScheme: WaveformViewerSchemeHandler.scheme)
    let hook = """
    (function(){ for (const k of ['warn','error']) { const o = console[k];
      console[k] = (...a) => { try { webkit.messageHandlers.console.postMessage(k + ': ' + a.map((x) => (x && x.stack ? String(x) + ' ' + x.stack : String(x))).join(' ')); } catch(e){}; o.apply(console, a); }; }
      window.addEventListener('error', e => webkit.messageHandlers.console.postMessage('onerror: ' + e.message + ' @' + e.filename + ':' + e.lineno + ':' + e.colno + ' ' + (e.error && e.error.stack)));
    })();
    """
    cfg.userContentController.addUserScript(WKUserScript(source: hook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    cfg.userContentController.add(self, name: "console")
    cfg.userContentController.add(self, name: "cmuxWaveform")
    web = WKWebView(frame: window.contentView!.bounds, configuration: cfg)
    web.navigationDelegate = self
    window.contentView!.addSubview(web)
    // Keep the harness invisible to the user: off-screen, transparent, click-through.
    window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    web.load(URLRequest(url: WaveformViewerSchemeHandler.indexURL))
  }

  var checksStarted = false

  func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
    guard m.name == "cmuxWaveform", let body = m.body as? [String: Any], let type = body["type"] as? String else {
      print("[\(m.name)]", m.body)
      return
    }
    if type == "debugger", body["event"] as? String == "lineBreakpoint" { lineEvents.append(body); return }
    if type == "debugger", body["event"] as? String == "breakpoints" { listEvents.append(body["items"] as? [[String: Any]] ?? []); return }
    if type == "debugger", body["event"] as? String == "moved" { movedEvents.append(body); return }
    if type == "debugger", body["event"] as? String == "watches" { watchEvents.append(body["items"] as? [String] ?? []); return }
    if ["debugger", "event", "sessionState", "log", "keyState", "context", "signalData"].contains(type) { return }
    print("[\(m.name)]", type)
    if type == "ready" {
      let fileURL = scheme.serve(fileURL: waveURL)
      let size = (try? FileManager.default.attributesOfItem(atPath: waveURL.path)[.size] as? NSNumber)?.intValue ?? 0
      let theme = "{kind:'dark', background:'#1e1e2e', foreground:'#cdd6f4'}"
      web.evaluateJavaScript("cmuxWaveform.setTheme(\(theme)); cmuxWaveform.open({url:'\(fileURL.absoluteString)', size:\(size), format:'vcd', strings:\(Harness.strings)})")
    } else if type == "opened" {
      openedCount += 1
      guard !checksStarted else { return }
      checksStarted = true
      Task { @MainActor in await self.runChecks() }
    } else if type == "error" {
      print("ERROR", body["message"] ?? "")
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.snap() }
    }
  }

  /// The English strings cmux gives the page (WaveformDebugger.pageStrings).
  static let strings = """
  {netlist:'Netlist', loading:'Loading…', openFailed:'Could not open', addSignal:'Add', debuggerLocals:'Locals',
   debuggerCycle:'Cycle %1$@ of %2$@ · %3$@', debuggerRate:'%@ cycles/s',
   debuggerBreakpoints:'Breakpoints', debuggerBreakWhenChanges:'Break When Changes', debuggerBreakWhenEquals:'Break When Equals…',
   debuggerBreakEqualsPrompt:'Break when %@ equals', debuggerBreakEqualsPlaceholder:"For example 'h3f, 8'b1010_??01, 12 or x",
   debuggerBreakpointChanges:'%@ changes', debuggerBreakpointEquals:'%1$@ == %2$@', debuggerRemoveBreakpoint:'Remove',
   debuggerBreakpointHit:'Breakpoint: %1$@ at %2$@ (cycle %3$@)', debuggerNoHitForward:'No breakpoint hit before the end.',
   debuggerNoHitBack:'No breakpoint hit before the start.', debuggerNoBreakpoints:'No breakpoints are enabled.',
   debuggerBadValue:'“%1$@” is not a value for a %2$@-bit signal.', debuggerTooManyChanges:'%@ changes too often to search here.',
   debuggerBreakpointSignalGone:'%@ is not in this waveform.',
   debuggerHitAfterLastEdge:'Breakpoint: %1$@ at %2$@, after the last clock edge.',
   debuggerNoEdges:'The clock never rises.', debuggerNoClock:'No clock.',
   debuggerEvaluate:'Evaluate', debuggerEvaluateTooltip:'An expression at the marker', debuggerEvalResult:'= %1$@ (width %2$@)',
   debuggerEvalTooltip:'Binary %1$@, decimal %2$@', debuggerAddWatch:'Add Watch', debuggerWatch:'Watch',
   debuggerRemoveWatch:'Remove Watch', debuggerEditWatch:'Edit Watch', debuggerExprError:'%1$@ (column %2$@)',
   debuggerExprSyntax:'Unexpected text', debuggerExprUnsupported:'Not supported here', debuggerExprEmpty:'Nothing to evaluate',
   debuggerExprTooLong:'Longer than %@ characters', debuggerExprTooManySignals:'More than %@ signals',
   debuggerExprTooWide:'Wider than %@ bits', debuggerExprBadLiteral:'Not a valid literal', debuggerExprNotConstant:'Must be a constant',
   debuggerExprBadReplication:'A replication count must be at least 1', debuggerExprUnknownName:'%@ is not in this waveform',
   debuggerExprNoValue:'%@ has no value at the marker', debuggerExprNoMarker:'Put the marker on a cycle first.',
   debuggerBreakpointIf:'%1$@ if %2$@', debuggerEditCondition:'Edit Condition…', debuggerConditionPrompt:'Break only when this is true at the clock edge',
   debuggerConditionError:'Condition of %1$@: %2$@', debuggerLinePathsCapped:'%1$@: watching the first %2$@ of %3$@ signals',
   debuggerLineNotPlaced:'%@: none of its signals are in the waveform (not placed in the design yet).'}
  """

  func snap() {
    web.takeSnapshot(with: nil) { img, err in
      if let img = img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
         let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: out)
        print("wrote", out.path)
      } else { print("snapshot failed", String(describing: err)) }
      exit(failures == 0 ? 0 : 1)
    }
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let h = MainActor.assumeIsolated { Harness() }
MainActor.assumeIsolated { h.start() }
DispatchQueue.main.asyncAfter(deadline: .now() + 120) { print("timeout"); exit(1) }
app.run()
