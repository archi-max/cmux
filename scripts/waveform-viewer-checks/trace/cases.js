// The checks run.sh trace runs on cmux-trace.js (the active driver, phase P1 of driver tracing):
// the prototype's seven hand-traced x chains (status/tracex-design.md section 11), one active()
// step at a time, on every dump of each design (VCS plain, -xprop variants, Icarus); design E's
// constructs; and the replay oracle (every change of every signal re-executed and compared with
// the dump). Fields of a case, each checked when present:
//   kind (driver.kind), proc (procKind), file + line + stmt (a substring of the statement),
//   act (activation edge), sample, since, value (bits), dec [[condition substring, taken]...],
//   fanin { path or local name: bits }, xIndex [fan-in names read through an x index],
//   trust, root, reasons [codes that must be there], viol [each decision's case violation or null],
//   noReasons [codes that must not], dumps [variants it runs on; default all of the design's].
/* global cmuxTrace, traceVcd, traceFiles */
/* exported runTraceChecks */

const TRACE_DUMPS = {
  a: ['plain', 'flowctrl', 'tmerge', 'course', 'icarus'],
  b: ['plain', 'flowctrl', 'tmerge', 'course', 'icarus'],
  c: ['plain', 'flowctrl', 'tmerge', 'course', 'icarus'],
  e: ['plain', 'flowctrl', 'tmerge', 'course', 'icarus'],
  // Icarus 12 has no interface ports.
  f: ['plain', 'flowctrl', 'tmerge', 'course'],
  g: ['plain', 'flowctrl', 'tmerge', 'course', 'icarus'],
  h: ['plain', 'flowctrl', 'tmerge', 'course', 'icarus'],
};

const XX = 'xxxxxxxx';
const TRACE_CASES = [
  // ---- A: an uninitialized flop through comb logic and a blocking temp (chain 1) ----
  { d: 'a', sig: 'tb_a.dut.dout', t: 60, kind: 'proc', proc: 'AlwaysFF', file: 'a_uninit.sv', line: 34, stmt: 'dout <= stage;',
    act: 55, sample: 54, since: 55, value: XX, dec: [['!rst_n', 'else']], fanin: { 'tb_a.dut.stage': XX, 'tb_a.dut.rst_n': '1', 'tb_a.dut.clk': '1' }, trust: 'exact' },
  { d: 'a', sig: 'tb_a.dut.stage', t: 54, kind: 'proc', proc: 'AlwaysComb', file: 'a_uninit.sv', line: 28, stmt: 'stage = tmp;',
    since: 45, dec: [['valid_q', 'then']], fanin: { tmp: XX, 'tb_a.dut.valid_q': '1' }, trust: 'computed' },
  { d: 'a', sig: 'tb_a.dut.sum', t: 54, kind: 'assign', file: 'a_uninit.sv', line: 23, stmt: 'sum = acc ^ {8{valid_q}}',
    since: 0, fanin: { 'tb_a.dut.acc': XX, 'tb_a.dut.valid_q': '1' }, trust: 'exact' },
  { d: 'a', sig: 'tb_a.dut.acc', t: 54, kind: 'proc', proc: 'AlwaysFF', file: 'a_uninit.sv', line: 21, stmt: 'acc <= acc + din;',
    act: 45, sample: 44, dec: [['en', 'then']], fanin: { 'tb_a.dut.acc': XX, 'tb_a.dut.din': '00000011' } },
  // Known values: the else branch (en low) and the reset branch.
  { d: 'a', sig: 'tb_a.dut.stage', t: 30, kind: 'proc', line: 29, stmt: 'stage = din;', dec: [['valid_q', 'else']], value: '00000011', trust: 'exact' },
  { d: 'a', sig: 'tb_a.dut.dout', t: 10, kind: 'proc', line: 33, stmt: "dout <= '0;", value: '00000000', dec: [['!rst_n', 'then']], trust: 'exact' },
  { d: 'a', sig: 'tb_a.dut.valid_q', t: 48, kind: 'proc', line: 18, stmt: 'valid_q <= en;', act: 45, sample: 44, value: '1', trust: 'exact' },

  // ---- B: x index, unwritten memory, x-assignment, x selector (chains 2-5) ----
  { d: 'b', sig: 'tb_b.dut.rdata', t: 60, kind: 'proc', proc: 'AlwaysComb', file: 'b_select.sv', line: 32, stmt: 'rdata = mem[raddr_q];',
    since: 55, value: XX, dec: [['mode_q', 0]], fanin: { 'tb_b.dut.raddr_q': 'xx' }, xIndex: ['mem'], dumps: ['plain', 'flowctrl', 'tmerge', 'icarus'] },
  { d: 'b', sig: 'tb_b.dut.raddr_q', t: 60, kind: 'proc', proc: 'AlwaysFF', line: 26, stmt: 'raddr_q <= raddr;', act: 55, sample: 54,
    dec: [['!rst_n', 'else']], fanin: { 'tb_b.dut.raddr': 'xx' }, trust: 'exact' },
  { d: 'b', sig: 'tb_b.dut.raddr', t: 54, kind: 'portIn', file: 'tb_b.sv', line: 6, since: 50, fanin: { 'tb_b.raddr': 'xx' }, trust: 'exact' },
  { d: 'b', sig: 'tb_b.raddr', t: 54, kind: 'initial', root: 'testbench', since: 50, reasons: ['testbench'], file: 'tb_b.sv', line: 16, stmt: "raddr = 2'bxx;" },
  { d: 'b', sig: 'tb_b.dut.rdata', t: 80, kind: 'proc', line: 32, stmt: 'rdata = mem[raddr_q];', dec: [['mode_q', 0]],
    fanin: { 'tb_b.dut.raddr_q': '11', 'tb_b.dut.mem[3]': XX }, dumps: ['plain', 'flowctrl', 'tmerge', 'course'] },
  { d: 'b', sig: 'tb_b.dut.rdata', t: 100, kind: 'proc', line: 35, stmt: "rdata = 'x;", dec: [['mode_q', 'default']], value: XX, trust: 'exact' },
  { d: 'b', sig: 'tb_b.dut.rdata', t: 120, kind: 'proc', line: 35, stmt: "rdata = 'x;", dec: [['mode_q', 'default']], value: XX,
    fanin: { 'tb_b.dut.mode_q': 'xx' }, dumps: ['plain', 'flowctrl', 'tmerge', 'icarus'] },
  { d: 'b', sig: 'tb_b.dut.mode_q', t: 120, kind: 'proc', line: 27, stmt: 'mode_q  <= mode;', act: 115, sample: 114, fanin: { 'tb_b.dut.mode': 'xx' } },
  { d: 'b', sig: 'tb_b.dut.mode', t: 114, kind: 'portIn', file: 'tb_b.sv', line: 6, since: 110, fanin: { 'tb_b.mode': 'xx' } },
  { d: 'b', sig: 'tb_b.mode', t: 114, kind: 'initial', root: 'testbench', file: 'tb_b.sv', line: 19, stmt: "mode = 2'bxx;" },
  // The testbench's write in effect at t, not the body's last (#delays summed along the body).
  { d: 'b', sig: 'tb_b.mode', t: 100, kind: 'initial', file: 'tb_b.sv', line: 18, stmt: 'mode = 2\'d3;' },
  // Known: case item 1 and the memory write (FSDB-only memories: the VCDs have no mem).
  { d: 'b', sig: 'tb_b.dut.rdata', t: 140, kind: 'proc', line: 33, stmt: 'rdata = ~mem[raddr_q];', dec: [['mode_q', 1]], value: '11011101', reasons: ['notDumped'], trust: 'approximate', dumps: ['icarus'] },
  { d: 'b', sig: 'tb_b.dut.rdata', t: 140, kind: 'proc', line: 33, stmt: 'rdata = ~mem[raddr_q];', dec: [['mode_q', 1]], value: '11011101', reasons: ['notDumped'], trust: 'approximate', dumps: ['plain'] },

  // ---- C: hierarchy and a packed-struct port (chains 6 and 7) ----
  { d: 'c', sig: 'tb_c.dut.q', t: 60, kind: 'portOut', file: 'c_struct.sv', line: 81, since: 55, fanin: { 'tb_c.dut.u_mid.q': XX }, trust: 'exact' },
  { d: 'c', sig: 'tb_c.dut.u_mid.q', t: 60, kind: 'portOut', line: 68, fanin: { 'tb_c.dut.u_mid.u_sink.q': XX } },
  { d: 'c', sig: 'tb_c.dut.u_mid.u_sink.q', t: 60, kind: 'proc', proc: 'AlwaysFF', line: 56, stmt: 'q  <= mix;', act: 55, sample: 54,
    dec: [['!rst_n', 'else'], ['in.valid', 'then']], fanin: { 'tb_c.dut.u_mid.u_sink.mix': XX }, trust: 'exact' },
  { d: 'c', sig: 'tb_c.dut.u_mid.u_sink.mix', t: 54, kind: 'assign', line: 49, stmt: 'mix = in.data + {4\'b0, in.id}', since: 0 },
  { d: 'c', sig: 'tb_c.dut.u_mid.u_sink.in', t: 54, kind: 'portIn', line: 68, since: 45, fanin: { 'tb_c.dut.u_mid.pin': '1xxxx00010000' }, trust: 'exact' },
  { d: 'c', sig: 'tb_c.dut.u_mid.pin', t: 54, kind: 'portIn', line: 81, fanin: { 'tb_c.dut.p': '1xxxx00010000' } },
  { d: 'c', sig: 'tb_c.dut.p', t: 54, kind: 'portOut', line: 80, fanin: { 'tb_c.dut.u_src.out': '1xxxx00010000' } },
  { d: 'c', sig: 'tb_c.dut.u_src.out', t: 54, kind: 'assign', line: 37, stmt: "out = '{valid: valid_q", fanin: { 'tb_c.dut.u_src.id_q': 'xxxx' }, trust: 'exact', dumps: ['plain', 'flowctrl', 'tmerge', 'course'] },
  { d: 'c', sig: 'tb_c.dut.u_src.out', t: 54, kind: 'assign', line: 35, stmt: 'out = {valid_q, id_q, data_q}', fanin: { 'tb_c.dut.u_src.id_q': 'xxxx' }, trust: 'exact', dumps: ['icarus'] },
  { d: 'c', sig: 'tb_c.dut.u_src.id_q', t: 54, kind: 'proc', line: 29, stmt: "id_q   <= id_q + 4'd1;", act: 45, sample: 44, dec: [['go', 'then']] },
  { d: 'c', sig: 'tb_c.qd', t: 80, kind: 'portOut', file: 'tb_c.sv', line: 6, since: 75, fanin: { 'tb_c.dut.qd': XX } },
  { d: 'c', sig: 'tb_c.dut.qd', t: 80, kind: 'portOut', line: 81 },
  { d: 'c', sig: 'tb_c.dut.u_mid.u_sink.qd', t: 80, kind: 'proc', line: 57, stmt: 'qd <= in.data;', act: 75, sample: 74, dec: [['!rst_n', 'else'], ['in.valid', 'then']] },
  { d: 'c', sig: 'tb_c.dut.u_src.data_q', t: 74, kind: 'proc', line: 30, stmt: 'data_q <= d;', act: 65, sample: 64, since: 65, fanin: { 'tb_c.dut.u_src.d': XX } },
  { d: 'c', sig: 'tb_c.dut.u_src.d', t: 64, kind: 'portIn', line: 80, since: 60, fanin: { 'tb_c.dut.d': XX } },
  { d: 'c', sig: 'tb_c.dut.d', t: 64, kind: 'portIn', file: 'tb_c.sv', line: 6, fanin: { 'tb_c.d': XX } },
  { d: 'c', sig: 'tb_c.d', t: 64, kind: 'initial', root: 'testbench', since: 60 },

  // ---- E: more constructs ----
  { d: 'e', sig: 'tb_e.dut.lat', t: 45, kind: 'proc', proc: 'AlwaysLatch', line: 27, stmt: 'lat = a;', value: '00010010', reasons: ['held'], sample: 30 },
  { d: 'e', sig: 'tb_e.dut.lat', t: 35, kind: 'proc', proc: 'AlwaysLatch', line: 27, value: '00010010', noReasons: ['held'], dec: [['en', 'then']] },
  { d: 'e', sig: 'tb_e.dut.dec', t: 35, kind: 'proc', line: 33, stmt: "dec = 4'd4;", dec: [['op', 1]], value: '0100', trust: 'exact' },
  { d: 'e', sig: 'tb_e.dut.dec', t: 60, kind: 'proc', line: 32, stmt: "dec = 4'd8;", dec: [['op', 0]], value: '1000', trust: 'exact' },
  { d: 'e', sig: 'tb_e.dut.dec', t: 100, kind: 'proc', line: 34, stmt: "dec = 4'd2;", value: '0010', trust: 'exact' },
  { d: 'e', sig: 'tb_e.dut.carry', t: 35, kind: 'assign', line: 42, stmt: '{carry, sum} = a + b', value: '0', trust: 'exact' },
  { d: 'e', sig: 'tb_e.dut.sum', t: 35, kind: 'assign', line: 42, value: '01000110', trust: 'exact' },
  { d: 'e', sig: 'tb_e.dut.hi_lo', t: 35, kind: 'assign', reasons: ['multiDriven'], value: '00100011' },
  { d: 'e', sig: 'tb_e.dut.y', t: 35, kind: 'assign', line: 66, stmt: 'y = lane[0].r ^ lane[1].r', trust: 'exact' },
  { d: 'e', sig: 'tb_e.dut.lane[1].r', t: 35, kind: 'proc', proc: 'AlwaysFF', line: 64, stmt: 'r <= r + a;', act: 35, sample: 34, trust: 'exact' },
  { d: 'e', sig: 'tb_e.dut.pk', t: 35, kind: 'assign', line: 71, value: '00110100', fanin: { 'tb_e.dut.op': '0110' }, trust: 'exact' },
  { d: 'e', sig: 'tb_e.dut.asc', t: 35, kind: 'assign', line: 74, value: '01001000', trust: 'exact' },
  { d: 'e', sig: 'tb_e.dut.t2', t: 40, kind: 'proc', line: 84, stmt: "t2 <= tmp2 + 8'd1;", act: 25, value: '00100111', trust: 'computed' },
  // An if on x in a flop and in comb logic: x-optimistic sims take the else branch...
  { d: 'e', sig: 'tb_e.dut.xc', t: 75, kind: 'proc', proc: 'AlwaysComb', line: 56, stmt: 'xc = b;', value: '01111000', dec: [['sel', 'else']], trust: 'exact', dumps: ['plain', 'flowctrl', 'icarus'] },
  { d: 'e', sig: 'tb_e.dut.xf', t: 80, kind: 'proc', proc: 'AlwaysFF', line: 52, stmt: 'xf <= b;', act: 75, value: '01111000', dec: [['!rst_n', 'else'], ['sel', 'else']], trust: 'exact', dumps: ['plain', 'flowctrl', 'icarus'] },
  // ...X-propagation merges both branches (tmerge: the bits they agree on, else x).
  { d: 'e', sig: 'tb_e.dut.xc', t: 75, kind: 'proc', value: '01x1xxx0', dec: [['sel', 'merge']], reasons: ['xprop'], trust: 'approximate', dumps: ['tmerge', 'course'] },
  { d: 'e', sig: 'tb_e.dut.xf', t: 80, kind: 'proc', act: 75, value: '01x1xxx0', dec: [['!rst_n', 'else'], ['sel', 'merge']], reasons: ['xprop'], dumps: ['tmerge', 'course'] },
  // Branches that agree: the merge is the common value.
  { d: 'e', sig: 'tb_e.dut.xc', t: 60, kind: 'proc', value: '01010110', trust: 'exact' },

  // ---- F: interface signals written by other instances through modport ports ----
  // The memory model's comb read of a never-written element (its memory isn't in the VCD).
  { d: 'f', sig: 'tb_f.bus.rdata', t: 60, kind: 'proc', proc: 'AlwaysComb', writer: 'tb_f.u_mem', file: 'f_bus.sv', line: 23,
    stmt: 'bus.rdata = store[bus.addr[1:0]];', value: XX, dec: [['bus.req', 'then']], fanin: { 'tb_f.bus.req': '1', 'tb_f.bus.addr': '00000011' } },
  { d: 'f', sig: 'tb_f.bus.rdata', t: 20, kind: 'proc', writer: 'tb_f.u_mem', line: 24, stmt: "bus.rdata = 8'h00;", value: '00000000', dec: [['bus.req', 'else']], trust: 'exact' },
  { d: 'f', sig: 'tb_f.bus.resp', t: 40, kind: 'proc', proc: 'AlwaysFF', writer: 'tb_f.u_mem', line: 28, stmt: 'bus.resp <= bus.req;', act: 35, sample: 34, value: '1', trust: 'exact' },
  { d: 'f', sig: 'tb_f.bus.addr', t: 55, kind: 'assign', writer: 'tb_f.dut', line: 32, stmt: 'bus.addr = a', value: '00000011', fanin: { 'tb_f.dut.a': '00000011' }, trust: 'exact' },
  { d: 'f', sig: 'tb_f.bus.req', t: 30, kind: 'proc', writer: 'tb_f.dut', line: 38, stmt: "bus.req <= 1'b1;", act: 25, value: '1', dec: [['!rst_n', 'else']], trust: 'exact' },
  // The reader's side: the dut's flop takes the interface's x.
  { d: 'f', sig: 'tb_f.dut.q', t: 60, kind: 'proc', proc: 'AlwaysFF', line: 39, stmt: 'q <= bus.rdata;', act: 55, value: XX, fanin: { 'tb_f.bus.rdata': XX } },
  // ---- G: a default then an override in one run: the last write that runs is the driver ----
  { d: 'g', sig: 'tb_g.dut.q', t: 30, kind: 'proc', proc: 'AlwaysFF', file: 'g_override.sv', line: 16, stmt: 'q <= d;', act: 25, sample: 24,
    value: '01011010', dec: [['!rst_n', 'else'], ['en', 'then']], fanin: { 'tb_g.dut.d': '01011010' }, trust: 'exact' },
  { d: 'g', sig: 'tb_g.dut.q', t: 48, kind: 'proc', line: 15, stmt: "q <= 8'h0f;", act: 45, value: '00001111', dec: [['!rst_n', 'else']], trust: 'exact' },
  { d: 'g', sig: 'tb_g.dut.y', t: 30, kind: 'proc', proc: 'AlwaysComb', line: 21, stmt: "y = d ^ 8'hff;", value: '10100101', dec: [['en', 'then']], trust: 'exact' },
  { d: 'g', sig: 'tb_g.dut.y', t: 45, kind: 'proc', line: 20, stmt: "y = 8'h00;", value: '00000000', dec: [], trust: 'exact' },
  // ---- H: z and tri-state, NBA, casex, x-index write, multi-driver, priority/unique, merge, delay ----
  // (the dump is in ps, the design's delays in ns)
  // A z passes through ports (implicit .* connections, the leaf names shown) and a tri-state bus.
  { d: 'h', sig: 'tb_h.dut.u_leaf.sel', t: 72000, kind: 'portIn', stmt: '.sel(sel)', value: '0z10', trust: 'exact' },
  { d: 'h', sig: 'tb_h.dut.sel', t: 72000, kind: 'portIn', stmt: '.sel(sel)', value: '0z10', trust: 'exact' },
  { d: 'h', sig: 'tb_h.dut.u_leaf.sel_o', t: 72000, kind: 'assign', value: '0z10', trust: 'exact' },
  { d: 'h', sig: 'tb_h.sel_o', t: 72000, kind: 'portOut', stmt: '.sel_o(sel_o)', value: '0z10', trust: 'exact' },
  { d: 'h', sig: 'tb_h.dut.bus', t: 72000, kind: 'assign', value: 'zzzzzzzz', reasons: ['multiDriven'], trust: 'exact' },
  // Two drivers: the second is the one whose value is on the bus.
  { d: 'h', sig: 'tb_h.dut.bus', t: 56000, kind: 'assign', line: 61, stmt: 'bus = oe_b ? ~din', value: '10101011', reasons: ['multiDriven'], trust: 'exact' },
  // Nonblocking read-after-write: r takes q's old value.
  { d: 'h', sig: 'tb_h.dut.r', t: 36000, kind: 'proc', line: 40, stmt: "r <= q + 8'h01;", value: '00100010', fanin: { 'tb_h.dut.q': '00100001' }, trust: 'exact' },
  // casex: an x in the selector, a z in the selector, wildcards in the items.
  { d: 'h', sig: 'tb_h.dut.cx', t: 66000, kind: 'proc', stmt: "cx = 8'ha1;", value: '10100001', dec: [['sel', 0]], trust: 'exact', dumps: ['plain', 'flowctrl', 'icarus'] },
  { d: 'h', sig: 'tb_h.dut.cx', t: 76000, kind: 'proc', stmt: "cx = 8'hb2;", value: '10110010', dec: [['sel', 1]], trust: 'exact', dumps: ['plain', 'flowctrl', 'icarus'] },
  { d: 'h', sig: 'tb_h.dut.cx', t: 46000, kind: 'proc', stmt: "cx = 8'hc3;", value: '11000011', dec: [['sel', 2]], trust: 'exact' },
  // An x-index write writes no element: mem[0] keeps its reset value (Icarus dumps the elements).
  { d: 'h', sig: 'tb_h.dut.mem[0]', t: 50000, kind: 'proc', value: '00000000', trust: 'exact', dumps: ['icarus'] },
  { d: 'h', sig: 'tb_h.dut.mem[1]', t: 50000, kind: 'proc', value: '00111101', trust: 'computed', dumps: ['icarus'] },
  // priority: two items match, no violation; unique: the same is a violation.
  { d: 'h', sig: 'tb_h.dut.pv', t: 36000, kind: 'proc', stmt: "pv = 8'h01;", value: '00000001', dec: [['pr', 0]], viol: [null], trust: 'exact' },
  { d: 'h', sig: 'tb_h.dut.uv', t: 36000, kind: 'proc', stmt: "uv = 8'h11;", value: '00010001', dec: [['pr', 0]], viol: ['multipleMatches'] },
  // An if on x under X-propagation: both branches merged, the step names the last write.
  { d: 'h', sig: 'tb_h.dut.mv', t: 56000, kind: 'proc', line: 80, stmt: "mv <= 8'h5a;", reasons: ['xprop'], dumps: ['tmerge', 'course'] },
  { d: 'h', sig: 'tb_h.dut.mv', t: 56000, kind: 'proc', line: 80, stmt: "mv <= 8'h5a;", value: '01011010', dec: [['c', 'else']], dumps: ['plain', 'icarus'] },
  // An RTL delay makes the step approximate.
  { d: 'h', sig: 'tb_h.dut.dly', t: 30000, kind: 'assign', stmt: 'dly = din', reasons: ['delay'], trust: 'approximate' },
  // The testbench write in effect at t: the delays (ns) scaled to the dump's ps.
  { d: 'h', sig: 'tb_h.din', t: 45000, kind: 'initial', file: 'tb_h.sv', line: 21, stmt: "din = 8'h43;", root: 'testbench' },
  { d: 'h', sig: 'tb_h.din', t: 80000, kind: 'initial', file: 'tb_h.sv', line: 24, stmt: "din = 8'h76;", root: 'testbench' },
];

function runTraceChecks() {
  const out = [];
  const designText = traceFiles.designs;
  const results = { cases: 0, failures: 0, oracle: {} };
  const engines = {};
  const lineOf = (file, snippet) => {
    const lines = (designText[file] || '').split('\n');
    const i = lines.findIndex((l) => l.includes(snippet));
    return i < 0 ? null : i + 1;
  };
  const base = (f) => (f ? String(f).split('/').pop() : f);

  function engineFor(d, variant) {
    const key = d + '.' + variant;
    if (engines[key]) { return engines[key]; }
    const modelName = d === 'c' && variant === 'icarus' ? 'c.icarus' : d;
    const all = JSON.parse(traceFiles.models[modelName]);
    const vcd = traceVcd(traceFiles.dumps[`${d}.${variant}`]);
    const models = {
      instance: async (p) => all.instances[p],
      // What cmux-sv-model's `writers` answers: the instances that write into `p` from outside it.
      writers: async (p) => Object.keys(all.instances).filter((k) => k !== p && JSON.stringify(all.instances[k]).includes('"name":"$abs:' + p + '.')),
      lookup: async (p) => {
        let best = null;
        for (const k of Object.keys(all.instances)) { if ((p === k || p.startsWith(k + '.')) && (!best || k.length > best.length)) { best = k; } }
        return best ? { instance: best, name: p.slice(best.length + 1) } : null;
      },
    };
    const engine = cmuxTrace.createEngine({ models, dump: vcd.provider });
    engines[key] = { engine, vcd, all };
    return engines[key];
  }

  function check(c, variant, step) {
    const bad = [];
    const want = (what, got, exp) => { if (got !== exp) { bad.push(`${what}: ${JSON.stringify(got)} != ${JSON.stringify(exp)}`); } };
    if (step.error) { bad.push('error ' + step.error); return bad; }
    const kind = step.driver && step.driver.kind;
    if (c.kind) { want('kind', kind, c.kind); }
    if (c.writer) { want('writer', step.driver && step.driver.writer, c.writer); }
    if (c.proc) { want('proc', step.procKind || (step.driver && step.driver.procKind), c.proc); }
    if (c.file) { want('file', base(step.stmt && step.stmt.loc && step.stmt.loc.file), c.file); }
    if (c.line) { want('line', step.stmt && step.stmt.loc && step.stmt.loc.line, c.line); }
    const squeeze = (x) => String(x).replace(/\s+/g, ' ');
    if (c.stmt) { if (!(step.stmt && squeeze(step.stmt.src).includes(squeeze(c.stmt)))) { bad.push(`stmt: ${JSON.stringify(step.stmt && step.stmt.src)} lacks ${JSON.stringify(c.stmt)}`); } }
    if (c.act !== undefined) { want('activation', step.activation && step.activation.time, c.act); }
    if (c.sample !== undefined) { want('sample', step.sample, c.sample); }
    if (c.since !== undefined) { want('since', step.since, c.since); }
    if (c.value !== undefined) { want('value', step.value, c.value); }
    if (c.trust) { want('trust', step.trust, c.trust); }
    if (c.root) { want('root', step.root, c.root); }
    for (const [k, v] of Object.entries(c.fanin || {})) {
      const f = (step.fanin || []).find((x) => x.path === k || (x.local && x.name === k));
      if (!f) { bad.push(`fan-in lacks ${k} (has ${(step.fanin || []).map((x) => x.path || x.name).join(', ')})`); } else if (f.value !== v) { bad.push(`fan-in ${k} = ${f.value} != ${v}`); }
    }
    for (const k of c.xIndex || []) {
      if (!(step.fanin || []).some((x) => x.xIndex && (x.name === k || x.path === k))) { bad.push(`fan-in lacks an x-index read of ${k}`); }
    }
    (c.dec || []).forEach(([src, taken], i) => {
      const d = (step.decisions || [])[i];
      if (!d) { bad.push(`no decision ${i}`); return; }
      if (!String(d.src).includes(src)) { bad.push(`decision ${i} src ${d.src} lacks ${src}`); }
      if (d.taken !== taken) { bad.push(`decision ${i} taken ${JSON.stringify(d.taken)} != ${JSON.stringify(taken)}`); }
    });
    (c.viol || []).forEach((v, i) => { const d = (step.decisions || [])[i]; want(`decision ${i} violation`, d ? (d.violation || null) : 'no decision', v); });
    if (c.dec && (step.decisions || []).length !== c.dec.length) { bad.push(`decisions: ${(step.decisions || []).length} != ${c.dec.length}`); }
    const codes = (step.reasons || []).map((r) => r.code);
    for (const r of c.reasons || []) { if (!codes.includes(r)) { bad.push(`reasons lack ${r} (have ${codes.join(',')})`); } }
    for (const r of c.noReasons || []) { if (codes.includes(r)) { bad.push(`reasons have ${r}`); } }
    // The line a case names is the statement's own line in its file.
    if (c.line && c.stmt && step.stmt && step.stmt.loc) {
      const l = lineOf(base(step.stmt.loc.file), c.stmt.trim());
      if (l !== null && l !== c.line) { bad.push(`case says line ${c.line}, the file has it at ${l}`); }
    }
    return bad;
  }

  async function run() {
    for (const c of TRACE_CASES) {
      for (const variant of c.dumps || TRACE_DUMPS[c.d]) {
        results.cases++;
        let step;
        try {
          step = await engineFor(c.d, variant).engine.active(c.sig, c.t);
        } catch (error) {
          step = { error: String(error && error.stack || error) };
        }
        const bad = check(c, variant, step);
        if (bad.length) {
          results.failures++;
          out.push(`FAIL ${c.d}.${variant} ${c.sig} @${c.t}: ${bad.join('; ')}`);
        } else {
          out.push(`ok   ${c.d}.${variant} ${c.sig} @${c.t}: ${step.driver.kind} ${step.stmt ? step.stmt.src : ''} [${step.trust}]`);
        }
      }
    }
    // The replay oracle: every change of every design signal at its change time.
    for (const d of Object.keys(TRACE_DUMPS)) {
      for (const variant of TRACE_DUMPS[d]) {
        const { engine, vcd, all } = engineFor(d, variant);
        const tally = { steps: 0, exact: 0, computed: 0, approximate: 0, inconsistent: 0, unexplained: 0 };
        for (const [inst, m] of Object.entries(all.instances)) {
          for (const name of Object.keys(m.signals)) {
            const p = inst + '.' + name;
            const s = vcd.sig.get(p);
            if (!s) { continue; }
            for (const [t] of s.changes) {
              const step = await engine.active(p, t);
              tally.steps++;
              if (step.driver && step.driver.kind === 'none') { tally.noDriver = (tally.noDriver || 0) + 1; if (tally.noDriver <= 3) { out.push(`ORACLE ${d}.${variant} ${p} @${t}: no driver`); } }
              tally[step.trust] = (tally[step.trust] || 0) + 1;
              // Inconsistent with no reason the engine can name: a modelling bug.
              if (step.trust === 'inconsistent' && (step.reasons || []).some((r) => r.code === 'mismatch')) {
                tally.unexplained++;
                tally.shown = tally.shown || {};
                tally.shown[p] = (tally.shown[p] || 0) + 1;
                if (tally.shown[p] <= 2 && Object.keys(tally.shown).length <= 8) { out.push(`ORACLE ${d}.${variant} ${p} @${t}: predicted ${step.predicted}, dump ${step.value} (${step.stmt && step.stmt.src})`); }
              }
            }
          }
        }
        results.oracle[`${d}.${variant}`] = tally;
        const expectClean = variant === 'plain' || variant === 'icarus' || variant === 'flowctrl';
        const line = `${d}.${variant}: ${tally.steps} steps, exact ${tally.exact}, computed ${tally.computed}, approximate ${tally.approximate}, inconsistent ${tally.inconsistent}, unexplained ${tally.unexplained}`;
        if (tally.noDriver) { results.failures++; out.push(`FAIL oracle ${d}.${variant}: ${tally.noDriver} steps found no driver`); }
        if (expectClean && tally.unexplained) { results.failures++; out.push('FAIL oracle ' + line); } else { out.push('oracle ' + line); }
      }
    }
    return out;
  }
  return run().then((lines) => { globalThis.__traceDone = { lines, results }; }, (error) => { globalThis.__traceDone = { lines: out.concat(['FAIL ' + (error && error.stack || error)]), results: { failures: 1 } }; });
}
