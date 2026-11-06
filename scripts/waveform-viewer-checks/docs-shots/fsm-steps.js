//// - wait=300
const members = [['IDLE','000'],['FETCH','001'],['DECODE','100'],['EXEC','101'],['DONE','111']];
cmuxWaveform.enums.define({ tables: [{ id: 'ctl_state_t', label: 'ctl_state_t', width: 3, members }],
  signals: { 'tb.dut.u_ctl.state': 'ctl_state_t', 'tb.dut.u_ctl.next_state': 'ctl_state_t' } });
for (const p of [['tb','dut','u_ctl','clk'],['tb','dut','u_ctl','rst'],['tb','dut','u_ctl','go'],['tb','dut','u_ctl','stall'],['tb','dut','u_ctl','state'],['tb','dut','u_ctl','next_state'],['tb','dut','u_ctl','busy']]) {
  await cmuxWaveform.link.addSignal(p);
  await new Promise(r => setTimeout(r, 150));
}
return null;
//// - wait=800
await cmuxWaveform.link.selectSignal(['tb','dut','u_ctl','state']);
cmuxWaveform.link.setMarker(50);
return (cmuxWaveform.viewerContext.webview.displayedSignals || []).map(s => s.name);
//// - wait=600
cmuxWaveform.host.toWebview({ command: 'setViewportRange', startTime: 0, endTime: 260 });
const click = async (name) => { const row = Array.from(document.querySelectorAll('#tree .row.scope')).find(r => r.textContent.trim().startsWith(name)); if (row) { row.dispatchEvent(new MouseEvent('click', {bubbles: true})); row.dispatchEvent(new MouseEvent('dblclick', {bubbles: true})); } await new Promise(r => setTimeout(r, 300)); return !!row; };
return [await click('dut'), await click('u_ctl')];
//// viewer
return Array.from(document.querySelectorAll('#tree .row')).map(r => r.className + ':' + r.textContent.trim()).slice(0, 8).join(' | ');
//// context-menu wait=500
const doc = document.getElementById('viewer').contentDocument;
const label = Array.from(doc.querySelectorAll('.waveform-label[data-vscode-context]')).find((el) => {
  try { const c = JSON.parse(el.getAttribute('data-vscode-context').replace(/%x20/g, ' ')); return c.webviewSection === 'signal' && c.signalName === 'state'; } catch (e) { return false; }
});
if (!label) return 'no row';
const r = label.getBoundingClientRect();
label.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, button: 2, clientX: r.left + 40, clientY: r.top + 5 }));
return Array.from(document.querySelectorAll('.cmux-menu .cmux-menu-item .label')).map((l) => l.textContent).join('|');

//// - wait=300
document.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true}));
document.querySelectorAll('.cmux-menu').forEach(m => m.remove());
return null;
//// fsm-pane wait=900
const model = { signal: 'state', width: 3, engine: 'yosys', controls: ['go', 'stall'], reset: '000', resetSignal: 'rst',
  states: [{ bits: '000', name: 'IDLE' }, { bits: '001', name: 'FETCH' }, { bits: '100', name: 'DECODE' }, { bits: '101', name: 'EXEC' }, { bits: '111', name: 'DONE' }],
  transitions: [{ from: '*', to: '000' }, { from: '111', to: '000' }, { from: '101', to: '001', condition: 'go' },
    { from: '101', to: '111', condition: '!go' }, { from: '100', to: '101', condition: '!stall' }, { from: '001', to: '100' }, { from: '000', to: '001', condition: 'go' }] };
cmuxWaveform.fsm.show({ path: ['tb','dut','u_ctl','state'], model, note: "From Yosys's FSM extraction of the design." });
return null;
