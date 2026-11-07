// The checks run.sh trace runs on cmux-trace.js (the active driver, phase P1 of driver tracing):
// the prototype's seven hand-traced x chains (status/tracex-design.md section 11), one active()
// step at a time, on every dump of each design (VCS plain, -xprop variants, Icarus); design E's
// constructs; and the replay oracle (every change of every signal re-executed and compared with
// the dump). Fields of a case, each checked when present:
//   kind (driver.kind), proc (procKind), file + line + stmt (a substring of the statement),
//   act (activation edge), sample, since, value (bits), dec [[condition substring, taken]...],
//   fanin { path or local name: bits, or '*' for any value }, noFanin [names that must not be fan-in], roles { fan-in name: 'data' | 'control' }, xIndex [fan-in names read through an x index],
//   trust, noTrust (a trust it must not have), root, reasons [codes that must be there], viol [each decision's case violation or null],
//   noReasons [codes that must not], dumps [variants it runs on; default all of the design's; 'stale' is
//   the Icarus dump with staleModel's model, 'nowrites' with that model's write lists removed only].
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
  i: ['icarus'],
  j: ['icarus'],
  // The vendor task is $deposit under Icarus (the model sees $cmux_poke).
  k: ['icarus'],
  // The classes a Verdi oracle run found exact but wrong on a larger SoC testbench, small.
  l: ['icarus'],
};

const XX = 'xxxxxxxx';
const TRACE_CASES = [
  // ---- A: an uninitialized flop through comb logic and a blocking temp (chain 1) ----
  { d: 'a', sig: 'tb_a.dut.dout', t: 60, kind: 'proc', proc: 'AlwaysFF', file: 'a_uninit.sv', line: 34, stmt: 'dout <= stage;',
    act: 55, sample: 54, since: 55, value: XX, dec: [['!rst_n', 'else']], fanin: { 'tb_a.dut.stage': XX, 'tb_a.dut.rst_n': '1', 'tb_a.dut.clk': '1' }, trust: 'exact' },
  { d: 'a', sig: 'tb_a.dut.stage', t: 54, kind: 'proc', proc: 'AlwaysComb', file: 'a_uninit.sv', line: 28, stmt: 'stage = tmp;',
    since: 45, dec: [['valid_q', 'then']], fanin: { tmp: XX, 'tb_a.dut.valid_q': '1', 'tb_a.dut.sum': XX }, trust: 'computed' },
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
  // A port's connection is evaluated in the parent: the driver says so (the page checks it against the KDB).
  { d: 'c', sig: 'tb_c.dut.u_mid.u_sink.in', t: 54, kind: 'portIn', from: 'tb_c.dut.u_mid' },
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
  { d: 'e', sig: 'tb_e.dut.t2', t: 40, kind: 'proc', line: 84, stmt: "t2 <= tmp2 + 8'd1;", act: 25, value: '00100111', trust: 'computed',
    // A blocking temp's fan-in carries what its write read (tmp2 = a ^ b), not just the temp.
    fanin: { 'tb_e.dut.tmp2': '*', 'tb_e.dut.a': '*', 'tb_e.dut.b': '*' } },
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
  // An x-index write writes no element: mem[0] keeps the write before it (Icarus dumps the elements).
  { d: 'h', sig: 'tb_h.dut.mem[0]', t: 50000, kind: 'proc', stmt: 'mem[0] <= din;', value: '01000011', trust: 'exact', dumps: ['icarus'] },
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
  { d: 'h', sig: 'tb_h.din', t: 10000, kind: 'initial', file: 'tb_h.sv', line: 6, stmt: "din = 8'b00010000", root: 'testbench' },
  { d: 'h', sig: 'tb_h.din', t: 80000, kind: 'initial', file: 'tb_h.sv', line: 24, stmt: "din = 8'h76;", root: 'testbench' },
  // Several delay scales fit (#5 at 1000 ps per ns, #50 at 100): the largest, so the #5 write.
  { d: 'h', sig: 'tb_h.ms', t: 30000, kind: 'initial', file: 'tb_h.sv', line: 30, stmt: "ms = 8'h99;", root: 'testbench' },

  // ---- I: writes that are found though not re-executed (approximate, never "no driver") ----
  // A loop-indexed comb write, per-lane counters in a loop, byte writes into memory words in a loop.
  { d: 'i', sig: 'tb_i.dut.pop', t: 30000, kind: 'proc', proc: 'AlwaysComb', file: 'i_drivers.sv', line: 23, stmt: 'for (int t = 0; t < 4; t++)',
    trust: 'approximate', reasons: ['statement'], noReasons: ['noWrite'] },
  { d: 'i', sig: 'tb_i.dut.lost[2]', t: 30000, kind: 'proc', proc: 'AlwaysFF', file: 'i_drivers.sv', line: 27, stmt: 'for (int c = 0; c < 4; c++) if (valid[c]',
    trust: 'approximate', reasons: ['statement'], noReasons: ['noWrite'] },
  { d: 'i', sig: 'tb_i.dut.mem[0]', t: 30000, kind: 'proc', proc: 'Always', file: 'i_drivers.sv', line: 30, stmt: 'for (int b = 0; b < 4; b++)',
    trust: 'approximate', reasons: ['statement'], noReasons: ['noWrite'] },
  // The testbench: x++ in a clocked block; a $value$plusargs output and an initial block that also
  // calls a dump task the elaborator doesn't know.
  { d: 'i', sig: 'tb_i.settle', t: 30000, kind: 'proc', proc: 'Always', file: 'tb_i.sv', line: 14, stmt: 'settle++;', noReasons: ['noWrite'] },
  { d: 'i', sig: 'tb_i.iters', t: 30000, kind: 'initial', root: 'testbench', file: 'tb_i.sv', line: 16 },
  { d: 'i', sig: 'tb_i.epoch', t: 30000, kind: 'initial', root: 'testbench', file: 'tb_i.sv', line: 17, stmt: 'epoch = iters;' },

  // ---- J: an x through a blocking temp the block ends with tmp = 'bx; a default 'bx no later case item replaced ----
  // q <= tmp, tmp = go ? a : b earlier in the block: q's fan-in is a and go (what reached q), not just tmp.
  { d: 'j', sig: 'tb_j.dut.q', t: 20000, kind: 'proc', file: 'j_temps.sv', line: 20, stmt: 'q <= tmp;', act: 15000, value: 'xxxx0001',
    fanin: { 'tb_j.dut.a': 'xxxx0001', 'tb_j.dut.go': '1', 'tb_j.dut.tmp': '*' } },
  // y = 'bx, then case (1'b1) with x items: nothing matched, so the items are why y stayed x.
  { d: 'j', sig: 'tb_j.dut.y', t: 10000, kind: 'proc', file: 'j_temps.sv', line: 29, stmt: "y = 'bx;",
    fanin: { 'tb_j.dut.is_add': 'x', 'tb_j.dut.is_xor': 'x' } },
  // wire is_add = op == 2'd1: a net's declaration assignment is a continuous assignment (its fan-in
  // is op), not a declaration initializer.
  { d: 'j', sig: 'tb_j.dut.is_add', t: 10000, kind: 'assign', file: 'j_temps.sv', line: 26, stmt: "is_add = op == 2'd1", fanin: { 'tb_j.dut.op': 'xx' } },
  // zq went x at 15 (zq <= 8'bx) and was rewritten x from a2 at 25 and 35: the value in effect was
  // written at the last edge, from a2, though its last change (since) is 15.
  { d: 'j', sig: 'tb_j.dut.zq', t: 40000, kind: 'proc', file: 'j_temps.sv', line: 43, stmt: 'zq <= a2;', act: 35000, since: 15000,
    fanin: { 'tb_j.dut.a2': XX, 'tb_j.dut.zsel': '10' }, roles: { 'tb_j.dut.a2': 'data', 'tb_j.dut.zsel': 'control' } },
  // p1 <= p0 then p1[3:0] <= 4'h0: p1's x bits (the high nibble, from a) came from the whole write.
  { d: 'j', sig: 'tb_j.dut.p1', t: 20000, kind: 'proc', file: 'j_temps.sv', line: 49, stmt: 'p1 <= p0;', value: 'xxxx000100100000',
    fanin: { 'tb_j.dut.p0': 'xxxx000100100010' } },
  // The x part-select write a later narrower write of known bits overlaid is the one shown, compared
  // over its own bits with the later write laid over them; also inside a wider word.
  { d: 'j', sig: 'tb_j.dut.st', t: 30000, kind: 'proc', line: 61, stmt: "st[7:2] = 6'bx;", value: 'xxxx0011', trust: 'exact' },
  { d: 'j', sig: 'tb_j.dut.w16', t: 30000, kind: 'proc', line: 66, stmt: "w16[7:0] = 'bx;", value: '00000000xxxx0011', trust: 'exact' },
  // A local declared with an initializer: the fan-in goes on through the initializer's reads.
  // (Icarus 12 does not run a block local's initializer, so its dump keeps dq at x: fan-in only.)
  { d: 'j', sig: 'tb_j.dut.dq', t: 20000, kind: 'proc', line: 72, stmt: 'dq <= t2;', fanin: { t2: '*', 'tb_j.dut.b': '00100010' } },
  // A net declaration assignment whose initializer has no source text (a width extension).
  { d: 'j', sig: 'tb_j.dut.wz', t: 20000, kind: 'assign', stmt: 'wz = go', rhs: 'go', value: '00000001', fanin: { 'tb_j.dut.go': '1' }, trust: 'exact' },

  // ---- K: writes that aren't re-executed: a driver that may have written, never a confident "nothing" ----
  // A simulator's own task given vq by name ($cmux_poke(vq, a)): it may write vq.
  { d: 'k', sig: 'tb_k.dut.vq', t: 20000, kind: 'proc', file: 'k_writes.sv', line: 21, stmt: '$cmux_poke(vq, a);', trust: 'approximate', reasons: ['statement'] },
  // A task call whose body writes tq.
  { d: 'k', sig: 'tb_k.dut.tq', t: 20000, kind: 'proc', file: 'k_writes.sv', line: 28, trust: 'approximate', reasons: ['statement'] },
  // fq <= bump(a), and bump's body writes fcnt.
  // ky = a, then if (go) kz = a: the later if doesn't write ky, so go isn't in its fan-in.
  { d: 'k', sig: 'tb_k.dut.ky', t: 30000, kind: 'proc', file: 'k_writes.sv', line: 39, stmt: 'ky = a;', fanin: { 'tb_k.dut.a': '00100010' }, noFanin: ['tb_k.dut.go'] },
  // fr went x at 15 (xa x), then the testbench forced it at 22: the runs at 25 and 35 write 05, so
  // the x in effect is still traced at 15, not moved to the last edge.
  { d: 'k', sig: 'tb_k.dut.fr', t: 40000, kind: 'proc', file: 'k_writes.sv', line: 44, stmt: 'fr <= xa;', act: 15000, since: 15000, value: XX,
    fanin: { 'tb_k.dut.xa': XX } },
  // cnt is written only by its if's condition (cnt++ == 3), in a live procedure.
  { d: 'k', sig: 'tb_k.dut.cnt', t: 20000, kind: 'proc', file: 'k_writes.sv', line: 47, trust: 'approximate', reasons: ['statement'] },
  // gq <= a, but the testbench forced it to 77 at 27; dq's last own write was 11 at 15, then the
  // testbench deposited 44 at 27: the testbench's statement, approximate ('force'), never exact.
  { d: 'k', sig: 'tb_k.dut.gq', t: 30000, kind: 'initial', file: 'tb_k.sv', stmt: 'force dut.gq', since: 27000, value: '01110111', trust: 'approximate', reasons: ['force'] },
  { d: 'k', sig: 'tb_k.dut.dq', t: 30000, kind: 'initial', file: 'tb_k.sv', stmt: '$deposit(dut.dq', since: 27000, value: '01000100', trust: 'approximate', reasons: ['force'] },
  // lq <= c17 through 18 blocking temps: the fan-in stops at 16 of them, with a 'limits' reason.
  { d: 'k', sig: 'tb_k.dut.lq', t: 20000, kind: 'proc', file: 'k_writes.sv', stmt: 'lq <= c17;', trust: 'approximate', reasons: ['limits'] },
  { d: 'k', sig: 'tb_k.dut.fcnt', t: 30000, kind: 'proc', file: 'k_writes.sv', line: 35, stmt: 'fq <= bump(a);', trust: 'approximate', reasons: ['statement'] },
  // ---- L: classes a Verdi oracle run found exact but wrong, as Verdi answers them ----
  // A: a reset declared low and raised by the initial block after clock edges: the write that
  // raised it (approximate, the testbench's), never the declaration; through the port too.
  { d: 'l', sig: 'tb_l.rst_n', t: 40000, kind: 'initial', file: 'tb_l.sv', line: 27, stmt: "rst_n = 1'b1;", since: 26000, value: '1', trust: 'approximate', root: 'testbench' },
  { d: 'l', sig: 'tb_l.dut.rst_n', t: 40000, kind: 'portIn', since: 26000, fanin: { 'tb_l.rst_n': '1' } },
  // Values from the initial block's opening statements (a plusarg, then a copy): their writes.
  { d: 'l', sig: 'tb_l.epoch_iters', t: 40000, kind: 'initial', file: 'tb_l.sv', line: 24, stmt: 'epoch_iters = iters;', trust: 'approximate' },
  { d: 'l', sig: 'tb_l.iters', t: 40000, kind: 'initial', file: 'tb_l.sv', stmt: 'iters = 4;', trust: 'approximate' },
  // A counter incremented in a clocked block of the testbench: that statement.
  { d: 'l', sig: 'tb_l.settle', t: 40000, file: 'tb_l.sv', stmt: 'settle++;', trust: 'approximate' },
  // A, as the oracle's model had it ('stale': no statement lists what it writes, and the initial
  // block is one statement slang could not elaborate). The block may write anything: it is named,
  // approximate; a value nothing explains is never exact, and the declaration did not make a
  // value that changed at 26.
  { d: 'l', sig: 'tb_l.rst_n', t: 40000, dumps: ['stale'], kind: 'initial', file: 'tb_l.sv', line: 18, since: 26000, trust: 'approximate', reasons: ['opaque'] },
  { d: 'l', sig: 'tb_l.epoch_iters', t: 40000, dumps: ['stale'], kind: 'initial', file: 'tb_l.sv', line: 18, trust: 'approximate', reasons: ['opaque'] },
  { d: 'l', sig: 'tb_l.iters', t: 40000, dumps: ['stale'], kind: 'initial', file: 'tb_l.sv', line: 18, trust: 'approximate', reasons: ['opaque'] },
  // The initial block may write settle too: named, approximate. With only the write lists gone
  // ('nowrites': settle++ is opaque and says nothing), nothing found writes it, yet it changed at 35.
  { d: 'l', sig: 'tb_l.settle', t: 40000, dumps: ['stale'], kind: 'initial', line: 18, since: 35000, trust: 'approximate', reasons: ['opaque'] },
  { d: 'l', sig: 'tb_l.settle', t: 40000, dumps: ['nowrites'], kind: 'none', since: 35000, trust: 'approximate', reasons: ['writeNotFound'] },
  { d: 'l', sig: 'tb_l.iters', t: 40000, dumps: ['nowrites'], kind: 'initial', stmt: 'iters = 4;', trust: 'approximate', noReasons: ['writeNotFound'] },
  // B: y unchanged since 35 (the override made it); at 40 and 50 the default gives the same value
  // (sel fell at 45). The statement that made the value, run when it changed, as Verdi names it.
  { d: 'l', sig: 'tb_l.dut.y', t: 50000, kind: 'proc', proc: 'Always', file: 'l_oracle.sv', line: 19, stmt: 'y = b;', since: 35000, sample: 35000, value: '00110011', trust: 'exact' },
  { d: 'l', sig: 'tb_l.dut.y', t: 40000, kind: 'proc', line: 19, stmt: 'y = b;', since: 35000, value: '00110011', trust: 'exact' },
  // c = 0 by the override while in reset (2), then by the default (26): the override, as Verdi
  // names picorv32's clear_prefetched_high_word at t=0. (Both write 1'b0: the line tells them apart.)
  { d: 'l', sig: 'tb_l.dut.c', t: 40000, kind: 'proc', file: 'l_oracle.sv', line: 24, since: 2000, value: '0', trust: 'exact' },
  // A1: a value nothing in the model writes is the start value only as the type starts: x for a
  // 4-state type, 0 for a 2-state one ('hidden': the initial block that wrote mode4 = 0 left out).
  { d: 'l', sig: 'tb_l.mode4', t: 40000, kind: 'initial', stmt: "mode4 = 4'b0;", trust: 'approximate' },
  { d: 'l', sig: 'tb_l.mode4', t: 40000, dumps: ['hidden'], value: '0000', trust: 'approximate', reasons: ['writeNotFound'] },
  { d: 'l', sig: 'tb_l.mode2', t: 40000, dumps: ['hidden'], value: '00000000000000000000000000000000', trust: 'exact', noReasons: ['writeNotFound'] },
  // B1: two writers that both explain the value: which one made it is not known.
  { d: 'l', sig: 'tb_l.dut.y', t: 50000, dumps: ['two'], kind: 'proc', value: '00110011', trust: 'approximate', reasons: ['multiDriven'] },
  // F: a flop that never took a value is its start value (x since 0), not its block.
  { d: 'l', sig: 'tb_l.dut.k', t: 40000, kind: 'none', since: 0, value: 'xxxxxxxx', trust: 'exact' },

];

// The model an older cmux-sv-model gave (the one the Verdi oracle ran on): no statement lists what
// it writes, and an initial block slang could not elaborate is one opaque statement.
// ('nowrites': the write lists only.)
// Load trace (who reads a signal: engine.loads): each case's entries, as
// 'kind/role/line/targets' (targets joined by ','), in the order loads gives them; `page`
// [offset, limit, total, next] checks one page.
const LOAD_CASES = [
  // A flop's output read by a continuous assign and as an always_comb's if condition.
  { d: 'a', sig: 'tb_a.dut.valid_q', want: ['assign/data/23/tb_a.dut.sum', 'stmt/condition/28/tb_a.dut.stage'] },
  // An input read as data (valid_q <= en) and as a condition (if (en) acc <= ...).
  { d: 'a', sig: 'tb_a.dut.en', want: ['stmt/data/18/tb_a.dut.valid_q', 'stmt/condition/21/tb_a.dut.acc'] },
  // A clock: each edge procedure's sensitivity, its writes the targets.
  { d: 'a', sig: 'tb_a.dut.clk', want: ['event/sensitivity/16/tb_a.dut.valid_q', 'event/sensitivity/20/tb_a.dut.acc', 'event/sensitivity/32/tb_a.dut.dout'] },
  { d: 'a', sig: 'tb_a.dut.clk', page: [1, 1, 3, 2], want: ['event/sensitivity/20/tb_a.dut.acc'] },
  { d: 'a', sig: 'tb_a.dut.clk', page: [2, 64, 3, null], want: ['event/sensitivity/32/tb_a.dut.dout'] },
  // The testbench's clock: its own toggle, and the DUT's input port it connects (the next hop down).
  { d: 'a', sig: 'tb_a.clk', want: ['portIn/connection/6/tb_a.dut.clk', 'stmt/data/7/tb_a.clk'] },
  // An output port: the parent's signal connected to it (the next hop up).
  { d: 'a', sig: 'tb_a.dut.dout', want: ['portOut/connection/6/tb_a.dout'] },
  // Read into a block-local temporary (tmp = sum + 1).
  { d: 'a', sig: 'tb_a.dut.sum', want: ['stmt/data/27/$local:tmp'] },
  // Read by nothing.
  { d: 'a', sig: 'tb_a.dout', want: [] },
];

// Active loads at a time (engine.loadsAt): each entry as 'line/role/status' in loads' order;
// `follow` { line: [path, time] }: where following that entry goes (the change it caused);
// `trust` { line: trust }. The reader's last activation at or before t is judged (the dump is
// searched backward, as driver tracing does): a flop whose input changed after its last edge is
// 'pending'.
const LOAD_AT_CASES = [
  // valid_q went 0 -> 1 at 45: sum = acc ^ {8{valid_q}} stays x (no change); the always_comb's
  // if (valid_q) takes its then branch.
  { d: 'a', sig: 'tb_a.dut.valid_q', t: 50, want: ['23/data/noChange', '28/condition/taken'] },
  { d: 'a', sig: 'tb_a.dut.valid_q', t: 30, want: ['23/data/noChange', '28/condition/untaken'] },
  // en rose at 40, sampled at the edge at 45: valid_q <= en made valid_q's change at 45.
  { d: 'a', sig: 'tb_a.dut.en', t: 50, want: ['18/data/propagated', '21/condition/taken'], follow: { 18: ['tb_a.dut.valid_q', 45] }, trust: { 18: 'exact' } },
  // At 42 the last edge (35) came before en's change: not sampled yet.
  { d: 'a', sig: 'tb_a.dut.en', t: 42, want: ['18/data/pending', '21/condition/pending'] },
  // The clock's posedge at 45 triggered each edge procedure; its negedge at 50 none.
  { d: 'a', sig: 'tb_a.dut.clk', t: 45, want: ['16/sensitivity/triggered', '20/sensitivity/triggered', '32/sensitivity/triggered'] },
  { d: 'a', sig: 'tb_a.dut.clk', t: 50, want: ['16/sensitivity/notTriggered', '20/sensitivity/notTriggered', '32/sensitivity/notTriggered'] },
  // din: read into acc at 45 (acc stays x), and stage = din is on the else branch, not run at 50.
  { d: 'a', sig: 'tb_a.dut.din', t: 50, want: ['21/data/noChange', '29/data/notRun'] },
  // The testbench clock: the DUT's clk port follows it at 50; its own toggle is stimulus.
  { d: 'a', sig: 'tb_a.clk', t: 50, want: ['6/connection/propagated', '7/data/stimulus'], follow: { 6: ['tb_a.dut.clk', 50] } },
  // An output port: the parent's dout changed with it at 25.
  { d: 'a', sig: 'tb_a.dut.dout', t: 30, want: ['6/connection/propagated'], follow: { 6: ['tb_a.dout', 25] } },
  // Into a block-local temporary (not dumped): read, nothing to follow.
  { d: 'a', sig: 'tb_a.dut.sum', t: 50, want: ['27/data/read'] },
];

// Follow forward: an entry's target's first change at or after t (engine.nextOf), on a provider
// with nextChange; without one, null (the page falls back to the change the read caused).
// line: the load entry; want: [path, time] | null (no later change); back: the provider has no nextChange.
const NEXT_CASES = [
  // en rose at 40; at 42 its read is pending: valid_q takes it at the edge at 45.
  { d: 'a', sig: 'tb_a.dut.en', t: 42, line: 18, want: ['tb_a.dut.valid_q', 45] },
  // At a change itself: at or after, so the same time.
  { d: 'a', sig: 'tb_a.clk', t: 50, line: 6, want: ['tb_a.dut.clk', 50] },
  // No nextChange in the provider: no forward answer.
  { d: 'a', sig: 'tb_a.dut.en', t: 42, line: 18, back: true, want: null },
  // Into a block-local temporary: nothing dumped to follow.
  { d: 'a', sig: 'tb_a.dut.sum', t: 50, line: 27, want: null },
];

// The load list against Verdi's (oracle-loads/<design>.json: npi-loads.py's lang.trace_load2 on
// each design's VCS KDB, is_pass_thr off = `stop`, on = `through`). A load is keyed by file:line,
// a port connection by the signals it reaches (Verdi places it at the child's port declaration, we
// at the instance). Verdi's "load in an upper statement" entries (statements under a condition or
// event that reads the signal) are ours as that condition or event entry. `through` is compared
// with ours followed through each port connection. The differences left, each with its reason:
// An interface's signal: Verdi lists each modport that takes it as an input (keyed by the
// modport port, iface.modport.name); ours list those too, plus the reads through the interface
// port in each instance it reaches (INTERFACE_READS), which Verdi does not list: counted, not listed.
// verdiOnly (and upper: an upper statement with no condition or event of ours reading the signal)
//   dumpTask: $dumpvars naming the signal (a dump directive, not a design read);
//   sysFunctionOutput: $value$plusargs's output argument (it writes the signal), and the statement
//     under that condition (upper);
// oursOnly
//   assignmentPattern: a read inside an assignment pattern ('{a: x, ...}), which Verdi does not list;
//   localInitializer: a procedural block local's declaration initializer, which Verdi does not list;
//   lvalueIndex: an index read in a two-level target select in a loop (mem[widx][8*b +: 8] <=),
//     which Verdi does not list (it does list mem[waddr] <=);
//   increment: x++ reads x; Verdi does not list it.
// Statements slang leaves opaque (loops, calls) are listed when their text names the signal
// (role 'opaque', maybe): Verdi's loads inside for and repeat loops match them.
const INTERFACE_READS = {
  'tb_n.bus.data': ['tb_n.u_prod:20', 'tb_n.u_mid.u_leaf:28', 'tb_n.u_mon:36'],
  'tb_n.bus.valid': ['tb_n:10', 'tb_n.u_mid.u_leaf:28', 'tb_n.u_mon:36'],
  'tb_n.bus.clk': ['tb_n.u_prod:15', 'tb_n.u_mid.u_leaf:27'],
  'tb_n.bus.ready': ['tb_n.u_prod:19'],
  'tb_f.bus.addr': ['tb_f.u_mem:23'],
  'tb_f.bus.req': ['tb_f.u_mem:23', 'tb_f.u_mem:28'],
  'tb_f.bus.clk': ['tb_f.u_mem:26', 'tb_f.dut:33'],
  'tb_f.bus.resp': ['tb_f.dut:39'],
  'tb_f.bus.rdata': ['tb_f.dut:39'],
};
const LOAD_ORACLE_DIFFS = [
  'verdiOnly h tb_h.dut.mem tb_h.sv:17 dumpTask',
  'verdiOnly i tb_i.dut.lost tb_i.sv:25 dumpTask',
  'verdiOnly i tb_i.dut.mem tb_i.sv:26 dumpTask',
  'verdiOnly i tb_i.iters tb_i.sv:16 sysFunctionOutput',
  'verdiOnly l tb_l.iters tb_l.sv:23 sysFunctionOutput',
  'upper i tb_i.iters tb_i.sv:16 sysFunctionOutput',
  'upper l tb_l.iters tb_l.sv:23 sysFunctionOutput',
  'oursOnly c tb_c.dut.u_src.data_q c_struct.sv:37 assignmentPattern',
  'oursOnly c tb_c.dut.u_src.id_q c_struct.sv:37 assignmentPattern',
  'oursOnly c tb_c.dut.u_src.valid_q c_struct.sv:37 assignmentPattern',
  'oursOnly j tb_j.dut.b j_temps.sv:71 localInitializer',
  'oursOnly i tb_i.dut.widx i_drivers.sv:30 lvalueIndex',
  'oursOnly i tb_i.settle tb_i.sv:14 increment',
  'oursOnly l tb_l.settle tb_l.sv:34 increment',
];

function staleModel(all, invalidInitial) {
  const strip = (x) => {
    if (Array.isArray(x)) { x.forEach(strip); return; }
    if (!x || typeof x !== 'object') { return; }
    delete x.writes;
    Object.values(x).forEach(strip);
  };
  for (const m of Object.values(all.instances)) {
    strip(m.procs);
    for (const p of m.procs) { if (invalidInitial && p.kind === 'Initial') { p.body = { k: 'opaque', why: 'Invalid', src: p.body.src || '', loc: p.loc }; } }
  }
}

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
    // 'stale': the Icarus dump with the model an older sidecar gave for that testbench.
    if (variant === 'stale' || variant === 'nowrites') { staleModel(all, variant === 'stale'); }
    // 'hidden': the testbench's initial blocks left out of the model (a write the model doesn't show).
    if (variant === 'hidden') { for (const m of Object.values(all.instances)) { m.procs = m.procs.filter((p) => p.kind !== 'Initial'); } }
    // 'two': the DUT's first always @* listed twice (two writers that both explain the value).
    if (variant === 'two') { const m = all.instances['tb_l.dut']; m.procs.splice(1, 0, JSON.parse(JSON.stringify(m.procs[0]))); }
    const onIcarus = ['stale', 'nowrites', 'hidden', 'two'].includes(variant);
    const vcd = traceVcd(traceFiles.dumps[`${d}.${onIcarus ? 'icarus' : variant}`]);
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
    if (c.from) { want('from', step.driver && step.driver.from, c.from); }
    if (c.proc) { want('proc', step.procKind || (step.driver && step.driver.procKind), c.proc); }
    if (c.file) { want('file', base(step.stmt && step.stmt.loc && step.stmt.loc.file), c.file); }
    if (c.line) { want('line', step.stmt && step.stmt.loc && step.stmt.loc.line, c.line); }
    const squeeze = (x) => String(x).replace(/\s+/g, ' ');
    if (c.rhs && !(step.stmt && squeeze(step.stmt.rhs || '') === squeeze(c.rhs))) { bad.push(`rhs: ${JSON.stringify(step.stmt && step.stmt.rhs)} != ${JSON.stringify(c.rhs)}`); }
    if (c.stmt) { if (!(step.stmt && squeeze(step.stmt.src).includes(squeeze(c.stmt)))) { bad.push(`stmt: ${JSON.stringify(step.stmt && step.stmt.src)} lacks ${JSON.stringify(c.stmt)}`); } }
    if (c.act !== undefined) { want('activation', step.activation && step.activation.time, c.act); }
    if (c.sample !== undefined) { want('sample', step.sample, c.sample); }
    if (c.since !== undefined) { want('since', step.since, c.since); }
    if (c.value !== undefined) { want('value', step.value, c.value); }
    if (c.trust) { want('trust', step.trust, c.trust); }
    if (c.noTrust && step.trust === c.noTrust) { bad.push(`trust is ${step.trust}, which it must not be`); }
    if (c.root) { want('root', step.root, c.root); }
    for (const [k, v] of Object.entries(c.fanin || {})) {
      const f = (step.fanin || []).find((x) => x.path === k || (x.local && x.name === k));
      if (!f) { bad.push(`fan-in lacks ${k} (has ${(step.fanin || []).map((x) => x.path || x.name).join(', ')})`); } else if (v !== '*' && f.value !== v) { bad.push(`fan-in ${k} = ${f.value} != ${v}`); }
    }
    for (const k of c.noFanin || []) {
      if ((step.fanin || []).some((x) => x.path === k || (x.local && x.name === k))) { bad.push(`fan-in has ${k}, which isn't why it has its value`); }
    }
    for (const [k, v] of Object.entries(c.roles || {})) {
      const f = (step.fanin || []).find((x) => (x.path === k || (x.local && x.name === k)) && x.role === v);
      if (!f) { bad.push(`fan-in lacks ${k} as ${v} (roles ${(step.fanin || []).filter((x) => x.path === k || x.name === k).map((x) => x.role).join(', ') || 'none'})`); }
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
    // Load trace: the static readers of a signal.
    for (const c of LOAD_CASES) {
      results.cases++;
      const what = `loads ${c.d} ${c.sig}${c.page ? ' page ' + JSON.stringify(c.page) : ''}`;
      let got;
      try {
        const opts = c.page ? { offset: c.page[0], limit: c.page[1] } : {};
        got = await engineFor(c.d, 'icarus').engine.loads(c.sig, opts);
      } catch (error) {
        got = { error: String(error && error.message || error) };
      }
      const bad = [];
      if (got.error) {
        bad.push('error ' + got.error);
      } else {
        const lines = got.entries.map((e) => `${e.kind}/${e.role}/${e.loc ? e.loc.line : '?'}/${(e.targets || []).join(',')}`);
        if (JSON.stringify(lines) !== JSON.stringify(c.want)) { bad.push(`entries ${JSON.stringify(lines)} != ${JSON.stringify(c.want)}`); }
        if (c.page && (got.total !== c.page[2] || got.next !== c.page[3])) { bad.push(`total/next ${got.total}/${got.next} != ${c.page[2]}/${c.page[3]}`); }
        for (const e of got.entries) {
          if (!e.loc || !e.loc.file || !e.src) { bad.push(`entry without loc or src: ${JSON.stringify(e)}`); }
        }
      }
      if (bad.length) { results.failures++; out.push(`FAIL ${what}: ${bad.join('; ')}`); } else { out.push(`ok   ${what}: ${got.entries.length} of ${got.total}`); }
    }
    for (const c of LOAD_AT_CASES) {
      results.cases++;
      const what = `loadsAt ${c.d} ${c.sig} @${c.t}`;
      let got;
      try {
        got = await engineFor(c.d, 'icarus').engine.loadsAt(c.sig, c.t);
      } catch (error) {
        got = { error: String(error && error.message || error) };
      }
      const bad = [];
      if (got.error) {
        bad.push('error ' + got.error);
      } else {
        const lines = got.entries.map((e) => `${e.loc ? e.loc.line : '?'}/${e.role}/${e.active ? e.active.status : '-'}`);
        if (JSON.stringify(lines) !== JSON.stringify(c.want)) { bad.push(`entries ${JSON.stringify(lines)} != ${JSON.stringify(c.want)}`); }
        for (const [line, [path, time]] of Object.entries(c.follow || {})) {
          const e = got.entries.find((x) => x.loc && x.loc.line === Number(line));
          const f = e && e.active && e.active.follow;
          if (!f || f.path !== path || f.time !== time) { bad.push(`follow ${line}: ${JSON.stringify(f)} != ${path}@${time}`); }
        }
        for (const [line, trust] of Object.entries(c.trust || {})) {
          const e = got.entries.find((x) => x.loc && x.loc.line === Number(line));
          if (!e || !e.active || e.active.trust !== trust) { bad.push(`trust ${line}: ${e && e.active && e.active.trust} != ${trust}`); }
        }
      }
      if (bad.length) { results.failures++; out.push(`FAIL ${what}: ${bad.join('; ')}`); } else { out.push(`ok   ${what}`); }
    }
    // The load lists against Verdi's (LOAD_ORACLE_DIFFS).
    {
      const oracle = traceFiles.loadOracle || {};
      const seen = [];
      const counts = { match: 0, upper: 0, through: 0, throughMatch: 0 };
      const keyOurs = (e) => (e.kind === 'portIn' || e.kind === 'portOut' || e.kind === 'modport' ? 'port:' + (e.targets || []).slice().sort().join(',') : base(e.loc && e.loc.file) + ':' + (e.loc && e.loc.line));
      const keyVerdi = (x) => (/Port$/.test(x.type || '') ? 'port:' + x.targets.slice().sort().join(',') : x.file + ':' + x.line);
      // (the model VCS compiled, without __ICARUS__: loads read no dump)
      const oracleEngines = {};
      const oracleEngine = (d) => {
        if (oracleEngines[d]) { return oracleEngines[d]; }
        const all = JSON.parse(traceFiles.models[d]);
        const models = {
          instance: async (p) => all.instances[p],
          writers: async () => [],
          lookup: async (p) => {
            let best = null;
            for (const k of Object.keys(all.instances)) { if ((p === k || p.startsWith(k + '.')) && (!best || k.length > best.length)) { best = k; } }
            return best ? { instance: best, name: p.slice(best.length + 1) } : null;
          },
        };
        const none = { values: async () => new Map(), lastChange: async () => null, prevEdge: async () => null };
        oracleEngines[d] = cmuxTrace.createEngine({ models, dump: none });
        return oracleEngines[d];
      };
      const oursOf = async (d, sig) => ((await oracleEngine(d).loads(sig, { limit: 100000 })).entries || []);
      for (const d of Object.keys(oracle).sort()) {
        const signals = JSON.parse(oracle[d]).signals;
        for (const sig of Object.keys(signals).sort()) {
          results.cases++;
          const o = signals[sig];
          let ours;
          try { ours = await oursOf(d, sig); } catch (error) { results.failures++; out.push(`FAIL load oracle ${d} ${sig}: ${error && error.message || error}`); continue; }
          const ok = new Set(ours.map(keyOurs));
          const direct = o.stop.filter((x) => !x.upper);
          const vk = new Set(direct.map(keyVerdi));
          for (const x of direct) { if (ok.has(keyVerdi(x))) { counts.match++; } else { seen.push(`verdiOnly ${d} ${sig} ${keyVerdi(x)}`); } }
          // Reads through an interface port, in another instance than the interface's own.
          const via = ours.filter((y) => y.via === 'interface');
          const want = INTERFACE_READS[sig];
          const got = [...new Set(via.map((y) => y.instance + ':' + (y.loc && y.loc.line)))].sort();
          if (want && JSON.stringify(got) !== JSON.stringify(want.slice().sort())) { seen.push(`interfaceReads ${d} ${sig} ${JSON.stringify(got)}!=${JSON.stringify(want)}`); }
          if (!want && via.length) { seen.push(`interfaceReads ${d} ${sig} unexpected ${JSON.stringify(got)}`); }
          counts.interfaceRead = (counts.interfaceRead || 0) + via.length;
          for (const y of ours) { if (y.via !== 'interface' && !vk.has(keyOurs(y))) { seen.push(`oursOnly ${d} ${sig} ${keyOurs(y)}`); } }
          // An upper statement's signal read in a condition or event of ours.
          const ctl = ours.some((y) => y.role === 'condition' || y.role === 'sensitivity' || y.role === 'opaque');
          for (const x of o.stop.filter((z) => z.upper)) { counts.upper++; if (!ctl) { seen.push(`upper ${d} ${sig} ${keyVerdi(x)}`); } }
          // Through ports: ours followed through each port connection, transitively.
          const closure = new Set();
          const todo = [sig];
          const done = new Set();
          while (todo.length) {
            const s0 = todo.pop();
            if (done.has(s0)) { continue; }
            done.add(s0);
            let es = [];
            try { es = await oursOf(d, s0); } catch (error) { es = []; }
            for (const e of es) {
              closure.add(keyOurs(e));
              if (e.kind === 'portIn' || e.kind === 'portOut') { (e.targets || []).forEach((t) => todo.push(t)); }
            }
          }
          for (const x of o.through.filter((z) => !z.upper)) {
            counts.through++;
            if (closure.has(keyVerdi(x))) { counts.throughMatch++; } else { seen.push(`through ${d} ${sig} ${keyVerdi(x)}`); }
          }
        }
      }
      // A through-only difference is fine when it is one of the stop differences (of a signal the ports reach).
      const stopKeys = new Set(LOAD_ORACLE_DIFFS.map((l) => l.split(' ')[3]));
      const left = seen.filter((l) => !(l.startsWith('through ') && stopKeys.has(l.split(' ')[3])));
      const expected = LOAD_ORACLE_DIFFS.map((l) => l.split(' ').slice(0, 4).join(' '));
      const extra = left.filter((l) => !expected.includes(l));
      const gone = expected.filter((l) => !left.includes(l));
      results.cases++;
      if (Object.keys(oracle).length === 0) { results.failures++; out.push('FAIL load oracle: no fixtures'); }
      else if (extra.length || gone.length) { results.failures++; out.push(`FAIL load oracle: ${counts.match} match, ${extra.length} unexplained: ${extra.join('; ')}${gone.length ? '; listed but not seen: ' + gone.join('; ') : ''}`); }
      else { out.push(`ok   load oracle: ${counts.match} match, ${counts.upper} upper, through ${counts.throughMatch}/${counts.through}, ${counts.interfaceRead} interface reads, ${expected.length} listed differences`); }
    }
    for (const c of NEXT_CASES) {
      results.cases++;
      const what = `nextOf ${c.d} ${c.sig} @${c.t} :${c.line}${c.back ? ' (no nextChange)' : ''}`;
      const bad = [];
      try {
        const eng = engineFor(c.d, 'icarus');
        const saved = eng.vcd.provider.nextChange;
        if (c.back) { delete eng.vcd.provider.nextChange; }
        try {
          const got = await eng.engine.loadsAt(c.sig, c.t);
          const e = got.entries.find((x) => x.loc && x.loc.line === c.line);
          if (!e) { bad.push('no entry at line ' + c.line); } else {
            const n = await eng.engine.nextOf(e, c.t);
            const g = n && n.time !== null ? [n.path, n.time] : null;
            if (JSON.stringify(g) !== JSON.stringify(c.want)) { bad.push(`next ${JSON.stringify(n)} != ${JSON.stringify(c.want)}`); }
            if (n && n.direction !== 'forward') { bad.push('direction ' + n.direction); }
          }
        } finally { eng.vcd.provider.nextChange = saved; }
      } catch (error) { bad.push('error ' + String(error && error.message || error)); }
      if (bad.length) { results.failures++; out.push(`FAIL ${what}: ${bad.join('; ')}`); } else { out.push(`ok   ${what}`); }
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
              // Held since 0 at the value it started with (x, or 0 for a 2-state type), with no write
              // missing: nothing drove it yet, which is no missing driver.
              const held = Number(step.since) === 0 && !(step.reasons || []).some((r) => r.code === 'writeNotFound');
              if (step.driver && step.driver.kind === 'none' && held) { tally.startValue = (tally.startValue || 0) + 1; }
              if (step.driver && step.driver.kind === 'none' && !held) { tally.noDriver = (tally.noDriver || 0) + 1; if (tally.noDriver <= 3) { out.push(`ORACLE ${d}.${variant} ${p} @${t}: no driver`); } }
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
    // Trace X to Root over the engine (the page's step and probe are its active()).
    const xc = (d, path, t, config) => {
      const { engine } = engineFor(d, 'icarus');
      return cmuxTrace.xChain({ path, time: t }, Object.assign({ step: (p, at) => engine.active(p, at) }, config || {}));
    };
    const chainWant = (what, got, exp) => {
      results.cases++;
      if (JSON.stringify(got) === JSON.stringify(exp)) { out.push(`ok   chain ${what}`); return; }
      results.failures++;
      out.push(`FAIL chain ${what}: ${JSON.stringify(got)} != ${JSON.stringify(exp)}`);
    };
    // An unreset counter (cnt <= cnt + 1, x since the start): uninitialised storage, not a loop.
    const cnt = await xc('j', 'tb_j.dut.cnt', 30000);
    chainWant('unreset counter', [cnt.end.code, cnt.root, cnt.steps.map((e) => e.signal)], ['uninit', 0, ['tb_j.dut.cnt']]);
    // A step whose value has no x though its probe had (the two disagree): the next candidate.
    const fake = {
      q: { signal: 'q', time: 10, value: 'x', since: 8, driver: { kind: 'proc' }, fanin: [{ path: 'a', value: 'x', time: 9 }, { path: 'b', value: 'x', time: 9 }] },
      a: { signal: 'a', time: 9, value: 'x', since: 2, driver: { kind: 'proc' }, fanin: [] },
      b: { signal: 'b', time: 9, value: 'x', since: 5, driver: { kind: 'none' }, fanin: [] },
    };
    const mismatch = await cmuxTrace.xChain({ path: 'q', time: 10 }, {
      probe: async (p) => fake[p],
      step: async (p) => (p === 'a' ? Object.assign({}, fake.a, { value: '0' }) : fake[p]),
    });
    chainWant('a step with no x is not followed', [mismatch.end.code, mismatch.steps.map((e) => e.signal)], ['uninit', ['q', 'b']]);
    const none = await cmuxTrace.xChain({ path: 'q', time: 10 }, {
      probe: async (p) => fake[p],
      step: async (p) => (p === 'q' ? fake.q : Object.assign({}, fake[p], { value: '0' })),
    });
    chainWant('no candidate with x left', [none.end.code, none.root, none.steps.map((e) => e.signal)], ['failed', -1, ['q']]);
    // cnt <= cnt + in, both x since the start: the input it has not seen is where the x came from.
    const ring = {
      cnt: { signal: 'cnt', time: 10, value: 'x', since: 0, driver: { kind: 'proc' }, fanin: [{ path: 'cnt', value: 'x', time: 9 }, { path: 'in', value: 'x', time: 9 }] },
      in: { signal: 'in', time: 9, value: 'x', since: 0, driver: { kind: 'none' }, fanin: [] },
    };
    const tied = await cmuxTrace.xChain({ path: 'cnt', time: 10 }, { step: async (p) => ring[p] });
    chainWant('a tie in since goes to the candidate not seen', [tied.root, tied.steps.map((e) => e.signal)], [1, ['cnt', 'in']]);
    return out;
  }
  return run().then((lines) => { globalThis.__traceDone = { lines, results }; }, (error) => { globalThis.__traceDone = { lines: out.concat(['FAIL ' + (error && error.stack || error)]), results: { failures: 1 } }; });
}
