# pipetest.S: tiny bare-metal RV32I program for the pipeline-view fixtures.
# Exercises: counted loops (taken/not-taken backward branch), a load-use pair,
# stores, a not-taken and a taken forward branch (with a squashed shadow
# instruction), a call/return (jal/jalr), a nested loop, and ends in `j .`
# (back-to-back identical PCs). Position independent; the linker sets the base.
# Data lives at _start + 0x800 (DATA_OFF), or at the absolute address DATA_ABS when
# that is defined (-DDATA_ABS=0x80000000 for RSD, whose code region is a ROM).
  .equ DATA_OFF, 0x800
  .text
  .globl _start
_start:
#ifdef DATA_ABS
  li    s0, DATA_ABS        # s0 = data base
#else
  auipc s0, 0
  li    t0, DATA_OFF
  add   s0, s0, t0          # s0 = data base
#endif
  li    t1, 0x11
  sw    t1, 0(s0)           # seed data[0]
  li    a0, 0               # i
  li    a1, 6               # outer trip count
  li    a2, 0               # accumulator
outer:
  lw    t2, 0(s0)           # load
  add   t3, t2, a0          # load-use (dependent on t2)
  sw    t3, 0(s0)           # store
  add   a2, a2, t3
  li    a3, 3               # inner trip count
inner:
  addi  a3, a3, -1
  bnez  a3, inner           # taken 2x, not taken 1x
  addi  a0, a0, 1
  bne   a0, a1, outer       # taken 5x, not taken 1x
  beq   a0, zero, skip      # not taken
  addi  a2, a2, 1
skip:
  beq   zero, zero, over    # taken forward
  addi  a2, a2, 100         # shadow: must never commit
over:
  jal   ra, func            # call
  sw    a2, 4(s0)           # store the result
  lw    t4, 4(s0)           # load it back
  addi  t4, t4, 1           # load-use
  sw    t4, 8(s0)
done:
  j     done                # j . : back-to-back identical PCs
func:
  addi  a2, a2, 7
  ret
