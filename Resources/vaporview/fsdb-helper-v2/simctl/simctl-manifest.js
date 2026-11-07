#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// After a build: record its sources, so simctl `staleness` can tell an agent when an edit needs a rebuild.
//   node simctl-manifest.js <simv> <source files...> [-f <file list, one path per line>]
// Writes <simv>.simctl.json (sha256 of each source, the simulator's mtime).
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { writeManifest } = require('./tb.js');
const a = process.argv.slice(2);
if (a.length < 2) { console.error('usage: simctl-manifest.js <simv> <sources...> [-f list]'); process.exit(2); }
const simv = path.resolve(a[0]);
const files = [];
for (let i = 1; i < a.length; i++) {
  if (a[i] === '-f') { for (const l of fs.readFileSync(a[++i], 'utf8').split('\n')) if (l.trim() && !l.trim().startsWith('#')) files.push(path.resolve(path.dirname(a[i]), l.trim())); }
  else files.push(path.resolve(a[i]));
}
const m = writeManifest(simv, files);
console.log(`${simv}.simctl.json: ${m.files.length} sources`);
