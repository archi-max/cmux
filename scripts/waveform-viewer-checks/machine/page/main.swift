// Machine state checks in the real page (run.sh machine): loads Resources/vaporview through the
// app's WaveformViewerSchemeHandler in an off-screen WKWebView, opens one dump and runs
// page-checks.js in the page (the stream found from wellen's netlist, the pane, F10 by commit, $
// names, gdb commands, row actions) against Spike's log or the generator's replay. The ELF image is
// read by the app's own WaveformMachineState.loadImage (readelf), and its parsers are checked here.
// Usage (machine/page/main.swift): machine-page <assetRoot> <machineDir> <outDir> <case>
//   case: nerv | picorv32 | ibex (fixtures/<case>) | prefixed | packed2 | array2 | array2late | struct | monitor | forward | none
//        machine-page <assetRoot> <machineDir> <outDir> fsdb <helperRoot> <sshHost> <remote.fsdb> <local commit.log> [local.elf]
//   fsdb: a remote FSDB through the helper (under nice), read in place, against its Spike-format commit.log.
import AppKit
import JavaScriptCore
import WebKit

let args = CommandLine.arguments
let assetRoot = URL(fileURLWithPath: args[1], isDirectory: true)
let machineDir = URL(fileURLWithPath: args[2], isDirectory: true)
let outDir = URL(fileURLWithPath: args[3], isDirectory: true)
let which = args[4]
let cores = ["nerv", "picorv32", "ibex"]
var failures = 0
let isFSDB = which == "fsdb"
let launched = Date()
/// Ready (90 s) plus one open on a busy host; a longer wait is a stuck connection, not a slow one.
let openTimeout: TimeInterval = 240
func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func expect(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "FAIL ", what); if !ok { failures += 1 } }

/// The dump to open: a fixture, a synthetic stream written by make-rvfi-vcd.js (in JavaScriptCore), or one with no stream.
func dumpURL() -> URL {
    if isFSDB { return URL(fileURLWithPath: "/dev/null") }
    if cores.contains(which) { return machineDir.appendingPathComponent("fixtures/\(which)/\(which).vcd") }
    let url = outDir.appendingPathComponent("machine-\(which).vcd")
    if which == "none" {
        var text = "$timescale 1ns $end\n$scope module top $end\n$var wire 1 ! clk $end\n$var wire 8 \" data [7:0] $end\n$upscope $end\n$enddefinitions $end\n"
        for n in 0..<20 { text += "#\(n * 10)\n1!\nb\(String(n, radix: 2)) \"\n#\(n * 10 + 5)\n0!\n" }
        try! text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    let js = JSContext()!
    js.exceptionHandler = { _, e in print("JS", e?.toString() ?? "") }
    js.evaluateScript(try! String(contentsOf: machineDir.appendingPathComponent("make-rvfi-vcd.js"), encoding: .utf8))
    let vcd = js.evaluateScript("rvfiToVcd(makeRvfi('\(which)'))")!.toString()!
    try! vcd.write(to: url, atomically: true, encoding: .utf8)
    return url
}

/// The app's ELF reading: readelf's text parsed, the ELF next to a dump found.
func elfChecks() {
    let headers = """
    Program Headers:
      Type           Offset   VirtAddr   PhysAddr   FileSiz MemSiz  Flg Align
      LOAD           0x001000 0x80000000 0x80000000 0x00450 0x00460 RWE 0x1000
      LOAD           0x002000 0x0000000080001000 0x0000000080001000 0x000010 0x000400 RW  0x1000
      GNU_STACK      0x000000 0x00000000 0x00000000 0x00000 0x00000 RW  0x10
    """
    let segments = WaveformMachineState.parseProgramHeaders(headers)
    expect(segments == [.init(offset: 0x1000, address: 0x8000_0000, fileSize: 0x450, memorySize: 0x460),
                        .init(offset: 0x2000, address: 0x8000_1000, fileSize: 0x10, memorySize: 0x400)],
           "readelf -lW: two LOAD lines (32- and 64-bit widths), GNU_STACK left out: \(segments)")
    let symbols = WaveformMachineState.parseSymbols("""
    Symbol table '.symtab' contains 5 entries:
       Num:    Value  Size Type    Bind   Vis      Ndx Name
         0: 00000000     0 NOTYPE  LOCAL  DEFAULT  UND
         1: 80000000     0 SECTION LOCAL  DEFAULT    1 .text
         2: 00000000     0 FILE    LOCAL  DEFAULT  ABS main.c
         3: 80000080    24 FUNC    GLOBAL DEFAULT    1 main
         4: 80001000 0x186a0 OBJECT GLOBAL DEFAULT    2 big_table
    """)
    expect(symbols == [.init(name: "main", address: 0x8000_0080, size: 24), .init(name: "big_table", address: 0x8000_1000, size: 100_000)],
           "readelf -sW: functions and objects, hex sizes; no sections, files or undefined: \(symbols)")
    let nervVCD = machineDir.appendingPathComponent("fixtures/nerv/nerv.vcd").path
    expect(WaveformMachineState.elfBeside(dumpPath: nervVCD) == machineDir.appendingPathComponent("fixtures/nerv/prog.elf").path,
           "the ELF next to a dump: \(WaveformMachineState.elfBeside(dumpPath: nervVCD) ?? "none")")
    let tools = WaveformMachineState.readelfCandidates()
    expect(!tools.isEmpty, "a readelf found: \(tools.first ?? "none")")
    do {
        _ = try WaveformMachineState.loadImage(path: nervVCD)
        expect(false, "a VCD is not an ELF")
    } catch {
        expect(error as? WaveformMachineState.LoadError == .notAnELF(nervVCD), "a VCD is not an ELF: \(WaveformMachineState.message(for: error))")
    }
    do {
        _ = try WaveformMachineState.loadImage(path: machineDir.appendingPathComponent("fixtures/nerv/prog.elf").path, readelf: [], python: [])
        expect(false, "no readelf: an error")
    } catch {
        expect(error as? WaveformMachineState.LoadError == .noReadelf, "no readelf: says so: \(WaveformMachineState.message(for: error))")
    }
    // pyelftools (no toolchain): the same image as readelf's. CMUX_MACHINE_PYELFTOOLS: a python3 that has it.
    let elf = machineDir.appendingPathComponent("fixtures/nerv/prog.elf").path
    if let py = ProcessInfo.processInfo.environment["CMUX_MACHINE_PYELFTOOLS"], !py.isEmpty {
        let a = try? WaveformMachineState.loadImage(path: elf, python: [])
        let b = try? WaveformMachineState.loadImage(path: elf, readelf: [], python: [py])
        expect(a != nil && b != nil && a!.segments.map(\.address) == b!.segments.map(\.address)
               && a!.segments.map(\.bytes) == b!.segments.map(\.bytes) && a!.segments.map(\.memorySize) == b!.segments.map(\.memorySize)
               && a!.symbols == b!.symbols,
               "pyelftools gives readelf's image: \(b?.segments.count ?? -1) segments, \(b?.symbols.count ?? -1) symbols")
    } else {
        print("      pyelftools: skipped (set CMUX_MACHINE_PYELFTOOLS to a python3 with pyelftools)")
    }
}

@MainActor
final class Harness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
    let scheme = WaveformViewerSchemeHandler(assetRoot: assetRoot)
    var web: WKWebView!
    var started = false
    let dump = dumpURL()
    var helper: WaveformFSDBHelper?

    func start() {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(scheme, forURLScheme: WaveformViewerSchemeHandler.scheme)
        let hook = """
        (function(){ for (const k of ['warn','error']) { const o = console[k];
          console[k] = (...a) => { try { webkit.messageHandlers.console.postMessage(k + ': ' + a.map((x) => (x && x.stack ? String(x) + ' ' + x.stack : String(x))).join(' ')); } catch(e){}; o.apply(console, a); }; }
          window.addEventListener('error', e => webkit.messageHandlers.console.postMessage('onerror: ' + e.message + ' @' + e.filename + ':' + e.lineno + ' ' + (e.error && e.error.stack)));
        })();
        """
        cfg.userContentController.addUserScript(WKUserScript(source: hook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        for name in ["make-rvfi-vcd.js", "core-cases.js", "page-checks.js"] {
            let source = try! String(contentsOf: machineDir.appendingPathComponent(name), encoding: .utf8)
            cfg.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        cfg.userContentController.add(self, name: "console")
        cfg.userContentController.add(self, name: "cmuxWaveform")
        web = WKWebView(frame: window.contentView!.bounds, configuration: cfg)
        web.navigationDelegate = self
        window.contentView!.addSubview(web)
        // Invisible to the user: off-screen, transparent, click-through.
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        if isFSDB {
            let host = args[6]
            helper = WaveformFSDBHelper(sshArguments: { cmd in
                ["-o", "BatchMode=yes", "-T", "--", host, "exec nice -n 10 bash -c " + shellQuoted(cmd)]
            }, resourceRoot: URL(fileURLWithPath: args[5], isDirectory: true)) { status in print("      [helper]", status, "at", Int(Date().timeIntervalSince(launched)), "s") }
            // The dump must open within openTimeout. If it doesn't (one run sat at "connecting" for 840 s while
            // another Verdi loaded on the host), say where it stopped and exit 75 so run.sh retries once.
            DispatchQueue.main.asyncAfter(deadline: .now() + openTimeout) { [weak self] in
                guard let self, !self.started else { return }
                print("FAIL  the FSDB did not open within \(Int(openTimeout)) s (helper connect, install or the open request); exit 75 to retry")
                self.helper?.stop()
                exit(75)
            }
        }
        web.load(URLRequest(url: WaveformViewerSchemeHandler.indexURL))
    }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard m.name == "cmuxWaveform", let body = m.body as? [String: Any], let type = body["type"] as? String else {
            print("[\(m.name)]", m.body)
            return
        }
        if type == "ready", isFSDB, let helper {
            let relayURL = scheme.serve(fsdbRelay: { body in await helper.response(for: body) { "\($0)" } })
            let data = try! JSONSerialization.data(withJSONObject: Self.strings())
            web.evaluateJavaScript("cmuxWaveform.open({url:'cmux-waveform://viewer/x.fsdb', format:'fsdb', strings:\(String(decoding: data, as: UTF8.self)), "
                + "fsdb:{url:'\(relayURL.absoluteString)', path:'\(args[7])'}})")
        } else if type == "ready" {
            let fileURL = scheme.serve(fileURL: dump)
            let size = (try? FileManager.default.attributesOfItem(atPath: dump.path)[.size] as? NSNumber)?.intValue ?? 0
            let data = try! JSONSerialization.data(withJSONObject: Self.strings())
            web.evaluateJavaScript("cmuxWaveform.open({url:'\(fileURL.absoluteString)', size:\(size), format:'vcd', strings:\(String(decoding: data, as: UTF8.self))})")
        } else if type == "opened", !started {
            started = true
            if isFSDB { print("      [page] opened") }
            Task { @MainActor in await self.run() }
        } else if type == "progress" {
            print("      [page]", body["text"] ?? "")
        } else if type == "error" {
            print("ERROR", body["message"] ?? "")
            exit(1)
        }
    }

    func run() async {
        var options: [String: Any] = ["kind": cores.contains(which) ? "core" : (which == "none" ? "none" : (isFSDB ? "fsdb" : "synthetic")), "name": which]
        if isFSDB {
            options["name"] = (args[7] as NSString).lastPathComponent
            options["spikeLog"] = try! String(contentsOf: URL(fileURLWithPath: args[8]), encoding: .utf8)
            if args.count > 9, let image = try? WaveformMachineState.loadImage(path: args[9]) { options["image"] = image.pageArgument }
        }
        if cores.contains(which) {
            let dir = machineDir.appendingPathComponent("fixtures/\(which)")
            options["spikeLog"] = try! String(contentsOf: dir.appendingPathComponent("spike.log"), encoding: .utf8)
            do {
                let t0 = Date()
                let image = try WaveformMachineState.loadImage(path: dir.appendingPathComponent("prog.elf").path)
                print("      prog.elf through readelf: \(image.segments.count) segments, \(image.symbols.count) symbols in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
                options["image"] = image.pageArgument
            } catch {
                expect(false, "prog.elf: \(WaveformMachineState.message(for: error))")
            }
            if which == "nerv" { elfChecks() }
        }
        do {
            let result = try await web.callAsyncJavaScript("return await runMachinePageChecks(options)", arguments: ["options": options],
                                                           in: nil, contentWorld: .page) as? [String: Any]
            for line in result?["lines"] as? [String] ?? [] { print(line) }
            failures += (result?["failures"] as? Int) ?? 1
            if result == nil { print("FAIL  no result") }
        } catch {
            print("FAIL  page checks threw:", error)
            failures += 1
        }
        print(failures == 0 ? "MACHINE PAGE CHECKS PASSED (\(which))" : "MACHINE PAGE CHECKS FAILED (\(which)): \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    /// The page's strings as cmux gives them: the machine section's from the app's own source, and
    /// the debugger's that these checks read.
    static func strings() -> [String: String] {
        [
            "netlist": "Netlist", "loading": "Loading…", "openFailed": "Could not open", "debuggerLocals": "Locals",
            "debuggerCycle": "Cycle %1$@ of %2$@ · %3$@", "debuggerRate": "%@ cycles/s", "debuggerBreakpoints": "Breakpoints",
            "debuggerBreakpointChanges": "%@ changes", "debuggerBreakpointIf": "%1$@ if %2$@", "debuggerRemoveBreakpoint": "Remove",
            "debuggerBreakWhenChanges": "Break When Changes", "debuggerBreakWhenEquals": "Break When Equals…",
            "debuggerBreakpointHit": "Breakpoint: %1$@ at %2$@ (cycle %3$@)", "debuggerNoHitForward": "No breakpoint hit before the end.",
            "debuggerNoEdges": "The clock never rises.", "debuggerNoClock": "No clock.", "debuggerEvaluate": "Evaluate",
            "debuggerEvalResult": "= %1$@ (width %2$@)", "debuggerEvalTooltip": "Binary %1$@, decimal %2$@", "debuggerAddWatch": "Add Watch",
            "debuggerWatch": "Watch", "debuggerExprError": "%1$@ (column %2$@)", "debuggerExprSyntax": "Unexpected text",
            "debuggerExprUnsupported": "Not supported here", "debuggerExprUnknownName": "%@ is not in this waveform",
            "debuggerExprNoValue": "%@ has no value at the marker", "debuggerExprNoMarker": "Put the marker on a cycle first.",
            "debuggerConditionError": "Condition of %1$@: %2$@", "debuggerTooManyChanges": "%@ changes too often to search here.",
            "debuggerBreakpointSignalGone": "%@ is not in this waveform.", "debuggerLoading": "The waveform is still loading.",
        ].merging(WaveformMachineState.pageStrings()) { _, machine in machine }
    }
}

setvbuf(stdout, nil, _IOLBF, 0)  // a hang shows where it stopped
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let h = MainActor.assumeIsolated { Harness() }
MainActor.assumeIsolated { h.start() }
DispatchQueue.main.asyncAfter(deadline: .now() + (isFSDB ? 840 : 240)) { print("timeout"); exit(1) }
app.run()
