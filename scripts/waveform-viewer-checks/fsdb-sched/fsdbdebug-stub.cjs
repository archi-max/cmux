#!/usr/bin/env node
// A stand-in for Verdi's fsdbdebug: `-top_n_var 0 <file>` lists the stored (primary) vars on
// stderr after a banner, one per line as `<idcode> <path> <count>(<pct>%)`. Primaries are
// STUB_PRIMARY (ids), counts from STUB_COUNTS (default 1000). STUB_DEBUG_LOG gets a line per run;
// STUB_DEBUG_PIDFILE gets its pid.
'use strict';
const fs = require('node:fs');
if (process.env.STUB_DEBUG_PIDFILE) { fs.writeFileSync(process.env.STUB_DEBUG_PIDFILE, String(process.pid)); }
if (process.env.STUB_DEBUG_LOG) { fs.appendFileSync(process.env.STUB_DEBUG_LOG, process.argv.slice(2).join(' ') + '\n'); }
if (process.argv[2] !== '-top_n_var') { process.exit(2); }
const counts = JSON.parse(process.env.STUB_COUNTS || '{}');
const ms = Number(process.env.STUB_DEBUG_MS || 0);
setTimeout(() => {
  process.stderr.write('logDir = /tmp/x\n\n                 fsdbdebug (R)\n   Copyright (c) 1999 - 2024\n\nSignal_idcode  Signal_hierarchy_name   VC_count(this_sig_vc_percentag)\n');
  for (const id of JSON.parse(process.env.STUB_PRIMARY || '[]')) { process.stderr.write(`${id}              /tb/s${id}   ${counts[id] || 1000}(0.01%)\n`); }
  process.exit(0);
}, ms);
