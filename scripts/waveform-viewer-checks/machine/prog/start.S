# Machine-state fixture program (our own): set sp, call main, report through tohost.
  .section .text.start, "ax"
  .globl _start
_start:
  la sp, _stack_top
  call main
  slli a0, a0, 1
  ori a0, a0, 1
  la t0, tohost
  sw a0, 0(t0)
1: j 1b

  .section .tohost, "aw"
  .align 6
  .globl tohost
tohost: .word 0
  .word 0
  .globl fromhost
fromhost: .word 0
  .word 0
