`timescale 1ns/1ps
// Design L: two classes of a driver labelled exact but wrong, found by a Verdi oracle run.
// B: a plain always @* with a default and a conditional override, whose value stays the same
// while the condition changes (the override made it; the default now gives the same value), and
// one whose override holds in reset (picorv32's clear_prefetched_high_word: the reset made it).
module l_dut (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       sel,
  input  logic       go,
  input  logic [7:0] a,
  input  logic [7:0] b,
  output logic [7:0] y,
  output logic [7:0] r,
  output logic       c
);
  always @* begin
    y = a;
    if (sel) y = b;
  end

  always @* begin
    c = 1'b0;
    if (go || !rst_n) c = 1'b0;
  end

  always_ff @(posedge clk)
    if (!rst_n) r <= '0;
    else r <= r + 8'd1;
endmodule
