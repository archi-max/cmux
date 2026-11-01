import Foundation

/// The waveform debugger's machine state (status/asm-breakpoints-design.md §1–§3): the viewer page
/// (`Resources/vaporview/cmux-machine.js`) finds the core's commit stream in the dump and replays it
/// into registers and memory. This side gives it its strings and the program image memory starts
/// from: an ELF's PT_LOAD segments and symbols, read with the toolchain's `readelf` (§16 answer 6:
/// the toolchain's tool, else LLVM's or the system's), not a parser of our own.
enum WaveformMachineState {
    // MARK: The program image

    struct Segment: Equatable, Sendable {
        var offset: UInt64
        var address: UInt64
        var fileSize: UInt64
        var memorySize: UInt64
    }

    struct Symbol: Equatable, Sendable {
        var name: String
        var address: UInt64
        var size: UInt64
    }

    struct Image: Sendable {
        var path: String
        var segments: [(address: UInt64, memorySize: UInt64, bytes: Data)]
        var symbols: [Symbol]

        /// For `cmuxWaveform.machine.setImage` (the bytes as base64).
        var pageArgument: [String: Any] {
            [
                "path": path,
                "segments": segments.map { ["addr": NSNumber(value: $0.address), "memsz": NSNumber(value: $0.memorySize),
                                            "bytes": $0.bytes.base64EncodedString()] },
                "symbols": symbols.map { ["name": $0.name, "addr": NSNumber(value: $0.address), "size": NSNumber(value: $0.size)] },
            ]
        }
    }

    enum LoadError: Error, Equatable, Sendable {
        case noReadelf
        case notAnELF(String)
        case noLoadSegments
        case unreadable(String)
    }

    /// At most this much of the image is sent to the page (a 64 MiB .bss is not sent byte by byte: it is memsz).
    static let maxImageBytes: UInt64 = 64 << 20

    /// `readelf` names to try, in order: the RISC-V toolchains', LLVM's, then the system's.
    static let readelfNames = [
        "riscv64-unknown-elf-readelf", "riscv32-unknown-elf-readelf", "riscv64-elf-readelf", "riscv64-linux-gnu-readelf",
        "llvm-readelf", "readelf",
    ]

    /// Where to look for them: `$RISCV/bin`, `PATH`, Homebrew's and its LLVM's bin.
    static func readelfCandidates(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var dirs: [String] = []
        if let riscv = environment["RISCV"], !riscv.isEmpty { dirs.append(riscv + "/bin") }
        dirs += (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/opt/homebrew/opt/llvm/bin", "/usr/local/bin", "/usr/local/opt/llvm/bin", "/usr/bin"]
        var seen = Set<String>()
        var out: [String] = []
        for name in readelfNames {
            for dir in dirs where !dir.isEmpty {
                let path = (dir as NSString).appendingPathComponent(name)
                if seen.insert(path).inserted, FileManager.default.isExecutableFile(atPath: path) { out.append(path) }
            }
        }
        return out
    }

    /// The LOAD lines of `readelf -lW`:
    /// `  LOAD  0x001000 0x0000000080000000 0x0000000080000000 0x000450 0x000460 RWE 0x1000`.
    static func parseProgramHeaders(_ text: String) -> [Segment] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.count >= 6, f[0] == "LOAD",
                  let offset = hex(f[1]), let virtual = hex(f[2]), let fileSize = hex(f[4]), let memorySize = hex(f[5])
            else { return nil }
            return Segment(offset: offset, address: virtual, fileSize: fileSize, memorySize: memorySize)
        }
    }

    /// The symbols of `readelf -sW`: `    12: 80000080    24 FUNC    GLOBAL DEFAULT    1 main`
    /// (sizes are decimal, or hex past 99999). Sections, files and nameless ones are left out.
    static func parseSymbols(_ text: String) -> [Symbol] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.count >= 8, f[0].hasSuffix(":"), let address = UInt64(f[1], radix: 16) else { return nil }
            let type = f[3]
            guard type != "SECTION", type != "FILE", f[6] != "UND" else { return nil }
            let size = f[2].hasPrefix("0x") ? UInt64(f[2].dropFirst(2), radix: 16) : UInt64(f[2])
            let name = f[7...].joined(separator: " ")
            guard !name.isEmpty, let size else { return nil }
            return Symbol(name: name, address: address, size: size)
        }
    }

    private static func hex(_ s: Substring) -> UInt64? {
        s.hasPrefix("0x") ? UInt64(s.dropFirst(2), radix: 16) : nil
    }

    /// pyelftools (public domain, run as a script, not vendored), for a host with Python but no toolchain:
    /// prints the same LOAD and symbol lines `readelf -lW` / `-sW` would, so one parser reads both.
    static let pyelftoolsScript = """
    import sys
    from elftools.elf.elffile import ELFFile
    from elftools.elf.sections import SymbolTableSection
    with open(sys.argv[1], 'rb') as f:
        e = ELFFile(f)
        for s in e.iter_segments():
            if s['p_type'] == 'PT_LOAD':
                print('LOAD 0x%x 0x%x 0x%x 0x%x 0x%x' % (s['p_offset'], s['p_vaddr'], s['p_paddr'], s['p_filesz'], s['p_memsz']))
        for sec in e.iter_sections():
            if isinstance(sec, SymbolTableSection):
                for i, y in enumerate(sec.iter_symbols()):
                    n = y['st_shndx']
                    print('%d: %x %d %s X X %s %s' % (i, y['st_value'], y['st_size'], y['st_info']['type'][4:],
                          'UND' if n == 'SHN_UNDEF' else 1, y.name))
    """

    /// Python interpreters to try for the pyelftools fallback.
    static func pythonCandidates(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        var seen = Set<String>()
        return dirs.map { ($0 as NSString).appendingPathComponent("python3") }
            .filter { seen.insert($0).inserted && FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Reads `path`'s image with the first `readelf` that understands it, else pyelftools.
    /// Blocking: run it off the main actor.
    static func loadImage(path: String, readelf: [String]? = nil, python: [String]? = nil) throws -> Image {
        let tools = readelf ?? readelfCandidates()
        let pythons = python ?? pythonCandidates()
        guard let handle = FileHandle(forReadingAtPath: path) else { throw LoadError.unreadable(path) }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 4)) ?? Data()
        guard magic == Data([0x7f, 0x45, 0x4c, 0x46]) else { throw LoadError.notAnELF(path) }
        var lastError = LoadError.noReadelf
        // Each reader: its LOAD lines, then its symbol lines.
        var readers: [() -> (String?, String?)] = tools.map { tool in { (run(tool, ["-lW", path]), run(tool, ["-sW", path])) } }
        readers += pythons.map { py in { let out = run(py, ["-c", pyelftoolsScript, path]); return (out, out) } }
        for reader in readers {
            let (headerText, symbolText) = reader()
            guard let headers = headerText else { continue }
            let segments = parseProgramHeaders(headers)
            guard !segments.isEmpty else { lastError = .noLoadSegments; continue }
            var image = Image(path: path, segments: [], symbols: parseSymbols(symbolText ?? ""))
            var total: UInt64 = 0
            for segment in segments {
                let size = min(segment.fileSize, maxImageBytes - min(total, maxImageBytes))
                total += size
                try handle.seek(toOffset: segment.offset)
                let bytes = size == 0 ? Data() : ((try? handle.read(upToCount: Int(size))) ?? Data())
                image.segments.append((segment.address, segment.memorySize, bytes))
            }
            return image
        }
        throw lastError
    }

    /// The ELF next to a local dump: the one named like it (`run.vcd` and `run.elf`), else the only
    /// `*.elf` there, else `prog.elf` (the machine checks' fixtures).
    static func elfBeside(dumpPath: String) -> String? {
        let dir = (dumpPath as NSString).deletingLastPathComponent
        let stem = ((dumpPath as NSString).lastPathComponent as NSString).deletingPathExtension
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let elves = names.filter { ($0 as NSString).pathExtension.lowercased() == "elf" }.sorted()
        let pick = elves.first { ($0 as NSString).deletingPathExtension == stem }
            ?? (elves.count == 1 ? elves[0] : elves.first { $0 == "prog.elf" })
        return pick.map { (dir as NSString).appendingPathComponent($0) }
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func message(for error: Error) -> String {
        switch error as? LoadError {
        case .noReadelf:
            return String(
                localized: "waveformMachine.elf.noReadelf",
                defaultValue: "No readelf or pyelftools found. Install a RISC-V toolchain or LLVM (for example brew install llvm), set RISCV, or pip install pyelftools."
            )
        case .notAnELF(let path):
            return String(format: String(localized: "waveformMachine.elf.notAnELF", defaultValue: "%@ is not an ELF file."), (path as NSString).lastPathComponent)
        case .noLoadSegments:
            return String(localized: "waveformMachine.elf.noLoadSegments", defaultValue: "The ELF file has no loadable segments.")
        case .unreadable(let path):
            return String(format: String(localized: "waveformMachine.elf.unreadable", defaultValue: "Could not read %@."), (path as NSString).lastPathComponent)
        case nil:
            return error.localizedDescription
        }
    }

    // MARK: The page's strings

    /// Strings of the Machine section (cmux-machine.js), merged into `WaveformDebugger.pageStrings()`.
    static func pageStrings() -> [String: String] {
        [
            "machineTitle": String(localized: "waveformMachine.title", defaultValue: "Machine"),
            "machineRegisters": String(localized: "waveformMachine.registers", defaultValue: "Registers"),
            "machineMemory": String(localized: "waveformMachine.memory", defaultValue: "Memory"),
            "machineCsrs": String(localized: "waveformMachine.csrs", defaultValue: "CSRs"),
            "machineHistory": String(localized: "waveformMachine.history", defaultValue: "History"),
            "machineHide": String(localized: "waveformMachine.hide", defaultValue: "Hide Machine State"),
            "machineBuilding": String(localized: "waveformMachine.building", defaultValue: "Reading the commit stream…"),
            "machineSource": String(localized: "waveformMachine.source", defaultValue: "%1$@ · NRET %2$@ · %3$@ commits"),
            "machineSourceTooltip": String(
                localized: "waveformMachine.sourceTooltip",
                defaultValue: "Memory masks: %1$@-relative. Program image: %2$@. Click to choose another stream."
            ),
            "machineNoImage": String(localized: "waveformMachine.noImage", defaultValue: "none (Load ELF…)"),
            "machineNoStream": String(
                localized: "waveformMachine.noStream",
                defaultValue: "No commit stream (RVFI) in this waveform. Right-click a signal and choose Use as Commit to pick one."
            ),
            "machineOffer": String(
                localized: "waveformMachine.offer",
                defaultValue: "No RVFI stream, but %@ look like a commit valid and pc. Right-click them and choose Use as Commit."
            ),
            "machineBudget": String(
                localized: "waveformMachine.budget",
                defaultValue: "The commit stream changes too often to read here (at %@)."
            ),
            "machineReadFailed": String(localized: "waveformMachine.readFailed", defaultValue: "Could not read the commit stream: %@"),
            "machineModeCycle": String(localized: "waveformMachine.modeCycle", defaultValue: "Cycle"),
            "machineModeInstruction": String(localized: "waveformMachine.modeInstruction", defaultValue: "Instruction"),
            "machineModeAuto": String(localized: "waveformMachine.modeAuto", defaultValue: "Auto: %@"),
            "machineModeTooltip": String(
                localized: "waveformMachine.modeTooltip",
                defaultValue: "What F10 and Shift-F10 step by. Auto steps by instruction while this section has focus. Click to change."
            ),
            "machineCommitTooltip": String(localized: "waveformMachine.commitTooltip", defaultValue: "Before commit %1$@ of %2$@"),
            "machineTrap": String(localized: "waveformMachine.trap", defaultValue: "trap"),
            "machineFromWrite": String(localized: "waveformMachine.fromWrite", defaultValue: "Written by commit %@"),
            "machineFromRead": String(
                localized: "waveformMachine.fromRead",
                defaultValue: "Never written before here; commit %@ read this value"
            ),
            "machineFromElf": String(localized: "waveformMachine.fromElf", defaultValue: "From the ELF image"),
            "machineUnknown": String(localized: "waveformMachine.unknown", defaultValue: "Unknown: not written or read yet"),
            "machinePendingBytes": String(localized: "waveformMachine.pendingBytes", defaultValue: "This commit writes %@"),
            "machineAddressPlaceholder": String(localized: "waveformMachine.addressPlaceholder", defaultValue: "Address, as in $sp or 0x80001000"),
            "machineAddressTooltip": String(
                localized: "waveformMachine.addressTooltip",
                defaultValue: "An address expression: a number, a register ($sp), a symbol or arithmetic. Enter shows it."
            ),
            "machineUnitTooltip": String(localized: "waveformMachine.unitTooltip", defaultValue: "Unit: bytes, halfwords, words or giant (8 bytes)"),
            "machineFormatTooltip": String(
                localized: "waveformMachine.formatTooltip",
                defaultValue: "Format: hex, signed, unsigned, char, instructions or string"
            ),
            "machineWhoLastWrote": String(localized: "waveformMachine.whoLastWrote", defaultValue: "Who Last Wrote This"),
            "machinePreviousWrite": String(localized: "waveformMachine.previousWrite", defaultValue: "Go to Previous Write"),
            "machineNextWrite": String(localized: "waveformMachine.nextWrite", defaultValue: "Go to Next Write"),
            "machineCopy": String(localized: "waveformMachine.copy", defaultValue: "Copy Value"),
            "machineBreakWhenWritten": String(localized: "waveformMachine.breakWhenWritten", defaultValue: "Break When Written"),
            "machineNoWriter": String(localized: "waveformMachine.noWriter", defaultValue: "Nothing wrote this before here."),
            "machineNoNextWrite": String(localized: "waveformMachine.noNextWrite", defaultValue: "Nothing writes this after here."),
            "machineWrittenBy": String(localized: "waveformMachine.writtenBy", defaultValue: "%1$@ was last written by commit %2$@ at pc %3$@"),
            "machineRebuild": String(localized: "waveformMachine.rebuild", defaultValue: "Find the Commit Stream Again"),
            "machineForgetPicks": String(localized: "waveformMachine.forgetPicks", defaultValue: "Forget the Signals I Picked"),
            "machineLoadElf": String(localized: "waveformMachine.loadElf", defaultValue: "Load ELF…"),
            "machineUseAsCommit": String(localized: "waveformMachine.useAsCommit", defaultValue: "Use as Commit"),
            "machineOrderGaps": String(
                localized: "waveformMachine.orderGaps",
                defaultValue: "The commit order skips %@ times: some commits are missing from the dump."
            ),
            "machinePcXZ": String(localized: "waveformMachine.pcXZ", defaultValue: "%@ commits have an unknown (x) pc."),
            "machineSilentChannels": String(localized: "waveformMachine.silentChannels", defaultValue: "Channels that never commit: %@"),
            "machineRdZero": String(
                localized: "waveformMachine.rdZero",
                defaultValue: "%@ commits write a nonzero value to x0 (ignored; RVFI says it must be 0)."
            ),
            "machineRegDisagree": String(
                localized: "waveformMachine.regDisagree",
                defaultValue: "%1$@ register reads disagree with the replay; the first is %2$@ at commit %3$@."
            ),
            "machineMemDisagree": String(
                localized: "waveformMachine.memDisagree",
                defaultValue: "%1$@ memory reads disagree with the replay; the first is at %2$@, commit %3$@."
            ),
            "machineWrongElf": String(
                localized: "waveformMachine.wrongElf",
                defaultValue: "A load disagrees with the ELF image: is it the program this run executed?"
            ),
            "machineSequences": String(localized: "waveformMachine.sequences", defaultValue: "Sequences"),
            "machineSeqPlaceholder": String(localized: "waveformMachine.seq.placeholder", defaultValue: "For example {lw} as L ##1 rs1 == L.rd"),
            "machineSeqTooltip": String(
                localized: "waveformMachine.seq.tooltip",
                defaultValue: "Committed instructions in order: steps joined by ##1 (next), ##[m:n] or ##[1:$]. A step is {text}, /regex/ or a condition on rd, rs1, rs2, imm, cls, pc, mem_addr…; as NAME names it. Enter searches."
            ),
            "machineSeqLandEnd": String(localized: "waveformMachine.seq.landEnd", defaultValue: "Go to: last step"),
            "machineSeqLandStart": String(localized: "waveformMachine.seq.landStart", defaultValue: "Go to: first step"),
            "machineSeqLandTooltip": String(
                localized: "waveformMachine.seq.landTooltip",
                defaultValue: "Where clicking a match puts the marker. Click to change."
            ),
            "machineSeqCount": String(localized: "waveformMachine.seq.count", defaultValue: "Matches: %1$@ (%2$@ ms)"),
            "machineSeqCountMore": String(localized: "waveformMachine.seq.countMore", defaultValue: "Matches so far: %1$@ (%2$@ ms)"),
            "machineSeqContinue": String(localized: "waveformMachine.seq.continue", defaultValue: "Continue"),
            "machineSeqCopyCsv": String(localized: "waveformMachine.seq.copyCsv", defaultValue: "Copy as CSV"),
            "machineSeqEmpty": String(localized: "waveformMachine.seq.empty", defaultValue: "Type a sequence to search for."),
            "machineSeqEmptyStep": String(localized: "waveformMachine.seq.emptyStep", defaultValue: "A step is empty (nothing between two ##)."),
            "machineSeqBadDelay": String(
                localized: "waveformMachine.seq.badDelay",
                defaultValue: "A delay must be ##n, ##[m:n] with m ≤ n, or ##[m:$]."
            ),
            "machineSeqBadRegex": String(localized: "waveformMachine.seq.badRegex", defaultValue: "A /regex/ is not valid."),
            "machineSeqBadAssign": String(
                localized: "waveformMachine.seq.badAssign",
                defaultValue: "A local variable must be written (condition, name = expression)."
            ),
            "machineSeqUnknownCapture": String(
                localized: "waveformMachine.seq.unknownCapture",
                defaultValue: "%@ refers to a step that is not named before it (as NAME)."
            ),
            "machineSeqTooManySteps": String(localized: "waveformMachine.seq.tooManySteps", defaultValue: "A sequence can have at most 16 steps."),
            "machineGated": String(
                localized: "waveformMachine.gated",
                defaultValue: "%@ commits that are not loads or stores left values on the memory signals; they were ignored."
            ),
        ]
    }
}
