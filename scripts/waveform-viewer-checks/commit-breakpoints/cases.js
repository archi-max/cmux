// The cases run.sh commit-breakpoints checks cmux-debugger-commits.js against (a mock commit index
// shaped as cmux-machine.js's window.cmuxWaveform.commits.index() gives it).
/* global window */
async function runCommitCases() {
  const waveform = window.cmuxWaveform;
  const C = waveform.debuggerCommits;
  const out = [];
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  const eq = (name, got, want) => out.push((same(got, want) ? 'ok   ' : 'FAIL ') + name
    + (same(got, want) ? ': ' + JSON.stringify(got) : ': got ' + JSON.stringify(got) + ', want ' + JSON.stringify(want)));
  Object.assign(waveform.strings, {
    debuggerBreakpointPc: 'PC %@', debuggerBreakpointPcAt: '%1$@ (%2$@)', debuggerBreakpointCommitText: 'Next instruction ~ /%@/',
    debuggerBreakpointWritten: '%@ written', debuggerCommitsNone: '%@: no commit stream', debuggerCommitsNoInsn: '%@: no instruction word',
    debuggerCommitError: 'Breakpoint %1$@: %2$@', debuggerCommitBadAddress: 'bad address', debuggerCommitBadLocation: 'bad location',
    debuggerTextError: 'Text breakpoint %1$@: %2$@', debuggerTextNoPattern: 'empty',
    debuggerCommitAddressTooLarge: 'too large', debuggerCommitTextJalHint: '%@: hint',
  });

  // k: time, pc (NaN: x), insn, channel. Two commits share the cycle at 20 (channels 0 and 1).
  const rows = [
    [10, NaN, 0x00000013, 0],          // nop, its pc x
    [20, 0x80000000, 0x00000513, 0],   // li a0,0
    [20, 0x80000004, 0x008002ef, 1],   // jal t0,pc+8 (jal ra prints as jal pc+8)
    [30, 0x80000004, 0x00004501, 0],   // c.li a0,0 (RVC: the low 16 bits)
    [40, 0x80000010, 0x30531073, 0],   // csrw mtvec,t1
    [50, 0x80000004, 0x008002ef, 0],   // jal t0,pc+8
    [60, 0x100000004, 0x00000513, 0],  // li a0,0 above 4 GiB (RV64)
    [70, 0x80000000, 0x0005a683, 0],   // lw a3,0(a1)
  ];
  const makeIndex = (rs, sortedBy, noInsn) => ({ backend: 1, count: rs.length, nret: 2, xlen: 64, sortedBy: sortedBy || 'time',
    time: Float64Array.from(rs.map((r) => r[0])), edge: Int32Array.from(rs.map((r, i) => i)), channel: Uint8Array.from(rs.map((r) => r[3])),
    pc: Float64Array.from(rs.map((r) => r[1])), insn: noInsn ? null : Uint32Array.from(rs.map((r) => r[2])), order: null });
  let ix = makeIndex(rows);
  let indexCalls = 0;
  const writeQueries = [];
  const writes = { a0: [1, 3, 6], 'csr:mtvec': [4], 'mem:4096': [7], 'mem:4098': [4] };
  waveform.commits = {
    index: async () => { indexCalls++; return ix; },
    writesOf: async (q) => {
      writeQueries.push(q.loc);
      const key = typeof q.loc === 'string' ? q.loc : (q.loc.csr ? 'csr:' + q.loc.csr : 'mem:' + q.loc.addr);
      return (writes[key] || []).slice();
    },
  };
  const warnings = [];
  const warn = (text) => warnings.push(text);
  const bp = (kind, item) => Object.assign({ id: 1, kind }, C.fields(kind, item));
  const hits = async (b) => { const t = await C.times(b, warn); return t ? Array.from(t) : t; };

  // ---- the syntax ----
  eq('address 0x', C.parseAddress('0x80000010'), '0x80000010');
  eq('address bare hex (as objdump prints it)', C.parseAddress('8000_0010'), '0x80000010');
  eq('address upper case', C.parseAddress(' DEADBEEF '), '0xdeadbeef');
  eq('address leading zeros', C.parseAddress('0x0000004'), '0x4');
  eq('address: a name is not one', C.parseAddress('main'), null);
  eq('address: 0x alone', C.parseAddress('0x'), null);
  eq('address: 17 digits', C.parseAddress('1' + '0'.repeat(16)), null);
  eq('address 64-bit', C.parseAddress('ffffffff80000000'), '0xffffffff80000000');
  // The commit index keeps PCs as doubles, exact below 2^53: an address from there up is refused (it would
  // hit every PC of its 2 KiB bucket), not searched.
  eq('check pc: 2^53 - 1 is exact', C.check('pc', C.fields('pc', { pc: '1fffffffffffff' })), null);
  eq('check pc: 2^53 is too large', C.check('pc', C.fields('pc', { pc: '20000000000000' })), 'addressTooLarge');
  eq('check pc: RV64 high half', C.check('pc', C.fields('pc', { pcs: ['0x80000000', 'ffffffff80000000'] })), 'addressTooLarge');
  eq('check write: memory ending past 2^53', C.check('write', C.fields('write', { loc: 'mem:0x1ffffffffffffe/4' })), 'addressTooLarge');
  eq('check write: memory below 2^53', C.check('write', C.fields('write', { loc: 'mem:0x1ffffffffffff0/4' })), null);
  eq('too large: said', C.errorText('addressTooLarge'), 'too large');
  eq('location a0', C.parseLocation('a0'), 'a0');
  eq('location X5', C.parseLocation('X5'), 'x5');
  eq('location $sp', C.parseLocation('$sp'), 'sp');
  eq('location fp', C.parseLocation('fp'), 'fp');
  eq('location x32 is no register (nor a CSR)', C.parseLocation('x32'), null);
  eq('location word', C.parseLocation('[0x1000]'), 'mem:0x1000/4');
  eq('location bytes', C.parseLocation('[1000] / 2'), 'mem:0x1000/2');
  eq('location mem [..]', C.parseLocation('mem [0x10]'), 'mem:0x10/4');
  eq('location size 0', C.parseLocation('[0x1000]/0'), null);
  eq('location bad address', C.parseLocation('[main]'), null);
  eq('location csr', C.parseLocation('mstatus'), 'csr:mstatus');
  eq('location csr prefix', C.parseLocation('csr mtvec'), 'csr:mtvec');
  eq('location csr named as a register', C.parseLocation('csr a0'), null);
  eq('location empty', C.parseLocation(''), null);
  eq('location two words', C.parseLocation('a b'), null);
  eq('write fields round trip (memory)', C.fields('write', { loc: 'mem:0x1000/2' }).loc, 'mem:0x1000/2');
  eq('write fields round trip (csr)', C.fields('write', { loc: 'csr:mtvec' }).loc, 'csr:mtvec');
  eq('write fields round trip (register)', C.fields('write', { loc: 'a0' }).loc, 'a0');
  eq('pc fields: same address once', C.fields('pc', { pcs: ['0x80000004', '80000004'] }).pcs, ['0x80000004']);
  eq('pc fields: one bad address, none', C.fields('pc', { pcs: ['0x80000004', 'main'] }).pcs, []);
  eq('pc fields: at most 64', C.fields('pc', { pcs: Array.from({ length: 70 }, (_, i) => '0x' + (i * 4).toString(16)) }).pcs.length, 64);
  eq('pc fields: channel', C.fields('pc', { pc: '0x4', channel: 1 }).channel, 1);
  eq('pc fields: bad channel', C.fields('pc', { pc: '0x4', channel: -1 }).channel, null);
  eq('check pc', C.check('pc', C.fields('pc', { pcs: [] })), 'address');
  eq('check write', C.check('write', C.fields('write', { loc: 'nope nope' })), 'location');
  eq('check commitText empty', C.check('commitText', C.fields('commitText', { pattern: '' })), 'pattern');
  eq('check commitText long', C.check('commitText', C.fields('commitText', { pattern: 'a'.repeat(5000) })), 'patternTooLong');
  eq('check ok', C.check('commitText', C.fields('commitText', { pattern: 'jal' })), null);
  eq('kinds', ['pc', 'commitText', 'write', 'text', 'line'].map(C.isKind), [true, true, true, false, false]);

  // ---- labels ----
  eq('label pc', C.label(bp('pc', { pcs: ['0x80000004', '0x80000010'] })), 'PC 0x80000004, 0x80000010');
  eq('label pc from a listing', C.label(bp('pc', { pc: '0x80000004', listingLabel: 'start+0x4' })), 'start+0x4 (0x80000004)');
  eq('label commitText', C.label(bp('commitText', { pattern: 'jal ra' })), 'Next instruction ~ /jal ra/');
  eq('label word', C.label(bp('write', { loc: 'mem:0x1000/4' })), '[0x1000] written');
  eq('label bytes', C.label(bp('write', { loc: 'mem:0x1000/2' })), '[0x1000]/2 written');
  eq('label csr', C.label(bp('write', { loc: 'csr:mtvec' })), 'mtvec written');

  // ---- PC hits ----
  eq('pc: every commit there, one time per cycle', await hits(bp('pc', { pc: '0x80000004' })), [20, 30, 50]);
  eq('pc: pinned to channel 1', await hits(bp('pc', { pc: '0x80000004', channel: 1 })), [20]);
  eq('pc: pinned to channel 0', await hits(bp('pc', { pc: '0x80000004', channel: 0 })), [30, 50]);
  eq('pc: two addresses (the shared cycle once)', await hits(bp('pc', { pcs: ['0x80000000', '0x80000004'] })), [20, 30, 50, 70]);
  eq('pc above 4 GiB', await hits(bp('pc', { pc: '0x100000004' })), [60]);
  eq('pc: not the same mod 4 GiB', await hits(bp('pc', { pc: '0x4' })), []);
  eq('pc: never committed', await hits(bp('pc', { pc: '0x90000000' })), []);
  const two = bp('pc', { pcs: ['0x80000000', '0x80000004'] });
  await hits(two);
  eq('kAt: the first commit of the cycle', C.kAt(two, 20), 1);
  eq('kAt: a later one', C.kAt(two, 70), 7);
  eq('kAt: no hit there', C.kAt(two, 40), null);
  const ch1 = bp('pc', { pc: '0x80000004', channel: 1 });
  await hits(ch1);
  eq('kAt: the matching commit, not the cycle\'s first', C.kAt(ch1, 20), 2);

  // ---- instruction text ----
  eq('text li a0 (RVC too)', await hits(bp('commitText', { pattern: 'li a0' })), [20, 30, 60]);
  eq('text li x10 (either register name)', await hits(bp('commitText', { pattern: 'li x10' })), [20, 30, 60]);
  eq('text li x10, ABI names only', await hits(bp('commitText', { pattern: 'li x10', anyRegisterNames: false })), []);
  eq('text jal t0', await hits(bp('commitText', { pattern: '^jal\\s+t0' })), [20, 50]);
  eq('text jal x5', await hits(bp('commitText', { pattern: 'jal x5' })), [20, 50]);
  eq('text case-insensitive', await hits(bp('commitText', { pattern: 'CSRW MTVEC' })), [40]);
  eq('text Match Case', await hits(bp('commitText', { pattern: 'CSRW MTVEC', caseSensitive: true })), []);
  eq('text a bad regex is a substring', await hits(bp('commitText', { pattern: '0(a1' })), [70]);
  eq('text: an x pc\'s commit is not one', await hits(bp('commitText', { pattern: '^nop$' })), []);
  const jal = bp('commitText', { pattern: 'jal t0' });
  await hits(jal);
  eq('kAt for text in the shared cycle', C.kAt(jal, 20), 2);

  warnings.length = 0;
  eq('pc above 2^53: no search', await hits(bp('pc', { pc: 'ffffffff80000004' })), null);
  eq('pc above 2^53: said', warnings, ['Breakpoint PC 0xffffffff80000004: too large']);

  // ---- jal ra prints as jal <target> (ra implied): 0 hits for `jal ra` is explained when such a jal committed ----
  warnings.length = 0;
  eq('jal ra: none without a jal that links ra', await hits(bp('commitText', { pattern: 'jal ra' })), []);
  eq('jal ra: nothing said then', warnings, []);
  ix = makeIndex(rows.concat([[80, 0x80000020, 0x008000ef, 0]]));  // jal ra,pc+8
  eq('jal pc+8 (rd = ra) is found as jal <target>', await hits(bp('commitText', { pattern: '^jal\\s+pc' })), [80]);
  warnings.length = 0;
  eq('jal ra: still no hit', await hits(bp('commitText', { pattern: 'jal ra' })), []);
  eq('jal ra: the hint is said', warnings, ['Next instruction ~ /jal ra/: hint']);
  warnings.length = 0;
  eq('jal x1: the same', [await hits(bp('commitText', { pattern: '^jal\\s+x1\\b' })), warnings], [[], ['Next instruction ~ /^jal\\s+x1\\b/: hint']]);
  warnings.length = 0;
  eq('jal t0: no hint (it hits)', [await hits(bp('commitText', { pattern: 'jal t0' })), warnings], [[20, 50], []]);
  ix = makeIndex(rows);

  // ---- writes ----
  eq('write a0', await hits(bp('write', { loc: 'a0' })), [20, 30, 60]);
  eq('write asks for a0', writeQueries.slice(-1), ['a0']);
  eq('write a word: any of its bytes', await hits(bp('write', { loc: 'mem:0x1000/4' })), [40, 70]);
  eq('write a word asks per byte', writeQueries.slice(-4), [{ addr: 4096 }, { addr: 4097 }, { addr: 4098 }, { addr: 4099 }]);
  eq('write one byte', await hits(bp('write', { loc: 'mem:0x1000/1' })), [70]);
  eq('write csr', await hits(bp('write', { loc: 'csr:mtvec' })), [40]);
  eq('write csr asks by name', writeQueries.slice(-1), [{ csr: 'mtvec' }]);
  eq('write never', await hits(bp('write', { loc: 'csr:mscratch' })), []);

  // ---- caches ----
  const cached = bp('pc', { pc: '0x80000004' });
  const first = await C.times(cached, warn);
  const second = await C.times(cached, warn);
  eq('times kept while the index is the same', first === second, true);
  cached.pcs = ['0x80000010'];
  eq('a changed breakpoint is searched again', Array.from(await C.times(cached, warn)), [40]);
  ix = makeIndex(rows.map((r) => [r[0] + 1, r[1], r[2], r[3]]));
  eq('a rebuilt index is searched again', Array.from(await C.times(cached, warn)), [41]);
  eq('the index is asked for each search', indexCalls > 0, true);

  // ---- program order (NRET > 1, sorted by order): times ascending, kAt by time ----
  ix = makeIndex([[30, 0x80000004, 0x13, 0], [10, 0x80000004, 0x13, 1], [20, 0x80000004, 0x13, 0], [10, 0x80000000, 0x13, 0]], 'order');
  const ord = bp('pc', { pc: '0x80000004' });
  eq('order: ascending times', await hits(ord), [10, 20, 30]);
  eq('order: kAt', [C.kAt(ord, 10), C.kAt(ord, 20), C.kAt(ord, 30)], [1, 2, 0]);

  // ---- a condition's scope: the commit source's instance, when the index names it ----
  eq('scopeOf: none named', C.scopeOf(ord), null);
  ix.scope = ['top', 'cpu'];
  const scoped = bp('pc', { pc: '0x80000004' });
  await hits(scoped);
  eq('scopeOf: the index\'s', C.scopeOf(scoped), ['top', 'cpu']);
  eq('scopeOf: before a search', C.scopeOf(bp('pc', { pc: '0x4' })), null);

  // ---- landing: the Machine section's commit ----
  const went = [];
  waveform.machine = { goToCommit: (q) => { went.push(q.k); return Promise.resolve({}); } };
  eq('landed: goes to the commit', [C.landed(ord, 20), went], [2, [2]]);
  eq('landed: no hit there, the commit kept', [C.landed(ord, 15), went], [null, [2]]);
  delete waveform.machine;
  eq('landed without a Machine section', C.landed(ord, 20), null);

  // ---- what is said ----
  warnings.length = 0;
  eq('bad breakpoint: none', await hits(bp('commitText', { pattern: '' })), null);
  eq('bad breakpoint: said', warnings, ['Breakpoint Next instruction ~ //: empty']);
  ix = makeIndex(rows, 'time', true);
  warnings.length = 0;
  eq('no instruction word: none', await hits(bp('commitText', { pattern: 'li' })), null);
  eq('no instruction word: said', warnings, ['Next instruction ~ /li/: no instruction word']);
  eq('no instruction word: PCs still hit', await hits(bp('pc', { pc: '0x80000010' })), [40]);
  ix = null;
  warnings.length = 0;
  eq('no commit stream: none', await hits(bp('pc', { pc: '0x80000010' })), null);
  eq('no commit stream: said', warnings, ['PC 0x80000010: no commit stream']);
  const api = waveform.commits;
  delete waveform.commits;
  warnings.length = 0;
  eq('no commit index at all: none', await hits(bp('write', { loc: 'a0' })), null);
  eq('no commit index at all: said', warnings, ['a0 written: no commit stream']);
  waveform.commits = { index: async () => { throw new Error('broken'); } };
  eq('an index that throws: none', await hits(bp('write', { loc: 'a0' })), null);
  waveform.commits = api;

  // ---- a PC from 2^53 up is not given to the listings (its double is rounded): no arrow, not sampled ----
  ix = makeIndex([[10, 0x80000000, 0x13, 0], [20, Number(0xffffffff80000004n), 0x13, 0], [30, 0x80000008, 0x13, 0]]);
  waveform.commits.current = () => ix;
  eq('currentPc: an exact PC', C.currentPc(10), '0x80000000');
  eq('currentPc: none from 2^53 up', C.currentPc(20), null);
  eq('sample: PCs from 2^53 up left out', (await C.sample(10)).map((x) => x.pc), ['0x80000000', '0x80000008']);
  delete waveform.commits.current;
  ix = makeIndex(rows);

  // ---- a broad pattern on a long trace: the hits are collected in linear time ----
  // 300k commits over 20k distinct words, every one matching: collecting by copying the hits so far for
  // each matching word took ~40 s here; collected in place it takes ~1 s (10 s allows for a loaded Mac).
  {
    const n = 300000;
    const distinct = 20000;
    const big = [];
    for (let k = 0; k < n; k++) { big.push([k * 10, 0x80000000 + (k % distinct) * 4, ((k % distinct) << 7 | 0x13) >>> 0, 0]); }
    ix = makeIndex(big);
    const broad = bp('commitText', { pattern: '.' });
    const t0 = Date.now();
    const found = await C.times(broad, warn);
    const ms = Date.now() - t0;
    eq('broad pattern: every commit hits', found ? found.length : null, n);
    eq('broad pattern over 20k distinct words: under 10 s (' + ms + ' ms)', ms < 10000, true);
    ix = makeIndex(rows);
  }
  return out;
}
