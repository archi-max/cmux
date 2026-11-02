import CmuxSyntaxHighlighting
import Darwin
import Foundation

/// One long-lived ssh run per host that serves the Files panel's and the
/// terminal links' file reads, so an open costs one round trip on an open
/// channel instead of a new ssh exec (a session, the login shell's startup
/// files, a process on this Mac) per step.
///
/// The host side is a fixed POSIX `sh` script, sent once as the ssh command
/// (``serverScript``). It reads one request per line and answers each with a
/// header line and an exact number of bytes. It runs a fixed set of reads:
/// `stat`, `read` (a capped whole-file read), `probe` (the first readable of
/// several spellings, `~` expanded, as ``RemoteFileProbe``) and `list` (the
/// Files panel's `ls`). It never runs a command named by a request: paths
/// travel base64-encoded and are decoded into variables that are only ever
/// used quoted, so no path byte reaches the shell's parser.
///
/// Requests are numbered and answered in order. A request that gets no answer
/// in time, a malformed answer or the channel's end tears the channel down and
/// fails every waiting request with ``Failure/unavailable``; callers then use
/// the per-exec path, and a new channel is started only after a backoff. When
/// the channel's stdin ends (closed, or ssh gone), a read stuck on the host is
/// killed there by the script's watchdog, as the FSDB helper's.
final class SSHFileChannel: @unchecked Sendable {
    struct Reply: Equatable, Sendable {
        var modificationTime: Int64
        var size: Int64
        /// Which candidate a `probe` read.
        var index: Int
        /// The host path read (`~` expanded), for `read` and `probe`.
        var path: String?
        var data: Data
    }

    enum Failure: Error, Equatable {
        /// No channel (not started, down, timed out, malformed): use the per-exec path.
        case unavailable
        /// No candidate is a regular readable file.
        case noFile
        /// The file is larger than the cap; nothing of it was sent.
        case tooLarge
        /// The host reported an error for this request.
        case failed(Int32)
    }

    /// The ssh run for `command` (the wrapped server script): executable and arguments.
    typealias Launch = @Sendable (_ command: String) -> (executable: URL, arguments: [String])

    static let readyPrefix = "cmux-files-ready 1 "
    static let okStatus: Int32 = 0
    static let noFileStatus: Int32 = 3
    static let tooLargeStatus: Int32 = 4
    /// The largest read the channel serves; larger files stream through their own
    /// ssh run, so neither side holds a whole large file (the host stages each read
    /// in a private temporary file to frame it exactly).
    static let maximumReadBytes: Int64 = 32 << 20
    /// How long a stuck read on the host may outlive the channel's stdin.
    static let stuckGrace = 3

    private let launch: Launch
    private let readyTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private let idleTimeout: TimeInterval
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var generation = 0
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Reply, Error>] = [:]
    private var downUntil: Date?
    private var backoff: TimeInterval = 1
    private var launches = 0
    private var idleWork: DispatchWorkItem?
    private let writeQueue = DispatchQueue(label: "com.cmuxterm.ssh-file-channel.write")

    init(
        launch: @escaping Launch,
        readyTimeout: TimeInterval = 10,
        requestTimeout: TimeInterval = 60,
        idleTimeout: TimeInterval = 10 * 60
    ) {
        self.launch = launch
        self.readyTimeout = readyTimeout
        self.requestTimeout = requestTimeout
        self.idleTimeout = idleTimeout
    }

    deinit { close() }

    /// ssh runs started so far (for the round-trip checks).
    var launchCount: Int { lock.withLock { launches } }

    // MARK: Requests

    /// `<mtime> <size>` of a regular file.
    func stat(_ path: String) async throws -> Reply {
        try await request(op: "stat", words: [Self.encode(path)])
    }

    /// A regular file's stamp (read first) and bytes; at most `maxBytes + 1`
    /// bytes when capped, ``Failure/tooLarge`` when its size is over the cap.
    func read(_ path: String, maxBytes: Int64?) async throws -> Reply {
        try await request(op: "read", words: [Self.cap(maxBytes), Self.encode(path)])
    }

    /// The first of `candidates` that is a regular readable file (`~` and
    /// `~/…` expanded on the host), read as ``read(_:maxBytes:)``.
    func probe(_ candidates: [String], maxBytes: Int64?) async throws -> Reply {
        guard !candidates.isEmpty else { throw Failure.noFile }
        return try await request(op: "probe", words: [Self.cap(maxBytes)] + candidates.map(Self.encode))
    }

    /// The Files panel's `ls -1paF` (`-A` with hidden files) of a folder.
    func list(_ path: String, showHidden: Bool) async throws -> Data {
        try await request(op: showHidden ? "lista" : "list", words: [Self.encode(path)]).data
    }

    /// Ends the channel; waiting requests fail with ``Failure/unavailable``.
    func close() {
        tearDown(generation: nil, backoff: false)
    }

    private static func encode(_ path: String) -> String { Data(path.utf8).base64EncodedString() }
    private static func cap(_ maxBytes: Int64?) -> String { maxBytes.map { String(max(0, $0)) } ?? "-1" }

    private func request(op: String, words: [String]) async throws -> Reply {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Reply, Error>) in
            lock.lock()
            guard let input = startLocked() else {
                lock.unlock()
                continuation.resume(throwing: Failure.unavailable)
                return
            }
            let id = nextId
            nextId += 1
            pending[id] = continuation
            let gen = generation
            let line = Data((["\(id)", op] + words).joined(separator: " ").utf8) + Data([0x0A])
            writeQueue.async { try? input.write(contentsOf: line) }
            scheduleIdleLocked()
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
                guard let self else { return }
                // No answer in time: the server is stuck on this request, and the
                // ones behind it wait on it too.
                if self.lock.withLock({ self.pending[id] != nil && self.generation == gen }) {
                    self.tearDown(generation: gen, backoff: true)
                }
            }
        }
    }

    // MARK: Channel

    /// The running channel's input, starting one if none runs and no backoff
    /// is pending. Called with `lock` held.
    private func startLocked() -> FileHandle? {
        if let input { return input }
        if let downUntil, downUntil > Date() { return nil }
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let (executable, arguments) = launch(SlangWorkspaceRoot.posixShellCommand(Self.serverScript(nonce: nonce)))
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        generation += 1
        let gen = generation
        process.terminationHandler = { [weak self] _ in self?.tearDown(generation: gen, backoff: true) }
        do {
            try process.run()
        } catch {
            markDownLocked()
            return nil
        }
        launches += 1
        self.process = process
        self.input = stdin.fileHandleForWriting
        let ready = ReadyFlag()
        let reader = Thread { [weak self] in
            Self.readLoop(fd: stdout.fileHandleForReading.fileDescriptor, nonce: nonce, ready: ready) { event in
                guard let self else { return false }
                return self.handle(event, generation: gen)
            }
            _ = stdout  // keeps the read end open until the loop ends
            self?.tearDown(generation: gen, backoff: true)
        }
        reader.name = "cmux SSH file channel reader"
        reader.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + readyTimeout) { [weak self] in
            if !ready.isSet { self?.tearDown(generation: gen, backoff: true) }
        }
        return stdin.fileHandleForWriting
    }

    private func markDownLocked() {
        downUntil = Date().addingTimeInterval(backoff)
        backoff = min(backoff * 2, 60)
    }

    private func scheduleIdleLocked() {
        idleWork?.cancel()
        let gen = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.lock.withLock({ self.pending.isEmpty && self.generation == gen }) {
                self.tearDown(generation: gen, backoff: false)
            }
        }
        idleWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + idleTimeout, execute: work)
    }

    /// Ends launch `generation` (nil: whichever runs), failing its waiting requests.
    private func tearDown(generation gen: Int?, backoff: Bool) {
        let (process, input, waiting): (Process?, FileHandle?, [CheckedContinuation<Reply, Error>]) = lock.withLock {
            guard gen == nil || gen == generation, self.process != nil || self.input != nil else { return (nil, nil, []) }
            let old = (self.process, self.input, Array(pending.values))
            self.process = nil
            self.input = nil
            pending.removeAll()
            idleWork?.cancel()
            idleWork = nil
            if backoff { markDownLocked() }
            return old
        }
        writeQueue.async { try? input?.close() }
        if let process, process.isRunning { process.terminate() }
        waiting.forEach { $0.resume(throwing: Failure.unavailable) }
    }

    enum Event {
        case ready
        case reply(id: Int, status: Int32, Reply)
    }

    /// Delivers one event of launch `generation`; false if the channel can't go on.
    private func handle(_ event: Event, generation gen: Int) -> Bool {
        switch event {
        case .ready:
            lock.withLock {
                if gen == generation { backoff = 1; downUntil = nil }
            }
            return true
        case let .reply(id, status, reply):
            let waiting: CheckedContinuation<Reply, Error>? = lock.withLock {
                gen == generation ? pending.removeValue(forKey: id) : nil
            }
            guard let waiting else { return true }
            switch status {
            case Self.okStatus: waiting.resume(returning: reply)
            case Self.noFileStatus: waiting.resume(throwing: Failure.noFile)
            case Self.tooLargeStatus: waiting.resume(throwing: Failure.tooLarge)
            default: waiting.resume(throwing: Failure.failed(status))
            }
            return true
        }
    }

    /// Reads the channel's stdout until its end or a malformed answer: lines
    /// before the ready line (startup-file banners) are skipped, then each
    /// answer is `R <id> <status> <mtime> <size> <bytes> <index> <b64 path or ->`
    /// and `<bytes>` raw bytes. Plain read(2): no Foundation read can raise here.
    static func readLoop(fd: Int32, nonce: String, ready: ReadyFlag, deliver: (Event) -> Bool) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        var isReady = false
        let readyLine = Data((readyPrefix + nonce).utf8)
        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return }
            buffer.append(contentsOf: chunk[0..<n])
            while true {
                guard let newline = buffer.firstIndex(of: 0x0A) else { break }
                let line = buffer[buffer.startIndex..<newline]
                if !isReady {
                    if line == readyLine {
                        isReady = true
                        ready.set()
                        guard deliver(.ready) else { return }
                    }
                    buffer.removeSubrange(buffer.startIndex...newline)
                    continue
                }
                guard let header = String(data: line, encoding: .utf8),
                      let parsed = parseHeader(header) else { return }
                let start = newline + 1
                guard buffer.endIndex - start >= parsed.bytes else { break }
                var reply = parsed.reply
                reply.data = Data(buffer[start..<(start + parsed.bytes)])
                buffer.removeSubrange(buffer.startIndex..<(start + parsed.bytes))
                guard deliver(.reply(id: parsed.id, status: parsed.status, reply)) else { return }
            }
        }
    }

    static func parseHeader(_ line: String) -> (id: Int, status: Int32, bytes: Int, reply: Reply)? {
        let f = line.split(separator: " ", omittingEmptySubsequences: false)
        guard f.count == 8, f[0] == "R",
              let id = Int(f[1]), let status = Int32(f[2]),
              let mtime = Int64(f[3]), let size = Int64(f[4]),
              let bytes = Int(f[5]), bytes >= 0, let index = Int(f[6]) else { return nil }
        var path: String?
        if f[7] != "-" {
            guard let data = Data(base64Encoded: String(f[7])), let decoded = String(data: data, encoding: .utf8) else { return nil }
            path = decoded
        }
        return (id, status, bytes, Reply(modificationTime: mtime, size: size, index: index, path: path, data: Data()))
    }

    final class ReadyFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    // MARK: Host script

    /// The POSIX `sh` server. `serve` answers requests from stdin; it runs
    /// behind a watchdog on that stdin (a fifo fed by `cat`), so when the
    /// channel's stdin ends and `serve` hasn't exited ``stuckGrace`` s later
    /// (a read stuck on NFS), it and its children are stopped and killed.
    static func serverScript(nonce: String) -> String {
        """
        set -f
        st() { stat -L -c "%Y %s" -- "$1" 2>/dev/null || stat -L -f "%m %z" -- "$1" 2>/dev/null; }
        dec() { printf %s "$1" | base64 -d 2>/dev/null || printf %s "$1" | base64 -D 2>/dev/null; }
        enc() { printf %s "$1" | base64 | tr -d '\\n'; }
        reply() { printf 'R %s %s %s %s %s %s %s\\n' "$1" "$2" "${3:-0}" "${4:-0}" "${5:-0}" "${6:-0}" "${7:--}"; }
        frame() {
          n=$(wc -c < "$W/f" | tr -d ' ')
          reply "$1" 0 "$2" "$3" "$n" "$4" "$5"; cat "$W/f"
        }
        send() {
          if [ "$6" -ge 0 ] && [ "$3" -gt "$6" ]; then reply "$1" \(tooLargeStatus) "$2" "$3" 0 "$4" "$(enc "$5")"; return; fi
          if [ "$6" -ge 0 ]; then head -c "$(($6 + 1))" < "$5" > "$W/f"; else cat < "$5" > "$W/f"; fi || { reply "$1" 1; return; }
          frame "$1" "$2" "$3" "$4" "$(enc "$5")"
        }
        serve() {
          echo "\(readyPrefix)\(nonce)"
          while IFS= read -r l; do
            set -- $l
            [ $# -ge 2 ] || continue
            id=$1; op=$2; shift 2
            case $op in
              stat)
                if p=$(dec "$1") && [ -n "$p" ] && [ -f "$p" ] && s=$(st "$p"); then set -- $s; reply "$id" 0 "$1" "$2"
                else reply "$id" \(noFileStatus); fi ;;
              read|probe)
                cap=$1; shift; i=0; found=
                for e in "$@"; do
                  if p=$(dec "$e") && [ -n "$p" ]; then
                    if [ "$op" = probe ]; then case $p in "~") p=$HOME ;; "~/"*) p=$HOME/${p#"~/"} ;; esac; fi
                    if [ -f "$p" ] && [ -r "$p" ] && s=$(st "$p"); then set -- $s; send "$id" "$1" "$2" "$i" "$p" "$cap"; found=1; break; fi
                  fi
                  [ "$op" = probe ] || break
                  i=$((i + 1))
                done
                [ -n "$found" ] || reply "$id" \(noFileStatus) ;;
              list|lista)
                fl=-1paF; [ "$op" = lista ] && fl=-1paFA
                if p=$(dec "$1") && [ -n "$p" ] && QUOTING_STYLE=literal ls $fl -- "$p" > "$W/f" 2>/dev/null; then frame "$id" 0 0 0 -
                else reply "$id" 1; fi ;;
              *) reply "$id" 2 ;;
            esac
          done
        }
        W=$(mktemp -d "${TMPDIR:-/tmp}/cmux-files.XXXXXX") && mkfifo "$W/i" || exit 1
        k() { kill -STOP $1 2>/dev/null; for c in $(pgrep -P $1); do k $c; done; kill -KILL $1 2>/dev/null; }
        m() { [ "$(ps -o ppid= -p $1 2>/dev/null | tr -d ' ')" = "$2" ]; }
        trap : HUP TERM
        exec 9<&0
        { serve; } <"$W/i" 9<&- & L=$!
        { trap : HUP TERM; cat <&9 >"$W/i" 2>/dev/null; exec 9<&-; n=0
          while m $L $$ && [ $n -lt \(stuckGrace) ]; do sleep 1; n=$((n+1)); done
          if m $L $$; then kill -STOP $L; for c in $(pgrep -P $L); do k $c; done; kill -CONT $L; sleep 1; m $L $$ && k $L; fi; } & D=$!
        exec 9<&- 0</dev/null
        while :; do wait $L; s=$?; m $L $$ || break; done
        m $D $$ && k $D
        rm -rf "$W"
        exit $s
        """
    }
}
