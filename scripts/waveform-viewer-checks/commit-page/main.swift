// Commit breakpoint checks in the viewer (run.sh commit-page): loads Resources/vaporview through the
// real WaveformViewerSchemeHandler in an off-screen WKWebView, opens text-breakpoints.vcd (its clock),
// gives the page a mock commit index (as cmux-machine.js's window.cmuxWaveform.commits would) and drives
// window.cmuxWaveform.debugger's pc, commitText and write breakpoints as the menus would: continue both
// ways, several commits in one cycle, conditions, the Machine section's commit after a hit, the list and
// its menu, View > Waveform Debugger > Add Instruction Breakpoint…'s menu and prompts, saving and
// restoring, caps, refusals, and a dump with no commit stream.
// Usage: commit-page <assetRoot> <text-breakpoints.vcd> <out.png>
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
  var pcEvents: [[String: Any]] = []
  var commitPcEvents: [[String: Any]] = []
  var readyEvents = 0
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

  /// Adds a text breakpoint on top.<signal>; its id (nil: refused).
  func addText(_ signal: String, _ format: String, _ pattern: String, extra: String = "") async -> Int? {
    let js = "return cmuxWaveform.debugger.addBreakpoint({ path: ['top', '\(signal)'], kind: 'text', format: '\(format)', pattern: \(Harness.js(pattern))\(extra) })"
    return (await call(js) as? [String: Any])?["id"] as? Int
  }

  static func js(_ s: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [s])
    let text = String(data: data, encoding: .utf8)!
    return String(text.dropFirst().dropLast())
  }

  func only(_ id: Int?) async {
    _ = await call("""
      for (const b of cmuxWaveform.debugger.breakpoints()) {
        cmuxWaveform.debugger.setBreakpointEnabled({ id: b.id, enabled: b.id === \(id ?? -1) });
      }
      return null
    """)
  }

  /// From the first posedge, every landing forward until the end; then every landing back.
  func landings(_ id: Int?) async -> (forward: [Int], back: [Int]) {
    await only(id)
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    var forward: [Int] = []
    for _ in 0..<20 {
      let r = await dbg("continue({ dir: 1 })")
      guard let hit = r?["hit"] as? [String: Any], let landed = hit["landed"] as? Int else { break }
      forward.append(landed)
      _ = await marker(landed)
    }
    var back: [Int] = []
    for _ in 0..<20 {
      let r = await dbg("continue({ dir: -1 })")
      guard let hit = r?["hit"] as? [String: Any], let landed = hit["landed"] as? Int else { break }
      back.append(landed)
      _ = await marker(landed)
    }
    return (forward, back)
  }

  func addCommit(_ fields: String) async -> Int? {
    (await call("return cmuxWaveform.debugger.addBreakpoint({ \(fields) })") as? [String: Any])?["id"] as? Int
  }

  func rowMenu(_ containing: String, run: String? = nil) async -> [String]? {
    await call("""
      const shown = [];
      const real = window.cmuxUI.showMenu;
      window.cmuxUI.showMenu = (items) => { shown.push(items); };
      const rows = Array.from(document.querySelectorAll('#cmux-breakpoints .cmux-breakpoint'));
      const row = rows.find((r) => r.querySelector('.label').textContent.includes(\(Harness.js(containing))));
      row.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, clientX: 5, clientY: 5 }));
      window.cmuxUI.showMenu = real;
      const items = shown[0] || [];
      const want = \(run.map(Harness.js) ?? "null");
      if (want) { await items.find((i) => i.label === want).run(); }
      return items.map((i) => i.label);
    """) as? [String]
  }

  func runChecks() async {
    // The mock index: commits on posedges (5, 15, ...); two share the cycle at 25 (channels 0 and 1).
    // k: time pc insn channel. Writes: a0 by k0, [0x1000] by k5, mtvec by k2.
    _ = await call("""
      const rows = [[15, 0x80000000, 0x00000513, 0], [25, 0x80000004, 0x008002ef, 0], [25, 0x80000008, 0x30531073, 1],
        [35, 0x80000004, 0x008002ef, 0], [45, 0x80000004, 0x008002ef, 0], [65, 0x80000010, 0x0005a683, 0], [85, 0x80000004, 0x008002ef, 0]];
      const index = { backend: 1, count: rows.length, nret: 2, xlen: 32, sortedBy: 'time',
        time: Float64Array.from(rows.map((r) => r[0])), edge: Int32Array.from(rows.map((r) => (r[0] - 5) / 10)),
        channel: Uint8Array.from(rows.map((r) => r[3])), pc: Float64Array.from(rows.map((r) => r[1])),
        insn: Uint32Array.from(rows.map((r) => r[2])), order: null };
      const writes = { a0: [0], 'csr:mtvec': [2], 'mem:4096': [5] };
      window.__commitIndex = index;
      window.__wentTo = [];
      window.__commitListeners = [];
      Object.defineProperty(cmuxWaveform, 'commits', { configurable: true, value: {
        index: async () => window.__commitIndex,
        current: () => window.__commitIndex,
        currentK: () => null,
        onChange: (fn) => { window.__commitListeners.push(fn); return () => {}; },
        writesOf: async (q) => (writes[typeof q.loc === 'string' ? q.loc : (q.loc.csr ? 'csr:' + q.loc.csr : 'mem:' + q.loc.addr)] || []).slice(),
      } });
      Object.defineProperty(cmuxWaveform, 'machine', { configurable: true, value: { goToCommit: (q) => { window.__wentTo.push(q.k); } } });
      return null
    """)

    // PC: every commit there; one landing per cycle.
    let pc = await addCommit("kind: 'pc', pcs: ['0x80000004']")
    expect(pc != nil, "a PC breakpoint is added")
    var l = await landings(pc)
    expect(l.forward == [25, 35, 45, 85], "pc 0x80000004 forward from 5: \(l.forward)")
    expect(l.back == [45, 35, 25], "and back: \(l.back)")
    let label = (await list()).first { $0["id"] as? Int == pc }
    expect(label?["label"] as? String == "PC 0x80000004" && label?["pcs"] as? [String] == ["0x80000004"] && label?["kind"] as? String == "pc",
           "its label and fields: \(String(describing: label))")
    await clearToasts()
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    _ = await call("window.__wentTo.length = 0; return null")
    _ = await dbg("continue({ dir: 1 })")
    expect(await toasts().contains("Breakpoint: PC 0x80000004 at 25 ns (cycle 3)"), "the hit is said: \(await toasts())")
    let went = await call("return window.__wentTo.slice()") as? [Int]
    expect(went == [1], "the Machine section goes to the commit that hit: \(String(describing: went))")

    // A condition, tested at the landing posedge (flag is high only at 35), its names looked up in
    // the commit source's instance (the index's scope, here top), then from the top.
    _ = await call("window.__commitIndex.scope = ['top']; return null")
    let cond = await addCommit("kind: 'pc', pcs: ['0x80000004'], condition: 'flag'")
    l = await landings(cond)
    expect(l.forward == [35] && l.back.isEmpty, "pc if flag: only 35: \(l)")
    let pinned = await addCommit("kind: 'pc', pcs: ['0x80000008'], channel: 1")
    l = await landings(pinned)
    expect(l.forward == [25], "pinned to channel 1: \(l.forward)")

    // Instruction text: the second commit of the shared cycle is the one gone to.
    let csrw = await addCommit("kind: 'commitText', pattern: 'csrw mtvec'")
    _ = await call("window.__wentTo.length = 0; return null")
    l = await landings(csrw)
    expect(l.forward == [25] && l.back.isEmpty, "commitText csrw mtvec: \(l)")
    let wentText = await call("return window.__wentTo.slice()") as? [Int]
    expect(wentText == [2], "to the commit that matched, not the cycle's first: \(String(describing: wentText))")
    let jal = await addCommit("kind: 'commitText', pattern: 'jal x5'")
    l = await landings(jal)
    expect(l.forward == [25, 35, 45, 85], "jal x5 matches jal t0 (either register name): \(l.forward)")
    let jalMenu = await rowMenu("jal x5", run: "✓ Match Either Register Name (a0 or x10)")
    expect(jalMenu == ["Edit Pattern…", "Match Case", "✓ Match Either Register Name (a0 or x10)", "Break at Address…",
                       "Break When Next Instruction Matches…", "Break When Written…", "Edit Condition…", "Remove"],
           "the list row's menu: \(String(describing: jalMenu))")
    l = await landings(jal)
    expect(l.forward.isEmpty, "and its register-name item turned it off: \(l.forward)")

    // Writes: a register, memory (a word: any of its bytes), a CSR.
    for (loc, want) in [("a0", [15]), ("mem:0x1000/4", [65]), ("csr:mtvec", [25])] {
      let w = await addCommit("kind: 'write', loc: '\(loc)'")
      l = await landings(w)
      expect(l.forward == want, "\(loc) written: \(l.forward)")
    }
    let wlabels = (await list()).filter { $0["kind"] as? String == "write" }.map { $0["label"] as? String ?? "" }
    expect(wlabels == ["a0 written", "[0x1000] written", "mtvec written"], "their labels: \(wlabels)")

    // Add Instruction Breakpoint… (View > Waveform Debugger): a menu of the three, each a prompt.
    let chooser = await call("""
      const shown = [];
      const real = window.cmuxUI.showMenu;
      window.cmuxUI.showMenu = (items) => { shown.push(items); };
      const ok = cmuxWaveform.debugger.chooseCommitBreakpoint();
      window.cmuxUI.showMenu = real;
      const realPrompt = window.cmuxUI.prompt;
      const asked = [];
      const answers = ['80000010', 'lw a3', '[0x1000]/1'];
      window.cmuxUI.prompt = async (o) => { asked.push([o.title, o.placeholder]); return answers[asked.length - 1]; };
      for (const item of shown[0]) { await item.run(); }
      window.cmuxUI.prompt = realPrompt;
      return { ok, labels: shown[0].map((i) => i.label), asked };
    """) as? [String: Any]
    expect(chooser?["ok"] as? Bool == true && chooser?["labels"] as? [String] == ["Break at Address…", "Break When Next Instruction Matches…", "Break When Written…"],
           "the menu: \(String(describing: chooser))")
    let asked = chooser?["asked"] as? [[String]]
    expect(asked?.map { $0[0] } == ["Break when an instruction at this address commits", "Break when a committed instruction's text matches",
                                     "Break when an instruction writes this register, CSR or memory"], "its prompts: \(String(describing: asked))")
    let made = (await list()).suffix(3)
    expect(made.map { $0["label"] as? String ?? "" } == ["PC 0x80000010", "Next instruction ~ /lw a3/", "[0x1000]/1 written"],
           "what they made: \(made.map { $0["label"] ?? "" })")
    for (bp, want) in zip(made, [[65], [65], [65]]) {
      l = await landings(bp["id"] as? Int)
      expect(l.forward == want, "\(bp["label"] ?? "") hits: \(l.forward)")
    }

    // Edit Address… on its row.
    _ = await call("window.__realPrompt = window.cmuxUI.prompt; window.cmuxUI.prompt = async () => '0x80000000, 0x80000010'; return null")
    _ = await rowMenu("PC 0x80000010", run: "Edit Address…")
    _ = await call("window.cmuxUI.prompt = window.__realPrompt; return null")
    let edited = (await list()).first { ($0["label"] as? String)?.hasPrefix("PC 0x80000000") == true }
    expect(edited?["pcs"] as? [String] == ["0x80000000", "0x80000010"], "Edit Address… changes it: \(String(describing: edited))")
    l = await landings(edited?["id"] as? Int)
    expect(l.forward == [15, 65], "and it hits at both: \(l.forward)")

    // What cmux is told (and saves), and a restore of it.
    let told = listEvents.last ?? []
    let toldPc = told.first { $0["kind"] as? String == "pc" && $0["channel"] as? Int == 1 }
    let toldW = told.first { $0["kind"] as? String == "write" && $0["loc"] as? String == "mem:0x1000/4" }
    let toldT = told.first { $0["kind"] as? String == "commitText" && $0["pattern"] as? String == "jal x5" }
    expect(toldPc?["pcs"] as? [String] == ["0x80000008"] && (toldPc?["path"] as? [String])?.isEmpty == true && toldW != nil
           && toldT?["anyRegisterNames"] as? Bool == false, "cmux is told their fields: \(told.filter { $0["kind"] as? String != "text" })")
    let restored = await call("""
      return cmuxWaveform.debugger.restoreBreakpoints({ items: [
        { path: [], kind: 'pc', pcs: ['0x80000004'], enabled: true, condition: 'top.flag' },
        { path: [], kind: 'commitText', pattern: 'csrw', enabled: false },
        { path: [], kind: 'write', loc: 'csr:mtvec', enabled: true },
        { path: [], kind: 'pc', pcs: ['main'], enabled: true },
        { path: ['top', 'inst'], kind: 'change', enabled: false }] }).map((b) => b.label);
    """) as? [String]
    expect(restored == ["PC 0x80000004 if top.flag", "Next instruction ~ /csrw/", "mtvec written", "top.inst changes"],
           "restored (a bad one dropped): \(String(describing: restored))")
    let restoredPc = (await list()).first { $0["kind"] as? String == "pc" }?["id"] as? Int
    l = await landings(restoredPc)
    expect(l.forward == [35], "the restored one hits with its condition: \(l.forward)")

    // Refusals: a bad address or location, an empty pattern, too many enabled.
    await clearToasts()
    let bad = await addCommit("kind: 'pc', pcs: ['main']")
    let badLoc = await addCommit("kind: 'write', loc: 'x99'")
    let noPattern = await addCommit("kind: 'commitText', pattern: ''")
    expect(bad == nil && badLoc == nil && noPattern == nil, "bad ones are refused")
    let said = await toasts()
    expect(said.contains("Breakpoint PC main: an address is a hex number of up to 16 digits")
           && said.contains("Breakpoint x99 written: give a register (a0, x5), a CSR (mstatus) or memory ([0x80001000])")
           && said.contains("Breakpoint Next instruction ~ //: the pattern is empty"), "and say why: \(said)")
    await clearToasts()
    for n in 0..<40 { _ = await addCommit("kind: 'commitText', pattern: 'nope\(n)'") }
    let enabled = (await list()).filter { $0["kind"] as? String == "commitText" && $0["enabled"] as? Bool == true }.count
    expect(enabled == 32, "at most 32 enabled instruction-text breakpoints: \(enabled)")
    expect(await toasts().contains("At most 32 breakpoints of this kind can be enabled"), "said: \(await toasts())")
    _ = await call("for (const b of cmuxWaveform.debugger.breakpoints()) { if (/nope/.test(b.pattern || '')) { cmuxWaveform.debugger.removeBreakpoint({ id: b.id }); } } return null")

    // No commit stream: no hit, and why.
    _ = await call("window.__savedIndex = window.__commitIndex; window.__commitIndex = null; return null")
    await clearToasts()
    l = await landings(restoredPc)
    expect(l.forward.isEmpty, "no commit stream: no hit: \(l.forward)")
    expect(await toasts().contains("PC 0x80000004: this dump has no commit stream (RVFI or similar) to search"), "and says so: \(await toasts())")

    // ---- listings (cmux owns their pc breakpoints, keyed by mark) ----
    _ = await call("window.__commitIndex = window.__savedIndex || window.__commitIndex; return null")
    _ = await call("""
      return cmuxWaveform.debugger.setPcBreakpoints({ items: [
        { key: 'K1', listingLabel: 'prog.dis: _start+0x4', pcs: ['0x80000004'], enabled: true },
        { key: 'K2', listingLabel: 'prog.dis: sum', pcs: ['0x80000010'], enabled: false, condition: 'top.flag' },
        { key: '', listingLabel: 'no key', pcs: ['0x80000010'], enabled: true },
        { key: 'K3', listingLabel: 'bad', pcs: ['main'], enabled: true }] }).map((b) => b.label);
    """)
    var listed = (await list()).filter { $0["key"] as? String != nil }
    expect(listed.map { $0["label"] as? String ?? "" } == ["prog.dis: _start+0x4 (0x80000004)", "prog.dis: sum (0x80000010) if top.flag"],
           "a listing's breakpoints in the list (no key or a bad address: none): \(listed.map { $0["label"] ?? "" })")
    let k1 = listed.first?["id"] as? Int
    l = await landings(k1)
    expect(l.forward == [25, 35, 45, 85], "a listing's breakpoint hits: \(l.forward)")
    let toldKeys = (listEvents.last ?? []).filter { $0["kind"] as? String == "pc" && $0["key"] != nil && !($0["key"] is NSNull) }
    expect(toldKeys.isEmpty, "cmux keeps them itself (not in the page's saved list): \(toldKeys)")
    // The list's checkbox, condition and remove tell cmux.
    pcEvents.removeAll()
    _ = await call("cmuxWaveform.debugger.setBreakpointEnabled({ id: \(k1 ?? -1), enabled: false }); return null")
    _ = await call("cmuxWaveform.debugger.setBreakpointCondition({ id: \(k1 ?? -1), condition: 'top.flag' }); return null")
    _ = await call("cmuxWaveform.debugger.removeBreakpoint({ id: \(k1 ?? -1) }); return null")
    expect(pcEvents.map { [$0["key"] as? String ?? "", "\($0["enabled"] ?? "-")", "\($0["condition"] ?? "-")", "\($0["removed"] ?? "-")"] }
           == [["K1", "0", "-", "0"], ["K1", "0", "top.flag", "0"], ["K1", "0", "-", "1"]],
           "cmux is told: \(pcEvents)")
    _ = await call("cmuxWaveform.debugger.setPcBreakpoints({ items: [{ key: 'K4', listingLabel: 'x', pcs: ['0x80000004'], enabled: true, condition: '((' }] }); return null")
    expect(pcEvents.last?["key"] as? String == "K4" && pcEvents.last?["conditionError"] as? Bool == true, "a condition that does not parse is told: \(String(describing: pcEvents.last))")
    // Restoring the page's own list keeps cmux's; setting cmux's keeps the page's.
    let pageMade = await addCommit("kind: 'pc', pcs: ['0x80000010']")
    _ = await call("cmuxWaveform.debugger.restoreBreakpoints({ items: [{ path: [], kind: 'write', loc: 'a0', enabled: true }] }); return null")
    listed = await list()
    expect(listed.contains { $0["key"] as? String == "K4" } && listed.contains { $0["label"] as? String == "a0 written" }
           && !listed.contains { $0["id"] as? Int == pageMade }, "restore keeps the listing's: \(listed.map { $0["label"] ?? "" })")
    _ = await addCommit("kind: 'pc', pcs: ['0x80000010']")
    _ = await call("cmuxWaveform.debugger.setPcBreakpoints({ items: [] }); return null")
    listed = await list()
    expect(!listed.contains { $0["key"] as? String == "K4" } && listed.contains { $0["label"] as? String == "PC 0x80000010" },
           "setting the listing's keeps the page's: \(listed.map { $0["label"] ?? "" })")

    // Run to a PC's next or previous commit (a listing's gutter menu): no breakpoint is added.
    let before = (await list()).count
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    var runs: [Int] = []
    for dir in [1, 1, -1] {
      let r = await dbg("runToPc({ pcs: ['0x80000004'], dir: \(dir) })")
      runs.append(((r?["hit"] as? [String: Any])?["landed"] as? Int) ?? -1)
      _ = await marker(runs.last)
    }
    expect(runs == [25, 35, 25], "run to 0x80000004: next, next, previous: \(runs)")
    let none = await dbg("runToPc({ pcs: ['0x90000000'], dir: 1 })")
    expect(none?["reason"] as? String == "end" && (await list()).count == before, "never committed: the end, and the list is as it was")

    // The commits at the marker go to the listings while debugging; none after Stop.
    commitPcEvents.removeAll()
    _ = await call("for (const b of cmuxWaveform.debugger.breakpoints()) { cmuxWaveform.debugger.removeBreakpoint({ id: b.id }); } return null")
    _ = await dbg("jump({ to: 'first' })")
    _ = await marker(5)
    _ = await dbg("step({ by: 2 })")
    _ = await marker(25)
    var lastPcs: [String: Any]?
    for _ in 0..<40 { lastPcs = commitPcEvents.last; if (lastPcs?["pcs"] as? [String])?.count == 2 { break }; await sleep(50) }
    expect(lastPcs?["pcs"] as? [String] == ["0x80000004", "0x80000008"] && lastPcs?["current"] as? String == "0x80000004",
           "the cycle at 25's commits: \(String(describing: lastPcs))")
    let currentPc = await call("return cmuxWaveform.debugger.currentCommitPc()") as? String
    expect(currentPc == "0x80000004", "Show Instruction in Listing's PC: \(String(describing: currentPc))")
    _ = await dbg("step({ by: 1 })")
    for _ in 0..<40 { lastPcs = commitPcEvents.last; if lastPcs?["current"] as? String == "0x80000004" && (lastPcs?["pcs"] as? [String])?.count == 1 { break }; await sleep(50) }
    expect(lastPcs?["pcs"] as? [String] == ["0x80000004"], "the next cycle's: \(String(describing: lastPcs))")
    _ = await dbg("step({ by: 2 })")
    for _ in 0..<40 { lastPcs = commitPcEvents.last; if (lastPcs?["pcs"] as? [String])?.isEmpty == true { break }; await sleep(50) }
    expect(lastPcs?["pcs"] as? [String] == [] && lastPcs?["current"] is NSNull, "a cycle without a commit (55): none: \(String(describing: lastPcs))")
    _ = await dbg("step({ by: 1 })")
    for _ in 0..<40 { lastPcs = commitPcEvents.last; if lastPcs?["current"] as? String == "0x80000010" { break }; await sleep(50) }
    expect(lastPcs?["current"] as? String == "0x80000010", "65's: \(String(describing: lastPcs))")
    _ = await dbg("stop()")
    for _ in 0..<40 { lastPcs = commitPcEvents.last; if (lastPcs?["pcs"] as? [String])?.isEmpty == true { break }; await sleep(50) }
    expect(lastPcs?["pcs"] as? [String] == [], "cleared on Stop: \(String(describing: lastPcs))")

    // A sample of the commits (cmux checks a listing against it), what cmux says, and the stream's readiness.
    let sample = await call("return cmuxWaveform.debugger.commitSample({ limit: 3 })") as? [[String: Any]]
    expect(sample?.map { $0["pc"] as? String ?? "" } == ["0x80000000", "0x80000004", "0x80000008"]
           && sample?[1]["insn"] as? Int == 0x008002ef, "commitSample: distinct PCs, in order, up to the limit: \(String(describing: sample))")
    await clearToasts()
    _ = await call("cmuxWaveform.debugger.say({ text: 'prog.dis does not match', level: 'warning' }); return null")
    expect(await toasts().contains("prog.dis does not match"), "say shows cmux's text")
    _ = await call("for (const fn of window.__commitListeners) { fn({ reason: 'ready', backend: 1, count: 7 }); } return null")
    await sleep(100)
    expect(readyEvents == 1, "cmux is told when the commit stream is ready: \(readyEvents)")

    print(failures == 0 ? "COMMIT PAGE CHECKS PASSED" : "COMMIT PAGE CHECKS FAILED: \(failures)")
    snap()
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
    if type == "debugger", body["event"] as? String == "pcBreakpoint" { pcEvents.append(body); return }
    if type == "debugger", body["event"] as? String == "commitPcs" { commitPcEvents.append(body); return }
    if type == "debugger", body["event"] as? String == "commitsReady" { readyEvents += 1; return }
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
   debuggerConditionError:'Condition of %1$@: %2$@', debuggerLinePathsCapped:'%1$@: watching the first %2$@ of %3$@ signals', debuggerLoading:'The waveform is still loading; try again in a moment.',
   debuggerLineNotPlaced:'%@: none of its signals are in the waveform (not placed in the design yet).',
   debuggerLineNothingToWatch:'%@: this line assigns no signal, so it has nothing to watch.',
   debuggerLineFileTooLarge:'%@: the file is too large to find the signals of this line.',
   debuggerBreakWhenTextMatches:'Break When Text Matches…', debuggerTextPrompt:'Break when %1$@, shown as %2$@, matches',
   debuggerTextPlaceholder:'A regular expression, for example jal ra or ^csrw mtvec', debuggerBreakpointText:'%1$@ ~ /%2$@/ (%3$@)',
   debuggerTextError:'Text breakpoint %1$@: %2$@', debuggerTextBadFormat:'this format cannot be searched as text',
   debuggerTextNoPattern:'the pattern is empty', debuggerTextPatternTooLong:'the pattern is longer than %@ characters',
   debuggerTextNoAlias:'its alias table is not loaded', debuggerTextTooSlow:'the pattern took too long to match, so the search stopped',
   debuggerTextTooManyValues:'the signal has too many different values to search here',
   debuggerTextTooMany:'At most %@ text breakpoints can be enabled at once.', debuggerEditTextPattern:'Edit Pattern…',
   debuggerTextMatchCase:'Match Case', debuggerTextAnyRegisterNames:'Match Either Register Name (a0 or x10)',
   debuggerTextFormatAlias:'alias %@', debuggerTextFormat_riscv:'RISC-V', debuggerTextFormat_riscv_numeric:'RISC-V, x0–x31',
   debuggerTextFormat_riscv_noalias:'RISC-V, no pseudo-instructions', debuggerTextFormat_riscv_numeric_noalias:'RISC-V, x0–x31, no pseudo-instructions',
   debuggerTextFormat_hexadecimal:'hex', debuggerTextFormat_binary:'binary', debuggerTextFormat_octal:'octal',
   debuggerTextFormat_decimal:'decimal', debuggerTextFormat_signed:'signed decimal', debuggerTextFormat_ascii:'ASCII',
   debuggerBreakAtAddress:'Break at Address…', debuggerBreakOnCommitText:'Break When Next Instruction Matches…',
   debuggerBreakWhenWritten:'Break When Written…', debuggerAddressPrompt:'Break when an instruction at this address commits',
   debuggerAddressPlaceholder:'A hex address', debuggerCommitTextPrompt:"Break when a committed instruction's text matches",
   debuggerWrittenPrompt:'Break when an instruction writes this register, CSR or memory', debuggerWrittenPlaceholder:'a0',
   debuggerEditAddress:'Edit Address…', debuggerEditLocation:'Edit Location…', debuggerBreakpointPc:'PC %@',
   debuggerBreakpointPcAt:'%1$@ (%2$@)', debuggerBreakpointCommitText:'Next instruction ~ /%@/', debuggerBreakpointWritten:'%@ written',
   debuggerCommitError:'Breakpoint %1$@: %2$@', debuggerCommitBadAddress:'an address is a hex number of up to 16 digits',
   debuggerCommitBadLocation:'give a register (a0, x5), a CSR (mstatus) or memory ([0x80001000])',
   debuggerCommitsNone:'%@: this dump has no commit stream (RVFI or similar) to search',
   debuggerCommitsNoInsn:'%@: the commit stream has no instruction word',
   debuggerCommitTooMany:'At most %@ breakpoints of this kind can be enabled'}
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
