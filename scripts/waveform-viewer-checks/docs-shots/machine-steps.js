//// - wait=300
const W = cmuxWaveform, M = W.machine, D = W.debugger;
document.getElementById('netlist').style.width = '330px';
for (const n of ['rvfi_valid', 'rvfi_pc_rdata', 'rvfi_insn', 'rvfi_rd_addr', 'rvfi_rd_wdata', 'rvfi_mem_addr']) {
  await W.link.addSignal(['tb', 'dut', n]); await new Promise(r => setTimeout(r, 120));
}
await W.link.addSignal(['tb', 'clk']);
const s = await M.build();
return JSON.stringify([s.source, s.count, s.error]);
//// - wait=800
const W = cmuxWaveform, M = W.machine, D = W.debugger;
const rows = W.viewerContext.webview.displayedSignals;
const byName = (n) => rows.find(r => r.name.endsWith(n));
W.host.toWebview({ command: 'setDisplayFormat', netlistId: byName('rvfi_insn').netlistId, numberFormat: 'riscv' });
for (const n of ['rvfi_pc_rdata', 'rvfi_rd_wdata', 'rvfi_mem_addr']) W.host.toWebview({ command: 'setDisplayFormat', netlistId: byName(n).netlistId, numberFormat: 'hexadecimal' });
await D.jump({ to: 'first' });
await D.step({ by: 420 });
W.host.toWebview({ command: 'setViewportRange', startTime: 4065000, endTime: 4345000 });
await D.addBreakpoint({ path: ['tb', 'dut', 'rvfi_trap'], kind: 'change' });
await D.addBreakpoint({ path: ['tb', 'dut', 'rvfi_rd_addr'], kind: 'equals', value: "5'd10" });
await D.addBreakpoint({ path: ['tb', 'dut', 'rvfi_insn'], kind: 'text', format: 'riscv', pattern: '^mulhu' });
await D.addBreakpoint({ kind: 'pc', pcs: ['0x800000ba'] });
await D.addBreakpoint({ kind: 'write', loc: 'a0' });
D.addWatch({ expr: '$a0 + $a1' });
D.addWatch({ expr: 'tb.dut.rvfi_rd_wdata[7:0]' });
await M.show({ tab: 'registers' });
return JSON.stringify(D.breakpoints().map(b => b.label || b.kind));
//// debugger-machine wait=1500
return null;
//// machine-history wait=900
await cmuxWaveform.machine.setTab({ tab: 'history' });
return null;
//// machine-memory wait=900
await cmuxWaveform.machine.setTab({ tab: 'memory' });
return null;
//// machine-sequences wait=1500
const r = await cmuxWaveform.machine.setSequence({ query: '{lw} as L ##1 rs1 == L.rd || rs2 == L.rd' });
return JSON.stringify(r && (r.matches ? r.matches.length : r));
