#!/usr/bin/env python3
"""mkconfig.py <slang types.json> <rsd.vcd> > pipeline.json

Writes the RSD pipeline config. RSD dumps every per-stage debug register as a flat packed
struct (core.debugIF.<x>Reg[i]); their field layouts come from slang (layouts.py) and the
$var widths in the VCD, and are written out per element under "layouts" (keys are the
dumped names relative to the scope, e.g. "debugIF.ifReg[0]").

Stage names follow RSD's own Kanata log (KanataGenerator.py: Np F Pd Dc Rn Ds Sc Is Rr X Ma
Mt Rw Wc Cm), so a Konata comparison can match them; back-end stages exist once per unit
(int x2, complex x1, mem x2, fp x1), named "<Kanata stage>:<unit>".
Log offset: vcdCycle = kanataCycle + 2 for stage cells (measured by rsd_commits.py).
Semantics per stage mirror RSD's own dumper (Processor/Src/SysDeps/Verilator/Dumper.h).
"""
import json, os, sys
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, '..'))
import vcdtool as V
sys.path.insert(0, here)
import layouts as LY

types_json, vcdp = sys.argv[1:3]
SCOPE = 'TOP.Main_Zynq_Wrapper.main.core'
_, vars_, _ = V.parse_header(open(vcdp))
width = {p[len(SCOPE) + 1:]: w for p, c, w, *_ in vars_ if p.startswith(SCOPE + '.')}

REG_TYPES = {  # dumped array (relative to scope) -> (struct type, element count)
    'debugIF.npReg': ('NextPCStageDebugRegister', 2), 'debugIF.ifReg': ('FetchStageDebugRegister', 2),
    'debugIF.pdReg': ('PreDecodeStageDebugRegister', 2), 'debugIF.idReg': ('DecodeStageDebugRegister', 2),
    'debugIF.rnReg': ('RenameStageDebugRegister', 2), 'debugIF.dsReg': ('DispatchStageDebugRegister', 2),
    'debugIF.scheduler': ('SchedulerDebugRegister', 16), 'debugIF.issueQueue': ('IssueQueueDebugRegister', 16),
    'debugIF.intIsReg': ('IntegerIssueStageDebugRegister', 2), 'debugIF.intRrReg': ('IntegerRegisterReadStageDebugRegister', 2),
    'debugIF.intExReg': ('IntegerExecutionStageDebugRegister', 2), 'debugIF.intRwReg': ('IntegerRegisterWriteStageDebugRegister', 2),
    'debugIF.complexIsReg': ('ComplexIntegerIssueStageDebugRegister', 1),
    'debugIF.complexRrReg': ('ComplexIntegerRegisterReadStageDebugRegister', 1),
    'debugIF.complexExReg': ('ComplexIntegerExecutionStageDebugRegister', 1),
    'debugIF.complexRwReg': ('ComplexIntegerRegisterWriteStageDebugRegister', 1),
    'debugIF.memIsReg': ('MemoryIssueStageDebugRegister', 2), 'debugIF.memRrReg': ('MemoryRegisterReadStageDebugRegister', 2),
    'debugIF.memExReg': ('MemoryExecutionStageDebugRegister', 2), 'debugIF.mtReg': ('MemoryTagAccessStageDebugRegister', 2),
    'debugIF.maReg': ('MemoryAccessStageDebugRegister', 2), 'debugIF.memRwReg': ('MemoryRegisterWriteStageDebugRegister', 2),
    'debugIF.fpIsReg': ('FPIssueStageDebugRegister', 1), 'debugIF.fpRrReg': ('FPRegisterReadStageDebugRegister', 1),
    'debugIF.fpExReg': ('FPExecutionStageDebugRegister', 1), 'debugIF.fpRwReg': ('FPRegisterWriteStageDebugRegister', 1),
    'debugIF.cmReg': ('CommitStageDebugRegister', 2), 'cmStage.alReadData': ('ActiveListEntry', 2),
}
SINGLE = {k: 'PipelineControll' for k in ('debugIF.npStagePipeCtrl', 'debugIF.ifStagePipeCtrl', 'debugIF.pdStagePipeCtrl',
          'debugIF.idStagePipeCtrl', 'debugIF.rnStagePipeCtrl', 'debugIF.dsStagePipeCtrl', 'debugIF.backEndPipeCtrl',
          'debugIF.cmStagePipeCtrl')}
args, keys = [], []
for base, (t, n) in REG_TYPES.items():
    for i in range(n):
        keys.append(('%s[%d]' % (base, i), t))
for k, t in SINGLE.items():
    keys.append((k, t))
LY.load(types_json)
layouts = {}
cache = {}
for k, t in keys:
    w = width[k]
    if (t, w) not in cache:
        cache[(t, w)] = LY.layout(t, w)
    layouts[k] = cache[(t, w)]

def fe(name, reg, ctrl, flush_extra=None, stall_extra=None, tag='opId.sid', extra=None):
    st = {'name': name, 'slots': 2, 'valid': 'debugIF.%s[$i].valid' % reg,
          'tag': 'debugIF.%s[$i].%s' % (reg, tag),
          'stall': 'debugIF.%s.stall' % ctrl + (' && ' + stall_extra if stall_extra else ''),
          'flush': 'debugIF.%s.clear' % ctrl + (' || ' + flush_extra if flush_extra else '')}
    st.update(extra or {})
    return st

stages = [
    fe('Np', 'npReg', 'npStagePipeCtrl', tag='sid', extra={'entry': True}),
    fe('F', 'ifReg', 'ifStagePipeCtrl', tag='sid', flush_extra='debugIF.ifReg[$i].flush',
       stall_extra='!debugIF.ifReg[$i].flush'),
    fe('Pd', 'pdReg', 'pdStagePipeCtrl', tag='sid'),
    fe('Dc', 'idReg', 'idStagePipeCtrl', flush_extra='debugIF.idReg[$i].flushed',
       stall_extra='!debugIF.stallByDecodeStage',
       extra={'pc': 'debugIF.idReg[$i].pc', 'inst': 'debugIF.idReg[$i].insn'}),
    fe('Rn', 'rnReg', 'rnStagePipeCtrl'),
    fe('Ds', 'dsReg', 'dsStagePipeCtrl'),
    {'name': 'Sc', 'kind': 'pool', 'entries': 16, 'valid': 'debugIF.scheduler[$i].valid',
     'tag': 'debugIF.issueQueue[$i].opId.sid', 'stall': 'debugIF.backEndPipeCtrl.stall',
     'flush': 'debugIF.issueQueue[$i].flush'},
]
units = [('int', 'int', 2), ('cx', 'complex', 1), ('mem', 'mem', 2), ('fp', 'fp', 1)]
for kst, regs in [('Is', 'Is'), ('Rr', 'Rr'), ('X', 'Ex')]:
    for u, pfx, n in units:
        # complexExReg and fpExReg hold COMPLEX_/FP_EXEC_STAGE_DEPTH sub-stages (valid/flush vectors, opId array);
        # element 0 (LSBs) is used here.
        cxex = (u in ('cx', 'fp') and regs == 'Ex')
        stages.append({'name': '%s:%s' % (kst, u), 'kind': 'event', 'slots': n,
                       'fire': 'debugIF.%s%sReg[$i].valid' % (pfx, regs) + ('[0]' if cxex else ''),
                       'tag': 'debugIF.%s%sReg[$i].opId' % (pfx, regs) + ('[11:2]' if cxex else '.sid'),
                       'stall': 'debugIF.backEndPipeCtrl.stall',
                       'flush': 'debugIF.%s%sReg[$i].flush' % (pfx, regs) + ('[0]' if cxex else '')})
for kst, reg in [('Mt', 'mtReg'), ('Ma', 'maReg')]:
    stages.append({'name': '%s:mem' % kst, 'kind': 'event', 'slots': 2, 'fire': 'debugIF.%s[$i].valid' % reg,
                   'tag': 'debugIF.%s[$i].opId.sid' % reg, 'stall': 'debugIF.backEndPipeCtrl.stall',
                   'flush': 'debugIF.%s[$i].flush' % reg})
for u, pfx, n in units:
    stages.append({'name': 'Rw:%s' % u, 'kind': 'event', 'slots': n, 'fire': 'debugIF.%sRwReg[$i].valid' % pfx,
                   'tag': 'debugIF.%sRwReg[$i].opId.sid' % pfx, 'stall': 'debugIF.backEndPipeCtrl.stall',
                   'flush': 'debugIF.%sRwReg[$i].flush' % pfx})
cfg = {'version': 1, 'pipelines': [{
    'name': 'rsd', 'scope': SCOPE, 'clock': 'TOP.clk_p', 'edge': 'posedge',
    'reset': 'TOP.posResetOut', 'resetActive': 1, 'sample': 'beforeEdge', 'isa': 'riscv',
    'stages': stages,
    'commit': {'nret': 2, 'valid': 'cmStage.commit[$i]', 'tag': 'cmStage.alReadData[$i].opId.sid',
               'pc': 'cmStage.alReadData[$i].pc'},
    'layouts': layouts,
    'logs': [{'path': 'kanata.log', 'format': 'kanata', 'offset': 2}],
}]}
json.dump(cfg, sys.stdout, indent=1)
sys.stdout.write('\n')
