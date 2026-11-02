// Split and slice checks (run.sh split): loads Resources/vaporview through the real
// WaveformViewerSchemeHandler in an off-screen, transparent, click-through WKWebView
// (never shown, never activated), opens split.vcd with the app's page strings
// (WaveformViewerStrings) and drives the viewer's own row menu:
//   - Split (Into N Parts…, By Width…, Bits, Add Slice…) is on rows wider than one
//     bit, Remove Slices only once a row has slices;
//   - the slices are rows under their parent, named by element (dfp_addr[1]) for
//     equal parts and bits, by range (odd[9:8]) otherwise, MSB first, with values
//     computed from the parent's value at the marker;
//   - the parent keeps its own row and value and gets a chevron that collapses its
//     slices and expands them again;
//   - a slice has its own format, follows the marker, is found by a value search and
//     copies its value; a slice can be split again (a 3D packed signal);
//   - Add Slice takes the parent's declared indices (nib [7:4]: 6:5);
//   - bad answers are refused with a toast and change nothing;
//   - undo takes a split back and redo brings it again; removing a slice keeps the
//     others; Remove Slices and removing the parent leave no rows behind;
//   - the slices, their names, formats and the collapsed state are in the saved
//     session, and come back from a session file, a reload and a restore.
// Prints SPLIT CHECKS PASSED, or the failures and SPLIT CHECKS FAILED: n.
// Usage: split <assetRoot> <split.vcd> <out.png>
import AppKit
import WebKit

let args = CommandLine.arguments
let assetRoot = URL(fileURLWithPath: args[1], isDirectory: true)
let waveURL = URL(fileURLWithPath: args[2])
let out = URL(fileURLWithPath: args[3])
var failures = 0

func expect(_ ok: Bool, _ what: String) {
  print(ok ? "ok  " : "FAIL", what)
  if !ok { failures += 1 }
}

@MainActor
final class Harness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1400, height: 900),
                        styleMask: [.borderless], backing: .buffered, defer: false)
  let scheme = WaveformViewerSchemeHandler(assetRoot: assetRoot)
  var web: WKWebView!
  var opened = 0
  var onOpened: (() -> Void)?
  var native: [[String: Any]] = []
  let strings = WaveformViewerStrings.all()

  static let prelude = """
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    const until = async (f, ms = 20000) => { const t = Date.now(); let ok; while (!(ok = await f()) && Date.now() - t < ms) { await sleep(100); } return ok; };
    const C = window.cmuxCommands, H = window.cmuxWaveform.host, S = window.cmuxWaveform.strings;
    const T = (k) => S['command.' + k];
    const SPLIT = S['submenu.split'];
    const frameDoc = () => document.getElementById('viewer').contentDocument;
    const rowText = (el) => el.textContent.replace(/\\s+/g, '').trim();
    // Every shown label row (the row's own text, not its slices'), in order.
    const shown = () => [...frameDoc().querySelectorAll('.waveform-label > .waveform-row')].map(rowText);
    const rowIdOf = (label) => {
      const row = [...frameDoc().querySelectorAll('.waveform-label > .waveform-row')].find((el) => rowText(el) === label);
      const lab = row && row.closest('.waveform-label');
      return lab ? parseInt(lab.id.split('-')[1], 10) : null;
    };
    const valueEl = (label) => { const id = rowIdOf(label); return id === null ? null : frameDoc().getElementById('value-' + id); };
    const value = (label) => { const el = valueEl(label); return el ? el.textContent.replace(/[_\\s]/g, '').toLowerCase() : null; };
    const chevron = (label) => {
      const id = rowIdOf(label);
      const lab = id === null ? null : frameDoc().getElementById('label-' + id);
      const row = lab && lab.querySelector(':scope > .waveform-row');
      const c = row && row.querySelector('.codicon-chevron-down, .codicon-chevron-right');
      return c ? (c.classList.contains('codicon-chevron-down') ? 'down' : 'right') : null;
    };
    const clickChevron = async (label) => {
      const id = rowIdOf(label);
      const c = frameDoc().getElementById('label-' + id).querySelector(':scope > .waveform-row .codicon');
      c.dispatchEvent(new MouseEvent('click', { bubbles: true }));
      await sleep(300);
    };
    const select = async (label) => {
      valueEl(label).dispatchEvent(new MouseEvent('click', { bubbles: true }));
      await sleep(200);
    };
    const menuAt = (label) => {
      let got = null;
      const show = window.cmuxUI.showMenu;
      window.cmuxUI.showMenu = (items) => { got = items; };
      try {
        const el = valueEl(label);
        const r = el.getBoundingClientRect();
        el.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: r.left + 2, clientY: r.top + 2 }));
      } finally { window.cmuxUI.showMenu = show; }
      return got || [];
    };
    const find = (items, label) => (items || []).find((i) => i && i.label === label);
    const sub = (items, ...path) => { let it = { items }; for (const l of path) { it = find(it.items, l); if (!it) { return null; } } return it; };
    const labels = (item) => (item && item.items ? item.items.filter((i) => !i.separator).map((i) => i.label) : null);
    // Runs a menu item, answering its prompt (if it has one) with `answer`.
    const choose = async (label, answer, ...path) => {
      const item = sub(menuAt(label), ...path);
      if (!item || !item.run) { return false; }
      const prompt = window.cmuxUI.prompt;
      window.__asked = null;
      window.cmuxUI.prompt = async (o) => { window.__asked = o.title; return answer; };
      try { await item.run(); } finally { window.cmuxUI.prompt = prompt; }
      await sleep(500);
      return true;
    };
    const marker = async (t) => { await C.run('waveformViewer.setMarker', { time: t, markerType: 0 }); await sleep(300); };
    const snapshotRows = () => { const st = C.sessionSnapshot().state; return st ? st.displayedSignals : []; };
    const reloaded = async () => { const t = Date.now(); const busy = () => !C.sessionSnapshot().state || (C.isRestoring && C.isRestoring()); while (busy() && Date.now() - t < 30000) { await sleep(50); } await sleep(400); };
    const sent = window.__sent || (window.__sent = []);
    if (!window.__sentHooked) { window.__sentHooked = true; const toNative = H.toNative; H.toNative = (m) => { sent.push(m); return toNative(m); }; }
    """

  func call(_ body: String) async -> [String: Any] {
    let js = Self.prelude + "\nconst R = {};\n" + body + "\nreturn JSON.stringify(R);"
    do {
      let value = try await web.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
      let object = (value as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
      print("js:", (object ?? [:]).filter { $0.key != "state" && $0.key != "text" })
      return object ?? [:]
    } catch {
      print("JS ERROR", error)
      failures += 1
      return [:]
    }
  }

  func open(restore: [String: Any]? = nil, file: URL = waveURL) async {
    let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
    var argument: [String: Any] = [
      "url": scheme.serve(fileURL: file).absoluteString, "size": size, "format": "vcd",
      "path": "/work/sim/split.vcd", "strings": strings, "settings": ["defaultNameType": "signalName"],
    ]
    argument["restore"] = restore
    let json = String(data: try! JSONSerialization.data(withJSONObject: argument), encoding: .utf8)!
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      onOpened = { done.resume() }
      web.evaluateJavaScript("cmuxWaveform.open(\(json))")
    }
    try? await Task.sleep(nanoseconds: 800_000_000)
  }

  func addAll() async {
    _ = await call("""
      for (const n of ['dfp_addr', 'nib', 'odd', 'cube', 'flag']) { await C.run('waveformViewer.addVariable', { instancePath: 'top.' + n, quiet: true }); await sleep(150); }
      await until(() => shown().length === 5);
      await marker(0);
      R.shown = shown();
      """)
  }

  func runChecks() async {
    await open()
    await addAll()

    // The menu.
    let menu = await call("""
      R.split = labels(sub(menuAt('dfp_addr[63:0]'), SPLIT));
      R.flag = labels(sub(menuAt('flag'), SPLIT));
      R.want = [T('splitDeclared'), T('splitIntoParts'), T('splitByWidth'), T('splitBits'), T('addSlice')];
      R.keys = R.want.concat([SPLIT, T('removeSlices')]).filter((l) => !l || /^(command|submenu)\\./.test(l) || l === 'split');
      """)
    let want = menu["want"] as? [String] ?? []
    expect(want == ["By Declared Dimensions", "Into N Parts…", "By Width…", "Bits", "Add Slice…"], "the Split items come from the app's strings: \(want)")
    expect((menu["keys"] as? [Any])?.isEmpty == true, "every Split title is localized: \(menu["keys"] ?? "nil")")
    expect(menu["split"] as? [String] == want, "a 64-bit row has Split with its five items: \(menu["split"] ?? "nil")")
    expect(menu["flag"] == nil || menu["flag"] is NSNull, "a 1-bit row has no Split")

    // Into N Parts: dfp_addr[63:0] = {elem1, elem0}.
    let parts = await call("""
      R.ok = await choose('dfp_addr[63:0]', '2', SPLIT, T('splitIntoParts'));
      R.asked = window.__asked;
      R.shown = shown();
      R.values = [value('dfp_addr[63:0]'), value('dfp_addr[1]'), value('dfp_addr[0]')];
      R.chevron = chevron('dfp_addr[63:0]');
      R.childChevron = chevron('dfp_addr[1]');
      R.remove = labels(sub(menuAt('dfp_addr[63:0]'), SPLIT));
      """)
    expect(parts["ok"] as? Bool == true && parts["asked"] as? String == strings["promptSplitParts"],
           "Into N Parts asks for the count: \(parts["asked"] ?? "nil")")
    expect(parts["shown"] as? [String] == ["dfp_addr[63:0]", "dfp_addr[1]", "dfp_addr[0]", "nib[7:4]", "odd[9:0]", "cube[23:0]", "flag"],
           "two slices under the parent, MSB first: \(parts["shown"] ?? "nil")")
    expect(parts["values"] as? [String] == ["1111111122222222", "11111111", "22222222"],
           "the slices show their part of the parent's value: \(parts["values"] ?? "nil")")
    expect(parts["chevron"] as? String == "down" && (parts["childChevron"] == nil || parts["childChevron"] is NSNull),
           "the parent has an open chevron, a slice none: \(parts["chevron"] ?? "nil")")
    expect((parts["remove"] as? [String])?.last == strings["command.removeSlices"], "Remove Slices once a row has slices: \(parts["remove"] ?? "nil")")

    // Own format, the marker, search and copy.
    let own = await call("""
      await select('dfp_addr[0]');
      R.ok = await choose('dfp_addr[0]', null, S['submenu.valueFormat'], T('displayAsDecimal'));
      R.values = [value('dfp_addr[63:0]'), value('dfp_addr[1]'), value('dfp_addr[0]')];
      await marker(15);
      R.at15 = [value('dfp_addr[1]'), value('dfp_addr[0]')];
      await marker(25);
      R.at25 = [value('dfp_addr[1]'), value('dfp_addr[0]')];
      await marker(0);
      await select('dfp_addr[1]');
      const d = frameDoc();
      d.getElementById('value-equals-button').click();
      const bar = d.getElementById('search-bar');
      bar.focus(); bar.value = '44444444';
      bar.dispatchEvent(new KeyboardEvent('keyup', { key: '4', bubbles: true }));
      d.getElementById('next-button').click();
      await until(() => H.viewerContext.webview && H.viewerContext.webview.markerTime === 20, 5000);
      R.found = H.viewerContext.webview.markerTime;
      bar.blur();
      await C.run('vaporview.copyValueAtMarker', { rowId: rowIdOf('dfp_addr[1]') });
      await sleep(300);
      """)
    // host.js posts the copy to native itself, not through the page's hook.
    let copied = native.last(where: { $0["type"] as? String == "copy" })?["text"] as? String
    expect(own["values"] as? [String] == ["1111111122222222", "11111111", "572662306"],
           "Decimal on one slice changes only that slice: \(own["values"] ?? "nil")")
    expect(own["at15"] as? [String] == ["11111111", "858993459"] && own["at25"] as? [String] == ["44444444", "858993459"],
           "slices follow the marker: \(own["at15"] ?? "nil") \(own["at25"] ?? "nil")")
    expect(own["found"] as? Int == 20, "a value search on a slice finds its change: \(own["found"] ?? "nil")")
    expect(copied?.replacingOccurrences(of: "_", with: "").lowercased() == "44444444",
           "Copy Value at Marker copies the slice's value: \(copied ?? "nil")")

    // Collapse and expand.
    let fold = await call("""
      await marker(0);
      await clickChevron('dfp_addr[63:0]');
      R.closed = shown(); R.chevron = chevron('dfp_addr[63:0]');
      R.saved = (snapshotRows()[0] || {}).cmuxSlices;
      await clickChevron('dfp_addr[63:0]');
      R.open = shown(); R.chevron2 = chevron('dfp_addr[63:0]');
      """)
    expect(fold["closed"] as? [String] == ["dfp_addr[63:0]", "nib[7:4]", "odd[9:0]", "cube[23:0]", "flag"] && fold["chevron"] as? String == "right",
           "the chevron collapses the slices under the parent: \(fold["closed"] ?? "nil")")
    expect(((fold["saved"] as? [String: Any])?["collapseState"] as? Int) == 1, "the collapsed state is in the view state: \(fold["saved"] ?? "nil")")
    expect((fold["open"] as? [String])?.count == 7 && fold["chevron2"] as? String == "down", "and expands them again")

    // Bits by declared index; By Width with a remainder; Add Slice in declared indices.
    let more = await call("""
      R.ok1 = await choose('nib[7:4]', null, SPLIT, T('splitBits'));
      R.ok2 = await choose('odd[9:0]', '4', SPLIT, T('splitByWidth'));
      R.ok3 = await choose('nib[7:4]', '6:5', SPLIT, T('addSlice'));
      R.ok4 = await choose('dfp_addr[63:0]', '39:32', SPLIT, T('addSlice'));
      R.shown = shown();
      R.nib = ['nib[7]', 'nib[6]', 'nib[5]', 'nib[4]', 'nib[6:5]'].map(value);
      R.odd = ['odd[9:8]', 'odd[7:4]', 'odd[3:0]'].map(value);
      R.extra = value('dfp_addr[39:32]');
      """)
    expect(more["shown"] as? [String] == ["dfp_addr[63:0]", "dfp_addr[1]", "dfp_addr[0]", "dfp_addr[39:32]",
                                          "nib[7:4]", "nib[7]", "nib[6]", "nib[5]", "nib[4]", "nib[6:5]",
                                          "odd[9:0]", "odd[9:8]", "odd[7:4]", "odd[3:0]", "cube[23:0]", "flag"],
           "Bits, By Width and Add Slice add slices under their parents: \(more["shown"] ?? "nil")")
    expect(more["nib"] as? [String] == ["1", "0", "1", "0", "1"], "bits and nib[6:5] by the declared [7:4]: \(more["nib"] ?? "nil")")
    expect(more["odd"] as? [String] == ["2", "c", "e"], "odd by width 4, the short part on top: \(more["odd"] ?? "nil")")
    expect(more["extra"] as? String == "11", "Add Slice 39:32 of dfp_addr: \(more["extra"] ?? "nil")")

    // A slice split again: cube is [1:0][2:0][3:0].
    let nested = await call("""
      R.ok1 = await choose('cube[23:0]', '2', SPLIT, T('splitIntoParts'));
      R.ok2 = await choose('cube[1]', '3', SPLIT, T('splitIntoParts'));
      R.shown = shown().slice(shown().indexOf('cube[23:0]'));
      R.values = ['cube[1]', 'cube[1][2]', 'cube[1][1]', 'cube[1][0]', 'cube[0]'].map(value);
      await marker(35);
      R.later = ['cube[1]', 'cube[1][0]'].map(value);
      await marker(0);
      await clickChevron('cube[1]');
      R.folded = shown().slice(shown().indexOf('cube[23:0]'));
      await clickChevron('cube[1]');
      """)
    expect(nested["shown"] as? [String] == ["cube[23:0]", "cube[1]", "cube[1][2]", "cube[1][1]", "cube[1][0]", "cube[0]", "flag"],
           "a slice splits again, its slices nested under it: \(nested["shown"] ?? "nil")")
    expect(nested["values"] as? [String] == ["abc", "a", "b", "c", "123"], "nested values: \(nested["values"] ?? "nil")")
    expect(nested["later"] as? [String] == ["abd", "d"], "nested slices follow the marker: \(nested["later"] ?? "nil")")
    expect(nested["folded"] as? [String] == ["cube[23:0]", "cube[1]", "cube[0]", "flag"], "a nested chevron folds only its own slices: \(nested["folded"] ?? "nil")")

    // Refused answers change nothing.
    let bad = await call("""
      const before = shown().length;
      let told = 0;
      const toast = window.cmuxUI.toast;
      window.cmuxUI.toast = (...a) => { told++; return toast(...a); };
      for (const [item, answer] of [['splitIntoParts', '3'], ['splitIntoParts', '0'], ['splitIntoParts', 'x'], ['splitByWidth', '65'],
                                    ['addSlice', '64:0'], ['addSlice', '3:9'], ['addSlice', 'a:b']]) {
        await choose('dfp_addr[63:0]', answer, SPLIT, T(item));
      }
      await choose('nib[7:4]', '3:2', SPLIT, T('addSlice'));
      window.cmuxUI.toast = toast;
      R.same = shown().length === before;
      R.toasts = told;
      """)
    expect(bad["same"] as? Bool == true, "bad counts, widths and ranges add no rows")
    expect(bad["toasts"] as? Int == 8, "each is refused with a toast: \(bad["toasts"] ?? "nil")")

    // Undo and redo a split; remove one slice; Remove Slices; the saved session.
    let undo = await call("""
      const has = () => shown().includes('cube[1][2]');
      await C.run('cmux.undo'); await sleep(500);
      R.undone = !has() && shown().includes('cube[1]');
      await C.run('cmux.redo'); await sleep(500);
      R.redone = has() && value('cube[1][2]') === 'a';
      await select('nib[6:5]');
      await C.run('vaporview.removeSignal', { rowId: rowIdOf('nib[6:5]') }); await sleep(400);
      R.nib = shown().filter((l) => l.startsWith('nib'));
      R.ok = await choose('odd[9:0]', null, SPLIT, T('removeSlices'));
      R.odd = shown().filter((l) => l.startsWith('odd'));
      R.oddChevron = chevron('odd[9:0]');
      R.state = C.sessionSnapshot().state;
      """)
    expect(undo["undone"] as? Bool == true && undo["redone"] as? Bool == true, "undo takes a split back, redo brings it again")
    expect(undo["nib"] as? [String] == ["nib[7:4]", "nib[7]", "nib[6]", "nib[5]", "nib[4]"], "removing one slice keeps the others: \(undo["nib"] ?? "nil")")
    expect(undo["odd"] as? [String] == ["odd[9:0]"] && (undo["oddChevron"] == nil || undo["oddChevron"] is NSNull),
           "Remove Slices takes them and the chevron away: \(undo["odd"] ?? "nil")")

    let saved = await call("""
      await clickChevron('nib[7:4]');
      await C.run('vaporview.saveViewerSession');
      const save = sent.filter((m) => m.type === 'saveSession').pop();
      R.text = save ? save.text : null;
      R.state = C.sessionSnapshot().state;
      """)
    let sessionText = saved["text"] as? String ?? ""
    let file = (try? JSONSerialization.jsonObject(with: Data(sessionText.utf8))) as? [String: Any]
    let top = file?["displayedSignals"] as? [[String: Any]] ?? []
    let addr = top.first { $0["name"] as? String == "top.dfp_addr" }
    let slices = (addr?["cmuxSlices"] as? [String: Any])?["children"] as? [[String: Any]] ?? []
    expect(slices.map { $0["customName"] as? String ?? "" } == ["dfp_addr[1]", "dfp_addr[0]", "dfp_addr[39:32]"],
           "the session file holds the slices: \(slices.map { $0["customName"] ?? "" })")
    expect(slices.dropFirst().first?["numberFormat"] as? String == "decimal", "and their formats: \(slices.map { $0["numberFormat"] ?? "" })")

    let expected = ["dfp_addr[63:0]", "dfp_addr[1]", "dfp_addr[0]", "dfp_addr[39:32]", "nib[7:4]", "odd[9:0]",
                    "cube[23:0]", "cube[1]", "cube[1][2]", "cube[1][1]", "cube[1][0]", "cube[0]", "flag"]
    let check = """
      await until(() => shown().length >= 13, 10000);
      await marker(0);
      R.shown = shown();
      R.values = [value('dfp_addr[0]'), value('cube[1][2]'), value('dfp_addr[39:32]')];
      R.nibChevron = chevron('nib[7:4]');
      await clickChevron('nib[7:4]');
      R.nib = shown().filter((l) => l.startsWith('nib'));
      await clickChevron('nib[7:4]');
      """
    func verify(_ r: [String: Any], _ how: String) {
      expect(r["shown"] as? [String] == expected, "\(how) brings the slices back: \(r["shown"] ?? "nil")")
      expect(r["values"] as? [String] == ["572662306", "a", "11"], "\(how) keeps their formats and values: \(r["values"] ?? "nil")")
      expect(r["nibChevron"] as? String == "right" && (r["nib"] as? [String])?.count == 5, "\(how) keeps nib collapsed: \(r["nib"] ?? "nil")")
    }

    await open()
    verify(await call("C.applySessionFile({ text: \(jsString(sessionText)), path: '/work/sim/split.json' });\nawait sleep(1500);\n" + check),
           "loading the session file")
    let reload = await call("window.cmuxWaveform.reload({});\nawait reloaded();\n" + check + "\nR.state = C.sessionSnapshot().state;")
    verify(reload, "a reload")
    if let state = reload["state"] as? [String: Any] {
      await open(restore: ["state": state, "dirty": false])
      verify(await call(check), "a restore (new panel)")
    } else {
      expect(false, "a state to restore")
    }

    // Removing a parent removes its slices with it.
    let gone = await call("""
      await select('cube[23:0]');
      await C.run('vaporview.removeSignal', { rowId: rowIdOf('cube[23:0]') }); await sleep(400);
      R.shown = shown();
      R.left = frameDoc().querySelectorAll('.value-display-item').length;
      R.rows = snapshotRows().length;
      """)
    expect(gone["shown"] as? [String] == ["dfp_addr[63:0]", "dfp_addr[1]", "dfp_addr[0]", "dfp_addr[39:32]", "nib[7:4]", "odd[9:0]", "flag"],
           "removing a parent removes its slices: \(gone["shown"] ?? "nil")")
    expect(gone["left"] as? Int == 7 && gone["rows"] as? Int == 4, "no rows are left behind: \(gone["left"] ?? "nil") values, \(gone["rows"] ?? "nil") saved")

    // By Declared Dimensions: cmux answers with the packed dimensions slang gives the signal
    // (here, `packedDims` below), and the row splits along them, nested, in one undo step.
    let declared = await call("""
      R.sliceMenu = labels(sub(menuAt('dfp_addr[1]'), SPLIT));
      sent.length = 0;
      await C.run('waveformViewer.addVariable', { instancePath: 'top.cube', quiet: true });
      await until(() => shown().includes('cube[23:0]'));
      await marker(0);
      await choose('cube[23:0]', null, SPLIT, T('splitDeclared'));
      await until(() => shown().includes('cube[0][0]'), 5000);
      R.asked = sent.filter((m) => m.type === 'packedDims').map((m) => m.path.join('.'));
      R.shown = shown();
      R.values = ['cube[1]', 'cube[1][2]', 'cube[1][1]', 'cube[1][0]', 'cube[0]', 'cube[0][2]', 'cube[0][0]'].map(value);
      await C.run('cmux.undo'); await sleep(800);
      R.undone = shown();
      await C.run('cmux.redo'); await sleep(800);
      R.redone = shown();
      // Index order: [0:1] puts element 0 at the most significant end.
      await choose('nib[7:4]', null, SPLIT, T('splitDeclared'));
      await until(() => shown().includes('nib[0]'), 5000);
      await marker(15);
      R.nib = shown().filter((l) => /^nib\\[[01]\\]$/.test(l));
      R.nibValues = [value('nib[0]'), value('nib[1]')];
      // A declared type of another width, or none: refused, nothing added.
      const toasts = [];
      const toast = window.cmuxUI.toast;
      window.cmuxUI.toast = (text, kind) => { toasts.push(String(text)); };
      const before = shown().length;
      await choose('odd[9:0]', null, SPLIT, T('splitDeclared'));
      await sleep(600);
      await choose('dfp_addr[63:0]', null, SPLIT, T('splitDeclared'));
      await sleep(600);
      window.cmuxUI.toast = toast;
      R.toasts = toasts;
      R.added = shown().length - before;
      """)
    expect(!((declared["sliceMenu"] as? [String]) ?? []).contains(strings["command.splitDeclared"] ?? "?"),
           "a slice has no By Declared Dimensions (it isn't a declared signal): \(declared["sliceMenu"] ?? "nil")")
    expect(declared["asked"] as? [String] == ["top.cube"], "cmux is asked for the row's dump path: \(declared["asked"] ?? "nil")")
    let cubeRows = ["cube[23:0]", "cube[1]", "cube[1][2]", "cube[1][1]", "cube[1][0]", "cube[0]", "cube[0][2]", "cube[0][1]", "cube[0][0]"]
    let cubeShown = (declared["shown"] as? [String])?.filter { $0.hasPrefix("cube") }
    expect(cubeShown == cubeRows, "a 3-D signal splits by its outer dimension, then the next: \(cubeShown ?? [])")
    expect(declared["values"] as? [String] == ["abc", "a", "b", "c", "123", "1", "3"], "each element shows its bits: \(declared["values"] ?? "nil")")
    expect((declared["undone"] as? [String])?.filter { $0.hasPrefix("cube") } == ["cube[23:0]"], "one Undo removes the whole split: \(declared["undone"] ?? "nil")")
    expect((declared["redone"] as? [String])?.filter { $0.hasPrefix("cube") } == cubeRows, "and Redo brings it back: \(declared["redone"] ?? "nil")")
    expect(declared["nib"] as? [String] == ["nib[0]", "nib[1]"] && declared["nibValues"] as? [String] == ["1", "2"],
           "[0:1] puts element 0 first, at the top bits: \(declared["nib"] ?? "nil") \(declared["nibValues"] ?? "nil")")
    let toasts = declared["toasts"] as? [String] ?? []
    expect(toasts.count == 2 && toasts.first?.contains("odd") == true && toasts.last == strings["messageNoDeclaredDimensions"],
           "another width, or no declared type, is refused with a message: \(toasts)")
    expect(declared["added"] as? Int == 0, "and adds nothing: \(declared["added"] ?? "nil")")

    // Custom Length is offered above 256 bits; a split into too many slices is refused.
    let wide = await call("""
      await C.run('waveformViewer.addVariable', { instancePath: 'top.wide', quiet: true });
      await until(() => shown().includes('wide[299:0]'));
      R.custom = labels(sub(menuAt('wide[299:0]'), S['submenu.createSignals']));
      const toasts = [];
      const toast = window.cmuxUI.toast;
      window.cmuxUI.toast = (text) => { toasts.push(String(text)); };
      const before = shown().length;
      await choose('wide[299:0]', '1', S['submenu.createSignals'], T('createSignalsForAllCustomLength'));
      window.cmuxUI.toast = toast;
      R.toasts = toasts;
      R.added = shown().length - before;
      """)
    expect(((wide["custom"] as? [String]) ?? []).contains(strings["command.createSignalsForAllCustomLength"] ?? "?"),
           "a 300-bit row has Custom Length: \(wide["custom"] ?? "nil")")
    expect(wide["toasts"] as? [String] == [strings["messageTooManySlices"] ?? "?"] && wide["added"] as? Int == 0,
           "300 one-bit slices are refused: \(wide["toasts"] ?? "nil") +\(wide["added"] ?? "nil")")

    // A session's slice past the end of a signal that got narrower (a parameter changed) is
    // missing, by its own name, rather than cut down to the bits left under its old name.
    await open(file: waveURL.deletingLastPathComponent().appendingPathComponent("narrow.vcd"))
    let narrow = await call("""
      const toasts = [];
      const toast = window.cmuxUI.toast;
      window.cmuxUI.toast = (text) => { toasts.push(String(text)); };
      C.applySessionFile({ text: \(jsString(sessionText)), path: '/work/sim/split.json' });
      await sleep(1500);
      await until(() => shown().includes('dfp_addr[39:32]'), 10000);
      window.cmuxUI.toast = toast;
      await marker(0);
      R.toasts = toasts;
      const addr = snapshotRows().find((r) => r.name === 'top.dfp_addr');
      R.slices = ((addr && addr.cmuxSlices && addr.cmuxSlices.children) || []).map((c) => [c.customName, c.source[0].msb, c.source[0].lsb, c.source[0].netlistId === undefined || c.source[0].netlistId === null]);
      R.values = [value('dfp_addr[0]'), value('dfp_addr[39:32]')];
      """)
    expect(narrow["slices"] as? [[AnyHashable]] == [["dfp_addr[1]", 63, 32, true], ["dfp_addr[0]", 31, 0, false], ["dfp_addr[39:32]", 39, 32, false]],
           "a slice past the narrower signal's end stays missing with its bits; the others resolve: \(narrow["slices"] ?? "nil")")
    expect(narrow["values"] as? [String] == ["572662306", "11"], "the slices that fit keep their values: \(narrow["values"] ?? "nil")")
    let narrowToasts = narrow["toasts"] as? [String] ?? []
    expect(narrowToasts.count == 1 && narrowToasts[0].contains("top.dfp_addr[1]") && !narrowToasts[0].contains("top.dfp_addr,") && !narrowToasts[0].hasSuffix("top.dfp_addr"),
           "the missing-signals message names the slice: \(narrowToasts)")

    print(failures == 0 ? "SPLIT CHECKS PASSED" : "SPLIT CHECKS FAILED: \(failures)")
    snap()
  }

  func jsString(_ s: String) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)!.dropFirst().dropLast().description
  }

  func start() {
    let cfg = WKWebViewConfiguration()
    cfg.setURLSchemeHandler(scheme, forURLScheme: WaveformViewerSchemeHandler.scheme)
    let hook = """
    (function(){ for (const k of ['warn','error']) { const o = console[k];
      console[k] = (...a) => { try { webkit.messageHandlers.console.postMessage(k + ': ' + a.map(String).join(' ')); } catch(e){}; o.apply(console, a); }; }
      window.addEventListener('error', e => webkit.messageHandlers.console.postMessage('onerror: ' + e.message + ' @' + e.filename + ':' + e.lineno));
    })();
    """
    cfg.userContentController.addUserScript(WKUserScript(source: hook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    cfg.userContentController.add(self, name: "console")
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

  func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
    if m.name == "console" { print("[console]", m.body); return }
    guard let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
    native.append(body)
    switch type {
    case "ready":
      guard opened == 0, native.filter({ $0["type"] as? String == "ready" }).count == 1 else { return }
      Task { @MainActor in await self.runChecks() }
    case "opened":
      opened += 1
      let next = onOpened
      onOpened = nil
      next?()
    case "packedDims":
      // cmux's side: the packed dimensions slang would give each dump path.
      let dims: [String: [[Int]]] = ["top.cube": [[1, 0], [2, 0], [3, 0]], "top.nib": [[0, 1], [1, 0]], "top.odd": [[1, 0], [3, 0]]]
      let path = (body["path"] as? [String] ?? []).joined(separator: ".")
      let answer: [String: Any] = ["id": body["id"] ?? NSNull(), "dims": dims[path].map { $0 as Any } ?? NSNull()]
      let json = String(data: try! JSONSerialization.data(withJSONObject: answer), encoding: .utf8)!
      web.evaluateJavaScript("window.cmuxWaveform.split.declared(\(json))")
    case "error":
      print("[error]", body["message"] ?? "")
    default:
      break
    }
  }

  func snap() {
    web.takeSnapshot(with: nil) { img, err in
      if let img = img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
         let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: out)
      } else { print("snapshot failed", String(describing: err)) }
      exit(failures == 0 ? 0 : 2)
    }
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let h = MainActor.assumeIsolated { Harness() }
MainActor.assumeIsolated { h.start() }
var loads = [Double](repeating: 0, count: 3)
let load = getloadavg(&loads, 3) > 0 ? loads[0] : 0
let limit = min(840.0, 240.0 + 4.0 * load)
print("timeout limit \(Int(limit)) s at load \(Int(load))")
Thread {
  Thread.sleep(forTimeInterval: limit)
  print("timeout after \(Int(limit)) s")
  fflush(stdout)
  exit(1)
}.start()
app.run()
