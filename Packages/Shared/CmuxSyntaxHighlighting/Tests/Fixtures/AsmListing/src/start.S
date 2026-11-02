# cmux asm-listing fixture (written for cmux's tests; public domain / CC0).
# A start routine with a loop, a call, a compressed instruction and a data word.
    .section .text.init, "ax"
    .globl _start
_start:
    li      sp, 0x80004000
    li      a0, 0
    li      t0, 5
.Lloop:
    addi    a0, a0, 3
    addi    t0, t0, -1
    bnez    t0, .Lloop
    call    sum
    la      t1, result
    sw      a0, 0(t1)
    csrw    mtvec, t1
    c.nop
    .insn   r 0x33, 0, 0, a1, a2, a3
1:  j       1b
    .balign 4
    .zero   32
    .globl  after_gap
after_gap:
    ebreak

    .data
    .globl result
result:
    .word   0xdeadbeef
    .ascii  "cmux"
