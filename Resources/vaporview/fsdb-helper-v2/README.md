# FSDB helper v2

cmux's waveform viewer reads FSDB dumps through this helper. It runs on the remote host that holds the dump, next to
the dump, and answers the viewer over one SSH connection. The viewer asks only for the data it is about to draw, so
a multi-gigabyte dump opens in seconds and never crosses the network whole.

This folder is uploaded to the host and compiled there. For the viewer side, see
[docs/vaporview/README.md](../../../docs/vaporview/README.md).

## Why it exists

FSDB can only be read with Verdi's FSDB reader, a set of proprietary Linux libraries. They don't run on macOS, and
they may not be redistributed. So the reader has to run on a Linux host that already has Verdi, and cmux has to
build against that host's copy.

## The flow

```
 Mac                                                     remote host
 ──────────────────────────────────────────              ─────────────────────────────────────────────────────────
 viewer frame (webview.js, window_cache.ts)
    │ {command: 'v2', req}  ▲ v2-reply + bytes
    ▼                       │
 host.js ── POST to the served FSDB URL ──┐
                                          ▼
 WaveformFSDBHelper.swift ── ssh, one per viewer ──▶  cmux-helper-v2.sh   (privacy check, nice, private run dir)
   request ids, allowlist,   JSON lines on stdin          │
   timeouts, fallback        ◀── JSON + bytes on fd 3 ─   helper.js        coordinator: hierarchy, routing,
                                                          │                cancel, caches, derived signals
                                                          ├─ worker.js ×N  each has the dump open and a store
                                                          │     │
                                                          │     ▼
                                                          │  fsdb_reader.node  (VaporView's addon + cmux's
                                                          │     │               window, derive and packed code)
                                                          │     ▼
                                                          │  Verdi FsdbReader (libnffr.so), from the host's install
```

1. **The page asks** (`window_cache.ts` in the VaporView patch) only for what it draws: windows, values, edges, searches.
2. **The Mac relays** only the commands the page uses, and `open` only of the panel's own file.
3. **The host answers.** `helper.js` answers the netlist itself and routes signal work to a pool of `worker.js`
   processes, each keeping its signals' changes in a compact C++ store, so the file is walked once.
4. **Replies** are one JSON line, optionally followed by `binLength` raw bytes, on fd 3.

## Launch and build

On the first open of an FSDB on a host:

1. cmux runs the launcher from `~/.cache/cmux/fsdb-helper-v2/<version>-<machine>` on the host. `<version>` hashes
   every file in this folder, so a cmux update that changes the helper rebuilds it once.
2. Exit 87 means "not installed, or built for a Node.js or Verdi that is gone". cmux then pipes a tar of this folder
   over SSH and runs `build.sh` on the host. It finds Verdi (`$VERDI_HOME`, `verdi` on `PATH`, or after
   `CMUX_VERDI_SETUP`, a command the user sets that puts it on `PATH`) and Node.js 18 or later, compiles the addon with the host's C++ compiler, checks that it
   loads, and installs it under a lock. A working install is never replaced half-way.
3. `cmux-helper-v2.sh` refuses to run (exit 86) an install that anyone but the user can write, since it would run
   that code. It starts `helper.js` under `nice`, in a private run directory on node-local `/tmp`.
4. The helper prints a ready line, and the viewer sends `open`.

If v2 can't be built or doesn't get ready, cmux falls back to the whole-signal helper in `../fsdb-helper/`, and the
status strip says so, with a Retry Windowed button. The "FSDB signal loading" setting can force whole signals.

## Protocol

Requests are `{id, cmd, ...}`. Replies are `{id, result, ms}` or `{id, error}`, and may come back out of order.
Times are integers in the dump's unit. The full list, with every field, is the header of
[`helper.js`](helper.js).

| Command | Answers |
| --- | --- |
| `open`, `children` | Metadata and top scopes; one scope's children |
| `window {signals, t0, t1, buckets}` | A signal's changes in `[t0, t1)`. Exact when there are at most 2 × `buckets` changes; otherwise each bucket's first and last change plus a count per bucket. Sent as deflated `[u64 delta][value]` records |
| `valueAt`, `edge`, `search` | The value at a time (with `prev: true`, also each signal's last real change at or before it, for trace-X); the next or previous change, rise or fall; the next match of a value pattern. A signal too big for a worker's store (its whole load fails on the cap, or its size projected from fsdbdebug's change count, or for an unlisted row from the densest window drawn of it, says it would) is answered from ranged reads that grow x8 from t up to the first hit |
| `count` | A signal's total change count, when known without a walk (the viewer uses it to load small signals whole) |
| `cancel {id}` | Stops a request. Its reply becomes `{cancelled: true}` |
| `signals` | The v1 whole-signal reply, for compatibility |

The helper also has `derive` (a signal from a SystemVerilog expression) and `searchAll` (a search over many
signals, streaming `partial` results); the Mac relay doesn't forward them yet.

What is streamed, and when:
- The viewer tiles time in powers of two, 1024 buckets per tile (256 for signals wider than 64 bits), and requests the tiles on screen plus one screen
  either side and one zoom level out. Panning back hits the same tiles.
- A signal with at most 350,000 changes is loaded whole once its count is known, within byte limits (128 MB per
  signal, 512 MB in total), and is then an ordinary local signal. Only big or dense signals stay windowed.
- A signal not yet in a worker's store is read "cold": a small time range is read directly from the file, and the
  full walk continues in the background.
  Stored signals in one such read go to one worker in one call; rebuilt ones are spread over the other free workers.
- A whole-dump load (a zoomed-out view, or the walk behind a cold read) is cut into time pieces that every worker
  takes from one shared queue, about 250 ms of work each (100 ms in the background). A cheap signal added after a
  heavy one waits for one piece at most, a heavy one is spread over the pool, and a pan never waits for a whole
  load. Cancelling a load's last request keeps it going in the background (at most 8 such loads, the furthest along); `free` of the signal drops it.
  Pieces wait in `/dev/shm` files until their join, which deletes them; that is RAM no worker's memory guard sees, so
  their total is capped (`FSDB_SHM_CAP`, 512 MB): above it, only the load nearest done gets more pieces.
- Stored and rebuilt signals load differently. On open, the helper lists the signals the dump stores, using
  `fsdbdebug -top_n_var 0` (from `FSDB_FSDBDEBUG` or `$VERDI_HOME/bin`), run under `nice` with a memory and
  time watchdog (`FSDB_FSDBDEBUG_TIMEOUT_MS`, 300 s). The result is cached next to the index (`kinds.v1.json`).
  A signal not on that list is unknown, not rebuilt: wide packed-struct parents, for one, are stored but
  unlisted. The helper keeps three kinds (`p` listed, `s` only on positive evidence, `u` unlisted), each with
  its source in `stats.kinds`. Unknown rows are scheduled like rebuilt ones, but up to `FSDB_WARM_UNKNOWN` (2)
  of them take spare warm-reader slots. Each is judged against its own cold cost: a warm call of its set
  that is slower than the row's last cold read of a similar span (alone) marks it `warmSlow`, and it leaves
  the set; one the warm call beats is `warmProven`, and only those unknowns go to the warm reader for point
  reads. Until the list is ready, or if the tool is missing, loads run as above.
  - A stored signal pays a fixed cost per reader call (about 110 ms on a 1.7 GB dump, learned as it runs), so
    cheap ones are loaded several at a time in one call, and a heavy one gets a few large pieces, not many small ones.
  - A rebuilt signal pays about 190 ms of setup on each worker it touches (`FSDB_SEC_SETUP_MS`), so it is spread
    over only as many workers as its measured cost repays.
- Aliases: a port bound to a single net is rebuilt on every load, though it equals a stored signal (a cluster's
  clk: 6.8 s against 0.43 s). The app names candidate pairs from its design model (`aliasHints`); a pair whose 16
  sampled windows match has its whole streams compared in the background, and only a verified pair is answered
  from the stored signal: until then the rebuilt row answers its own (ranged) data, never another signal's.
  Verified pairs are kept per file (`aliases.v1.json`); one found wrong later is dropped and reported
  (`aliasDropped`) so the page asks again.
- `searchText`: value searches on rows shown as RISC-V, ASCII or alias text are formatted and matched on
  the host, with the viewer's own formatters (`formats.js`, bundled from the VaporView patch). Format `string`
  matches a string or real signal's text with a case-insensitive regular expression.

Variable kinds:
- **Bit vectors** (1 byte per bit: wires, regs, integers, enums...) are sent as `[u64 delta][value]` records.
- **Strings** (SystemVerilog `string`) and **reals** (8-byte double, 4-byte float) come as text records,
  `[u64 delta][u32 length][UTF-8]`; the window header says `text: true` and `kind`, and a real's also carries
  `min`/`max` for the analog view (not on a ranged answer, whose range is only the slice's; the viewer keeps
  the widest it has seen). A real reads as Rust's `f64` text (shortest round-trip digits, `-0`, `NaN`,
  `inf`), the same as a VCD real in the viewer. A string or real change is an edge; a bit pattern `search` and
  expressions refuse them, and they are walked whole, never split or saved to the store cache.
- **Long text** is stored once per distinct value, but a window repeats it per record, so a window carries
  at most 4 KB of each value (cut at a character boundary, ended with `…`). A reply's string records stay
  within 16 MB (`--text-budget-mb`, `FSDB_TEXT_BUDGET_MB`), shared equally by the strings in the request.
  Each string gets at least a quarter, so a request for more than 4 strings can pass 16 MB in all. The cut
  shrinks, down to 256 bytes, so the window fits; a window that doesn't fit even then is a retryable error
  (a narrower window fits). A window that cut a value says `cut: true`, and the viewer then keeps the
  signal windowed rather than loading it whole. `valueAt` and `searchText` use the whole text. A string's header says
  `textMean`, the mean text bytes per change, which the viewer counts before loading it whole.
- **Events** keep every occurrence, repeats included, in stored and cold searches alike.
- **Parameters and time vars** are listed as Real by the reader, but most are bit vectors and work as
  expression operands; the addon refuses an operand whose values really are text or reals.
- Any other encoding (for example 2 bytes per bit) is an error for that signal alone. Errors that can't
  change on a retry (unsupported encoding, 0 bits, not a bit signal) come with `permanent: true`: the viewer
  labels the row once, without "(retrying)", and doesn't ask again. Over the store cap is not permanent: a
  zoomed-in range of the signal still loads through the ranged cold path.

## Timeouts and recovery

In this tree:
- The helper must print its ready line within 90 s. The build is cut off after 10 minutes. A request times out
  after 5 minutes on the Mac.
- The viewer gives each request its own timeout: 8 s for a value, 120 s for a search, and for a window 10 s,
  adapted to the round-trip time up to 180 s. A stale request is cancelled, then retried with backoff.
- A v2 that missed its ready timeout is skipped for that host for 10 minutes, so each new viewer doesn't wait again.
- A worker that dies is restarted and reopens the file. Its queued and running parts fail with an error, so no
  request waits forever. After more than 5 restarts in 30 s the helper gives up and reports the error.

*(coming)*:
- **Open timeout.** An `open` that doesn't answer in 120 s relaunches the helper once and resends the open. A second
  timeout reports "did not open the file in time". The whole open, relaunch included, is bounded at 240 s.
- **Stdin watchdog.** The launcher runs under a watchdog. When the SSH session's stdin closes (the viewer closed, or
  a relaunch) and the helper hasn't exited 3 s later, the watchdog stops the launcher, then kills the coordinator and
  workers, children first. A stuck reader no longer leaves processes behind on the host.
- **Protocol pinning.** A relaunch keeps the protocol the page already uses. It never falls back to v1 in the middle
  of a page.

## Decisions

| Decision | Why |
| --- | --- |
| Read the dump in place, on its host | Dumps are often gigabytes. Downloading or converting one (to VCD or FST) takes minutes and disk on both sides, and must be redone after each simulation. Reading in place sends only what's drawn. |
| Compile on the host, never ship binaries | The reader links Verdi's proprietary libraries. Building against the host's own install means no Synopsys code is ever redistributed, and the addon always matches that host's Verdi and Node.js. See [NOTICE](NOTICE). |
| Windows with caps, not whole signals | A busy signal can have hundreds of millions of changes. Decimated windows keep each reply proportional to the screen. Caps bound every reply: buckets per request, store budget per worker, hybrid whole-load limits. |
| A pool of workers, sized from the host | One reader process walks one signal at a time, and one whole load costs 1 ms to 10 s on a big dump, can't be interrupted, and costs about the same in time slices. So several processes, each with the file open, take whole loads in time pieces from one queue: requests before background work, nearly done loads first, then new ones, then the least remaining work. `--workers auto` (cmux's default) runs half the host's cores, at most 8, and only as many as fit in its free memory minus 4 GB. The coordinator never walks, so it always answers the netlist and cancels at once. |
| Warm readers for the rows being viewed | A cold ranged read pays the reader's navigation floor on every call (~110 ms on a 1.7 GB dump, ~650 ms on 10 GB). A reader in navDB-once mode (`ffrSetLoadNavDBOnlyOnce`) keeps its navigation, but every signal it reads must be in its first load, so a warm reader is its own process with a fixed set: stored (primary) rows asked for in the last 3 s and not stored whole, at most 16 (`FSDB_WARM_SIGNALS`). It does its first load before it takes requests. Rows asked for together go to it as one call per window, and rows outside the set are read cold in parallel. A new set (a quarter of the viewed rows outside it) is built in the background once the requests pause for 150 ms, and the old reader retires. A stream that never pauses (a pan held down) gets a new set after 2 s, and that wait doubles (up to 16 s) until the requests pause for 1 s. Memory is bounded per reader and in total. A reader's calls fail at twice `FSDB_WARM_RSS_MB` (default 600), and the addon undoes a load past that bound before walking. The coordinator reads each warm process's RSS from outside, so a native call that can't yield is seen too, and kills a reader over that bound. Ready, building and retiring readers together are at most twice `FSDB_WARM_READERS` processes and `FSDB_WARM_TOTAL_MB` (default twice the cap per reader). All processes reading the dump, cold workers included, are at most `FSDB_READERS` (default: the workers plus `FSDB_WARM_READERS`). A set rebuilt at that budget retires the old reader first, and its rows are read cold until the new one is ready. Unlisted rows join a set one at a time, on trial. A row leaves the set if it adds more than max(10 ms, 10% of the call) to its set's warm calls, if the unlisted rows kept so far would add more than max(10 ms, 10%) together over the primaries-only call (both plus a noise margin, the spread of the primaries-only calls, at most 5 ms; `FSDB_WARM_BOUND_FRAC` sets the 10%), or if its call is slower than its own cold read. Each comparison uses calls over the same span (within 10%), and a fresh reader's first 2 calls aren't counted. The memory total is sampled every 500 ms, so it can be overshot for up to one interval before readers are killed. A call unanswered in `FSDB_WARM_CALL_MS` (60 s) ends its reader. Only growth well past a reader's own baseline rebuilds the same set. A set too big for the cap is halved and the old reader goes first. A set that failed (or was halved, or rebuilt for growth) backs off from 5 s, doubling, up to 5 min. Rebuilt (secondary) rows stay cold: their per-window rebuild costs the same either way. Unlisted rows can take up to 2 spare slots (see the kinds note above). 10 one-row requests at 0.1% of the dump: 553 → 12 ms (1.7 GB), 3.2 s → 34 ms (10 GB). `FSDB_WARM=0` turns it off. Answers equal the cold path change for change (`scripts/waveform-viewer-checks/fsdb-sched/warm-parity.mjs`). Point reads (valueAt, and valueAt {prev} while its search span is at most 1% of the dump) of rows in the set go to it too; prev is each row's real last change, and wider rounds are read cold. For 16 stored rows, warm against cold, p50: valueAt 9 against 235 ms and a trace step 38 against 277 ms (1.7 GB); 18 against 1,338 ms and 151 against 1,490 ms (10 GB), with equal answers (`warm-point-bench.mjs`). The reader's max tag is the current view window's end, so a warm reader keeps the file's end from before its first load. |
| Replies on fd 3 | The FSDB reader prints to stdout. A separate descriptor keeps the protocol clean. |
| Private install, private run directory | The helper runs code and loads libraries from its install. An install others can write is refused. The reader's log directory goes to a private folder on node-local `/tmp`, not a shared home. |
| Memory bounds | Each worker has an RSS cap (1 GB by default). Over it, the store shrinks first, then the worker is replaced when idle. A load that would pass twice the cap is undone. |
| Store cache on disk | Walked signals are saved under `/tmp/<user>-cmux-helper/` (keyed by path, size, mtime and inode, LRU-bounded), so a reopened dump draws about 20× faster. Not on an NFS home. |
| Background work yields on SIGUSR2 | Background walks poll for SIGUSR2 every 4096 changes and between signals, and yield to interactive requests. A `cancel` drops queued parts; running ones finish and are discarded. A whole load nobody else waits for goes on in the background. *(coming)* searchText is cancelled by SIGUSR2 too, because a SIGINT-based cancel killed workers and cancelled unrelated requests. |
| Node.js on the host | It reuses VaporView's Node-API reader addon and worker code unmodified. The cost is Node.js 18 or later on the host (found on `PATH` and in common places, or set with `CMUX_FSDB_NODE`; build exit 11 if missing). |
| Watchdog kills only its own children *(coming)* | A pid can be reused once a process exits. The watchdog signals only processes that are still children of the launch shell, so it never touches another user's process. |

## Files

| File | Role |
| --- | --- |
| [`helper.js`](helper.js) | Coordinator: protocol, routing, splitting, cancel, store cache, `derive`, `searchAll` |
| [`worker.js`](worker.js) | A worker: the file open, its store, background work that yields |
| [`expr.js`](expr.js) | `derive` expressions, with SystemVerilog sizing |
| [`addon/fsdb_reader.cpp`](addon/fsdb_reader.cpp) | VaporView's reader addon, unmodified apart from a license header |
| [`addon/window.cpp.inc`](addon/window.cpp.inc), [`derive.cpp.inc`](addon/derive.cpp.inc), [`deval.h`](addon/deval.h), [`packed.cpp.inc`](addon/packed.cpp.inc) | cmux's additions: the store, windows, cold reads, derived signals, packed replies |
| [`build.sh`](build.sh) | Finds Verdi, Node.js and a compiler; builds and installs privately |
| [`cmux-helper-v2.sh`](cmux-helper-v2.sh) | The launcher: privacy check, exit 86 or 87, `nice`, run directory, fd 3 |
| [`../../../Sources/Panels/WaveformFSDBHelper.swift`](../../../Sources/Panels/WaveformFSDBHelper.swift) | The Mac side: install, launch, relay, timeouts, fallback |

Tests: `scripts/waveform-viewer-checks/run.sh windowed` runs the real Swift relay and `build.sh` against a mock helper
on the Mac. `windowed-launcher` and `windowed-fsdb` run the real helper on a host with Verdi.

## License

GPL-3.0, as VaporView, which the reader addon and the original helper come from. The Node-API headers in
`third_party/` are MIT. Verdi's FSDB reader is not included; it is linked on the host from the host's own install.
See [NOTICE](NOTICE).
