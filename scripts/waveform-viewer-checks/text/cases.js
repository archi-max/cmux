// The cases run.sh text checks cmux-textmatch.js against.
/* global cmuxTextMatch */
function runTextCases() {
  const T = cmuxTextMatch;
  const out = [];
  const eq = (name, got, want) => out.push((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'FAIL ') + name
    + (JSON.stringify(got) === JSON.stringify(want) ? '' : ': got ' + JSON.stringify(got) + ', want ' + JSON.stringify(want)));
  const bits = (n, w) => n.toString(2).padStart(w === undefined ? 32 : w, '0');
  const hits = (spec, values) => Array.from(T.judge(spec, values.map((v) => (typeof v === 'number' ? bits(v) : v))));

  // The viewer's texts (objdump style; checked against objdump 2.43.1 by the fork's own tests).
  eq('riscv li', T.textOf({ format: 'riscv' }, bits(0x00000513)), 'li a0,0');
  eq('riscv_numeric li', T.textOf({ format: 'riscv_numeric' }, bits(0x00000513)), 'li x10,0');
  eq('riscv_noalias', T.textOf({ format: 'riscv_noalias' }, bits(0x00000513)), 'addi a0,zero,0');
  eq('riscv csr', T.textOf({ format: 'riscv' }, bits(0x30531073)), 'csrw mtvec,t1');
  eq('riscv branch', T.textOf({ format: 'riscv' }, bits(0xfe029ee3)), 'bnez t0,pc-4');
  eq('riscv compressed (low 16 bits)', T.textOf({ format: 'riscv' }, bits(0x4501, 16)), 'li a0,0');
  eq('riscv x', T.textOf({ format: 'riscv' }, 'x'.repeat(32)), 'x');
  eq('hex', T.textOf({ format: 'hexadecimal' }, bits(0x3f, 8)), '3f');
  eq('hex grouped', T.textOf({ format: 'hexadecimal' }, bits(0x3f, 40)), '00_0000_003f');
  eq('signed', T.textOf({ format: 'signed' }, bits(0xf8, 8)), '-8');
  eq('ascii', T.textOf({ format: 'ascii' }, bits(0x636d7578)), 'cmux');

  // Matching: a regex, case-insensitive unless asked; one that does not parse is a substring.
  const lw = 0x0005a683, li = 0x00000513, csrw = 0x30531073;
  eq('regex', hits({ format: 'riscv', pattern: '^li\\s+a0' }, [li, lw, csrw]), [1, 0, 0]);
  eq('case-insensitive', hits({ format: 'riscv', pattern: 'CSRW MTVEC' }, [li, csrw]), [0, 1]);
  eq('case-sensitive', hits({ format: 'riscv', pattern: 'CSRW MTVEC', caseSensitive: true }, [li, csrw]), [0, 0]);
  // `0(a1` and `w mtvec,(` do not parse: each is looked for as plain text.
  eq('bad regex is a substring', hits({ format: 'riscv', pattern: '0(a1' }, [lw, li]), [1, 0]);
  eq('substring miss', hits({ format: 'riscv', pattern: 'W MTVEC,(' }, [csrw]), [0]);
  eq('substring found', hits({ format: 'riscv', pattern: 'LW A3,0(' }, [lw]), [1]);
  eq('substring case-sensitive', hits({ format: 'riscv', pattern: 'LW A3,0(', caseSensitive: true }, [lw]), [0]);

  // Register names: either naming matches by default (`li a0` and `li x10`); off, only the format's.
  eq('abi name in numeric format', hits({ format: 'riscv_numeric', pattern: 'li a0' }, [li]), [1]);
  eq('numeric name in abi format', hits({ format: 'riscv', pattern: 'li x10' }, [li]), [1]);
  eq('only the format names', hits({ format: 'riscv', pattern: 'li x10', anyRegisterNames: false }, [li]), [0]);
  eq('noalias pair', hits({ format: 'riscv_noalias', pattern: 'addi x10,x0' }, [li]), [1]);

  // ASCII: VaporView's rule, the pattern's characters as bytes anywhere in the bits.
  eq('ascii inside', hits({ format: 'ascii', pattern: 'mu' }, [0x636d7578, 0x41424344]), [1, 0]);

  // x and z values: the viewer's text, matched like any other.
  eq('hex x', hits({ format: 'hexadecimal', pattern: '^x' }, ['xxxxxxxx', bits(1, 8)]), [1, 0]);

  // Refusals.
  eq('bad format', T.check({ format: 'float', pattern: 'a' }), 'format');
  eq('empty pattern', T.check({ format: 'riscv', pattern: '' }), 'pattern');
  eq('long pattern', T.check({ format: 'riscv', pattern: 'a'.repeat(4097) }), 'patternTooLong');
  eq('alias without its file', T.check({ format: 'alias:state', pattern: 'IDLE' }), 'alias');
  eq('ok', T.check({ format: 'riscv', pattern: 'jal' }), null);
  eq('text formats', ['riscv', 'hexadecimal', 'ascii', 'alias:x', 'float', 'enum'].map(T.isTextFormat), [true, true, true, true, false, false]);

  // Alias tables (Verdi .alias lines).
  const alias = { text: JSON.stringify({ tables: { state: { '0': 'IDLE', '1': 'RUN' } } }), table: 'state', fileName: 'a.json' };
  const aliasOk = T.check({ format: 'alias:state', pattern: 'RUN', alias });
  eq('alias check', aliasOk, null);
  if (aliasOk === null) { eq('alias match', hits({ format: 'alias:state', pattern: '^run$', alias }, [bits(1, 2), bits(0, 2)]), [1, 0]); }

  // The linear-time numeric formatters equal the viewer's on random values of every alphabet.
  let seed = 12345;
  const rand = (n) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; };
  for (const alphabet of ['01', '01xz', '01xzuwlh', '01-']) {
    let bad = 0, n = 0;
    for (let k = 0; k < 400; k++) {
      const w = 1 + rand(200);
      let v = '';
      for (let i = 0; i < w; i++) { v += alphabet[rand(alphabet.length)]; }
      for (const f of ['hexadecimal', 'binary', 'decimal', 'signed']) {
        n++;
        if (T.numericText(f, v) !== T.viewerText(f, v)) { bad++; if (bad < 3) { out.push('FAIL fast ' + f + ' ' + v); } }
      }
    }
    eq('fast == viewer (' + alphabet + ', ' + n + ' values)', bad, 0);
  }
  return out;
}
