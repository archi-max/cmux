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
   over SSH and runs `build.sh` on the host. It finds Verdi (`$VERDI_HOME`, `verdi` on `PATH`, environment modules,
   common install roots) and Node.js 18 or later, compiles the addon with the host's C++ compiler, checks that it
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
| `valueAt`, `edge`, `search` | The value at a time; the next or previous change, rise or fall; the next match of a value pattern |
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
- A whole-dump load (a zoomed-out view, or the walk behind a cold read) is cut into time pieces that every worker
  takes from one shared queue, about 250 ms of work each (100 ms in the background). A cheap signal added after a
  heavy one waits for one piece at most, a heavy one is spread over the pool, and a pan never waits for a whole
  load. Cancelling a load's last request keeps it going in the background (at most 8 such loads, the furthest along); `free` of the signal drops it.
  Pieces wait in `/dev/shm` files until their join, which deletes them; that is RAM no worker's memory guard sees, so
  their total is capped (`FSDB_SHM_CAP`, 512 MB): above it, only the load nearest done gets more pieces.
- Stored and rebuilt signals load differently. On open, the helper lists the signals the dump stores, using
  `fsdbdebug -top_n_var 0` (from `FSDB_FSDBDEBUG` or `$VERDI_HOME/bin`), run under `nice` with a memory and
  time watchdog (`FSDB_FSDBDEBUG_TIMEOUT_MS`, 300 s). The result is cached next to the index (`kinds.v1.json`).
  Everything else is rebuilt by the reader on load. Until the list is ready, or if the tool is missing, loads
  run as above.
  - A stored signal pays a fixed cost per reader call (about 110 ms on a 1.7 GB dump, learned as it runs), so
    cheap ones are loaded several at a time in one call, and a heavy one gets a few large pieces, not many small ones.
  - A rebuilt signal pays about 190 ms of setup on each worker it touches (`FSDB_SEC_SETUP_MS`), so it is spread
    over only as many workers as its measured cost repays.
- *(coming)* `searchText`: value searches on rows shown as RISC-V, ASCII or alias text are formatted and matched on
  the host, with the viewer's own formatters (`formats.js`, bundled from the VaporView patch).

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
