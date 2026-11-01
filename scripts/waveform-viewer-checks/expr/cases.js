// The cases run.sh expr checks cmux-expr.js against: [expression, expected], where expected is
// the value as format() writes it in the radix its base letter names (8'h3c, 4'b10x1), or
// 'error:<key>@<column>' (0-based) for one that is refused.
/* global cmuxExpr */
function runExprCases() {
  const E = cmuxExpr;
  // The signals the cases read, by path: width, declared range, value (most significant bit first).
  const signals = {
    a: { width: 8, value: '00111100' },
    b: { width: 8, value: '11110000' },
    c4: { width: 4, value: '10x1' },
    z4: { width: 4, value: 'zzzz' },
    one: { width: 1, value: '1' },
    zero: { width: 1, value: '0' },
    xbit: { width: 1, value: 'x' },
    r: { width: 8, msb: 15, lsb: 8, value: '10100101' },
    asc: { width: 4, msb: 0, lsb: 3, value: '1000' },
    'u_core.count': { width: 4, value: '1001' },
    'gen[0].q': { width: 1, value: '1' },
    'a.b': { width: 1, value: '0', escaped: true },
    w100: { width: 100, value: '1'.repeat(100) },
    w64: { width: 64, value: '0'.repeat(64) },
  };
  const env = (path) => {
    const key = path.length === 1 && path[0] === 'a.b' ? 'a.b' : path.join('.');
    const s = signals[key];
    if (!s || (key === 'a.b' && path.length !== 1)) { return null; }
    return { width: s.width, msb: s.msb, lsb: s.lsb, value: E.fromBits(s.value, s.width) };
  };
  const cases = [
    // widths: context-determined, unsized literals 32 bits
    ["8'hff + 1", "32'h00000100"],
    ["8'hff + 8'h01", "8'h00"],
    ['a + b', "8'h2c"],
    ["{1'b0, a} + {1'b0, b}", "9'h12c"],
    ['a * 2', "32'h00000078"],
    ['a - b', "8'h4c"],
    ['-a', "8'hc4"],
    ['+a', "8'h3c"],
    // bitwise, 4-state
    ['a & b', "8'h30"], ['a | b', "8'hfc"], ['a ^ b', "8'hcc"], ['a ~^ b', "8'h33"], ['a ^~ b', "8'h33"], ['~a', "8'hc3"],
    ["c4 & 4'b0000", "4'b0000"], ["c4 | 4'b1111", "4'b1111"], ["c4 & 4'b1111", "4'b10x1"], ["c4 ^ 4'b0000", "4'b10x1"],
    ['~c4', "4'b01x0"], ["z4 & 4'b1111", "4'bxxxx"], ["z4 | 4'b1111", "4'b1111"], ['z4', "4'bzzzz"],
    // arithmetic with an unknown bit: all x
    ['c4 + 1', "32'hxxxxxxxx"], ['c4 * 1', "32'hxxxxxxxx"], ['-c4', "4'bxxxx"],
    // equality: x when the known bits don't settle it; === exact
    ["c4 == 4'b1001", "1'bx"], ["c4 == 4'b0001", "1'b0"], ["c4 != 4'b0001", "1'b1"], ["c4 != 4'b1011", "1'bx"],
    ["c4 === 4'b10x1", "1'b1"], ["c4 === 4'b10z1", "1'b0"], ["c4 !== 4'b10z1", "1'b1"], ['z4 === z4', "1'b1"],
    ['a == 60', "1'b1"], ["a == 9'h03c", "1'b1"], ['a < b', "1'b1"], ['a <= a', "1'b1"], ['a > b', "1'b0"], ['a >= b', "1'b0"],
    ["c4 < 4'd2", "1'bx"],
    // logical
    ['!zero', "1'b1"], ['!a', "1'b0"], ['!xbit', "1'bx"], ['zero && xbit', "1'b0"], ['one || xbit', "1'b1"],
    ['one && xbit', "1'bx"], ['zero || xbit', "1'bx"], ['a && b', "1'b1"], ["c4 && 1", "1'b1"],
    // reductions
    ['&a', "1'b0"], ['|a', "1'b1"], ['^a', "1'b0"], ['~^a', "1'b1"], ['^~a', "1'b1"], ['~&b', "1'b1"], ['~|a', "1'b0"],
    ['&c4', "1'b0"], ['|c4', "1'b1"], ['^c4', "1'bx"], ["&4'b1x11", "1'bx"], ["|4'b0x00", "1'bx"], ['&w100', "1'b1"],
    // shifts: the left operand's width; an unknown amount is all x
    ['a << 2', "8'hf0"], ['a >> 2', "8'h0f"], ['a <<< 1', "8'h78"], ['a >>> 4', "8'h03"], ['a << xbit', "8'hxx"],
    ['c4 << 1', "4'b0x10"], ['a << 100', "8'h00"], ["{1'b0, a} << 1", "9'h078"],
    // ?: an unknown condition merges the two bit by bit
    ['one ? a : b', "8'h3c"], ['zero ? a : b', "8'hf0"], ['xbit ? a : b', "8'bxx11xx00"], ['xbit ? a : a', "8'h3c"],
    ["one ? 4'h1 : a", "8'h01"],
    // precedence and associativity
    ['1 + 2 * 3', "32'h00000007"], ["a & b | 8'h1", "8'h31"], ['1 + 2 == 3', "1'b1"], ['a == 60 && b == 240', "1'b1"],
    ['1 ? 2 : 0 ? 3 : 4', "32'h00000002"], ['0 ? 2 : 0 ? 3 : 4', "32'h00000004"], ['- 2 + 3', "32'h00000001"],
    ['!0 + 1', "32'h00000002"], ['(1 + 2) * 3', "32'h00000009"], ['1 << 2 + 1', "32'h00000008"], ['a | b & 0', "32'h0000003c"],
    ['a ^ b & a', "8'h0c"], ['1 < 2 == 1', "1'b1"], ['one || zero && zero', "1'b1"], ['5 - 3 - 1', "32'h00000001"],
    // concatenation and replication
    ['{a, b}', "16'h3cf0"], ['{2{a}}', "16'h3c3c"], ["{4{1'b1}}", "4'b1111"], ["{a[3:0], 4'h0}", "8'hc0"],
    ['{3{c4}}', "12'b10x110x110x1"], ['{a, 1}', "40'h3c00000001"],
    // selects: the declared range; out of range or an unknown index is x
    ['a[2]', "1'b1"], ['a[7:4]', "4'b0011"], ['a[0 +: 4]', "4'b1100"], ['a[7 -: 2]', "2'b00"], ['a[8]', "1'bx"],
    ['a[xbit]', "1'bx"], ['a[one]', "1'b0"], ['a[9:6]', "4'bxx00"], ['a[one +: 2]', "2'b10"],
    ['r[15:12]', "4'b1010"], ['r[8]', "1'b1"], ['r[0]', "1'bx"], ['asc[0]', "1'b1"], ['asc[3]', "1'b0"], ['asc[0:1]', "2'b10"],
    ['{a, b}[11:4]', "8'hcf"],
    // literals
    ["4'b10x?", "4'b10xz"], ["'hx", "32'hxxxxxxxx"], ["8'hx", "8'hxx"], ["8'hz", "8'hzz"], ["a | '1", "8'hff"], ["a & '0", "8'h00"],
    ["{a, 'x}", "error:badLiteral@4"], ["12'd7", "12'h007"], ["8'shff", "8'hff"], ['1_000', "32'h000003e8"], ["8'b1010_0101", "8'ha5"],
    ["3'b1x", "3'b01x"], ["4'bx1", "4'bxxx1"], ["8'o17", "8'h0f"], ["'d12", "32'h0000000c"], ["8 'h 3c", "8'h3c"],
    ['12345678901', "34'h2dfdc1c35"], ["16'HABCD", "16'habcd"], ["1'B1", "1'b1"],
    // names: dotted paths, generate scopes, escaped identifiers, wide values
    ['u_core.count + 0', "32'h00000009"], ['gen[0].q', "1'b1"], ['\\a.b  | 0', "32'h00000000"], ['w100 + 1', "100'h0000000000000000000000000"],
    ['w100[99:96]', "4'b1111"],
    // An unsized based literal whose leftmost digit is x or z fills the whole context width (1800 5.7.1;
    // VCS W-2024.09: logic [63:0] b = 0; b | 'hx is 64 x's); another leftmost digit zero-extends.
    ["w64 | 'hx", "64'hxxxxxxxxxxxxxxxx"], ["w64 | 'h1x", "64'h000000000000001x"], ["w64 ^ 'bz", "64'hxxxxxxxxxxxxxxxx"],
    ["w64 + 'dx", "64'hxxxxxxxxxxxxxxxx"], ["{1'b1, 63'h0} | 'hz0", "64'hXxxxxxxxxxxxxxx0"], ["'hx", "32'hxxxxxxxx"],
    ["w64 | 36'hx", "64'h0000000xxxxxxxxx"],
    // slang semantics (the VCS fuzz found these): unary plus is the operand itself, z included.
    ['+c4', "4'b10x1"], ['+z4', "4'bzzzz"], ["+'hz", "32'hzzzzzzzz"],
    // Unsized decimals and 's literals are signed: a negative index, sign extension in a signed
    // context, signed comparison, and >>> shifting in the top bit (x and z too).
    ['c4[-1 +: 2]', "2'b1x"], ['r[7 +: 3]', "3'b01x"], ['asc[-1 +: 3]', "3'bx10"], ['a[-2 +: 4]', "4'b00xx"],
    ["8'sd178 * 219", "32'hffffbd46"], ['-16 >>> 16', "32'hffffffff"], ['- 1 >>> 22', "32'hffffffff"], ['-2 < 50', "1'b1"],
    ["4'sb1000 < 4'sb0111", "1'b1"], ["4'sb1000 < 4'b0111", "1'b0"], ["8'sb10000000 + 9'b0", "9'h080"], ["8'sb10000000 + 9'sb0", "9'h180"],
    ["4'sb1x00 >>> 1", "4'b11x0"], ["4'sbz000 >>> 2", "4'bzzz0"], ["4'sb1000 >>> 9", "4'b1111"], ["4'b1000 >>> 1", "4'b0100"],
    ["(4'sb1000 >>> 1) + 8'd0", "8'h04"], ["4'sb1111 == 8'hff", "1'b0"], ["4'sb1111 == 8'shff", "1'b1"], ['-1 == 32\'hffffffff', "1'b1"],
    ["{4'sb1000}  + 8'sd0", "8'h08"], ["c4[asc[0 +: 1] - 2]", "1'bx"],
    // An unknown condition: z in both arms is x (table 11-20; VCS W-2024.09 agrees, slang keeps z).
    ['xbit ? z4 : z4', "4'bxxxx"], ["xbit ? 4'b1z01 : 4'b1z01", "4'b1x01"], ["xbit ? 4'b1z01 : 4'b1z00", "4'b1x0x"],
    // refused
    ['', 'error:empty@0'], ['   ', 'error:empty@3'], ['a +', 'error:syntax@3'], ['a / b', 'error:unsupported@2'], ['a % b', 'error:unsupported@2'],
    ['a ** 2', 'error:unsupported@2'], ['a ==? b', 'error:unsupported@2'], ['a !=? b', 'error:unsupported@2'], ['a = b', 'error:unsupported@2'],
    ['$countones(a)', 'error:unsupported@0'], ['(a', 'error:syntax@2'], ['a)', 'error:syntax@1'], ['a b', 'error:syntax@2'],
    ['a ~& b', 'error:syntax@2'], ['a[one:0]', 'error:notConstant@2'], ['{0{a}}', 'error:badReplication@1'], ['{one{a}}', 'error:notConstant@1'],
    ["8'hfff", 'error:badLiteral@0'], ["8'b102", 'error:badLiteral@0'], ["0'h1", 'error:badLiteral@0'], ['a # b', 'error:syntax@2'],
    ['nope', 'error:unknownName@0'], ['a + u_core.nope', 'error:unknownName@4'], ['{50{w100}}', 'error:tooWide@0'],
    ['x'.repeat(1001), 'error:tooLong@0'],
    [Array.from({ length: 17 }, (_, i) => 's' + i).join(' + '), 'error:tooManySignals@' + Array.from({ length: 17 }, (_, i) => 's' + i).join(' + ').indexOf('s16')],
    ['a[1:0', 'error:syntax@5'], ['{a, b', 'error:syntax@5'], ["4'b1 ?", 'error:syntax@6'], ['a ? b', 'error:syntax@5'],
  ];
  const out = [];
  const check = (ok, what) => out.push((ok ? 'ok   ' : 'FAIL ') + what);
  for (const [text, expected] of cases) {
    let got;
    const parsed = E.parse(text);
    if (parsed.error) {
      got = 'error:' + parsed.error + '@' + parsed.at;
    } else {
      const result = E.evaluate(parsed.ast, env);
      if (result.error) {
        got = 'error:' + result.error + '@' + result.at;
      } else {
        const radix = { h: 'hex', b: 'binary', d: 'decimal', o: 'octal' }[(/'([hbdo])/.exec(expected) || [])[1]] || 'hex';
        got = E.format(result.value, radix);
      }
    }
    check(got === expected, JSON.stringify(text.length > 60 ? text.slice(0, 57) + '...' : text) + ' -> ' + got + (got === expected ? '' : '  (expected ' + expected + ')'));
  }
  // VCS differential-fuzz regressions (expr/fuzz-regressions.js, from fuzz.js): each case with its
  // own signals, against the bits VCS printed.
  if (typeof FUZZ_REGRESSIONS !== 'undefined') {
    for (const c of FUZZ_REGRESSIONS) {
      const byName = new Map(c.signals.map((s) => [s.name, s]));
      const fenv = (p) => {
        const s = p.length === 1 ? byName.get(p[0]) : null;
        return s ? { width: s.width, msb: s.msb, lsb: s.lsb, value: E.fromBits(s.value, s.width) } : null;
      };
      const parsed = E.parse(c.text);
      const r = parsed.error ? parsed : E.evaluate(parsed.ast, fenv);
      const got = r.error ? 'error:' + r.error : E.toBits(r.value);
      check(got === c.want, 'fuzz ' + c.seed + '#' + c.i + ' ' + JSON.stringify(c.text.length > 50 ? c.text.slice(0, 47) + '...' : c.text) + (got === c.want ? '' : '  (vcs ' + c.want + ', got ' + got + ')'));
    }
  }
  // names(): each signal once, in order, as written (resolution is the caller's).
  const names = E.names(E.parse('a + u_core.count + a + gen[0].q + \\a.b ').ast);
  check(JSON.stringify(names) === JSON.stringify([['a'], ['u_core', 'count'], ['gen[0]', 'q'], ['a.b']]), 'names: ' + JSON.stringify(names));
  // truthy(): some known bit is 1 (as an SV if takes it); x, z and 0 are not.
  const truth = ["4'b0x10", "4'b0x00", "4'b0000", "1'bz"].map((t) => E.truthy(E.evaluate(E.parse(t).ast, env).value));
  check(JSON.stringify(truth) === '[true,false,false,false]', 'truthy: ' + JSON.stringify(truth));
  // decimal and octal; unknown digits.
  const fmt = (t, radix) => E.format(E.evaluate(E.parse(t).ast, env).value, radix);
  const formats = [fmt('a', 'decimal'), fmt('c4', 'decimal'), fmt('z4', 'decimal'), fmt("4'b10z1", 'decimal'), fmt("4'bxxxx", 'decimal'), fmt("8'hff", 'octal'), fmt("8'b0000_x1zz", 'hex'), fmt("8'b0000_zzzz", 'hex'),
    fmt("8'b0000_xxxx", 'hex'), fmt("8'b0000_xzzz", 'hex'), fmt('w100', 'decimal')];
  check(JSON.stringify(formats) === JSON.stringify(["8'd60", "4'dX", "4'dz", "4'dZ", "4'dx", "8'o377", "8'h0X", "8'h0z", "8'h0x", "8'h0X", "100'd1267650600228229401496703205375"]),
    'formats: ' + JSON.stringify(formats));
  // Equal values compare equal (watches highlight a change); fromBits pads like the viewer's values.
  check(E.same(E.fromBits('1', 4), E.fromBits('0001', 4)) && !E.same(E.fromBits('x', 4), E.fromBits('z', 4)), 'same and fromBits');
  check(E.format(E.fromBits('x1', 4), 'binary') === "4'bxxx1", 'fromBits extends x: ' + E.format(E.fromBits('x1', 4), 'binary'));
  // A dump's other states (VCD/FSDB strengths): h is 1, l is 0, u, w and - are x; ? is z.
  check(E.format(E.fromBits('hluw-?10', 8), 'binary') === "8'b10xxxz10", 'fromBits of h, l, u, w, -, ?: ' + E.format(E.fromBits('hluw-?10', 8), 'binary'));
  return out;
}
