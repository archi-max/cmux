//// - wait=600
const W = cmuxWaveform;
document.getElementById('netlist').style.width = '200px';
for (const n of ['clk', 'instr', 'instr2', 'half']) { await W.link.addSignal(['top', n]); await new Promise(r => setTimeout(r, 150)); }
const rows = W.viewerContext.webview.displayedSignals;
const id = (n) => rows.find(r => r.name === 'top.' + n).netlistId;
W.host.toWebview({ command: 'setDisplayFormat', netlistId: id('instr2'), numberFormat: 'riscv_numeric' });
W.host.toWebview({ command: 'setDisplayFormat', netlistId: id('half'), numberFormat: 'riscv' });
W.link.setMarker(30);
return rows.map(r => r.name).join(',');
//// riscv-menu wait=700
await cmuxWaveform.link.selectSignal(['top', 'instr']);
await new Promise(r => setTimeout(r, 300));
const doc = document.getElementById('viewer').contentDocument;
const label = Array.from(doc.querySelectorAll('.waveform-label[data-vscode-context]')).find((el) => {
  try { const c = JSON.parse(el.getAttribute('data-vscode-context').replace(/%x20/g, ' ')); return c.webviewSection === 'signal' && c.signalName === 'instr'; } catch (e) { return false; }
});
const r = label.getBoundingClientRect();
label.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, button: 2, clientX: r.left + 40, clientY: r.top + 5 }));
await new Promise(r => setTimeout(r, 200));
const find = (t) => Array.from(document.querySelectorAll('.cmux-menu .cmux-menu-item')).find(i => i.querySelector('.label').textContent === t);
find('Format Values').dispatchEvent(new MouseEvent('mouseenter'));
await new Promise(r => setTimeout(r, 300));
const rv = find('RISC-V'); if (rv) rv.dispatchEvent(new MouseEvent('mouseenter'));
await new Promise(r => setTimeout(r, 300));
const item = find('ABI Names'); if (item) item.dispatchEvent(new MouseEvent('mouseenter'));
return Array.from(document.querySelectorAll('.cmux-menu')).map(m => m.textContent.slice(0, 80)).join(' || ');
