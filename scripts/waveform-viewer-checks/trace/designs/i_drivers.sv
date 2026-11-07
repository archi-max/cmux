`timescale 1ns/1ps
// Design I: writes the driver search must see though they are not re-executed: writes indexed by
// a loop variable (a comb round-robin decode, per-lane counters), byte writes into memory words
// in a loop, and (tb_i) a counter's x++, a $value$plusargs output and an initial block that also
// calls a dump task the elaborator doesn't know.
module i_drivers (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [3:0]  valid,
  input  logic [1:0]  pick,
  input  logic        we,
  input  logic [1:0]  widx,
  input  logic [3:0]  wstrb,
  input  logic [31:0] wdata,
  output logic [3:0]  pop,
  output logic [7:0]  lost0,
  output logic [31:0] word0
);
  logic [7:0]  lost [4];
  logic [31:0] mem [4];

  always_comb
    for (int t = 0; t < 4; t++) pop[t] = valid[t] && pick == 2'(t);

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) for (int c = 0; c < 4; c++) lost[c] <= '0;
    else for (int c = 0; c < 4; c++) if (valid[c] && pick != 2'(c)) lost[c] <= lost[c] + 1'b1;

  always @(posedge clk)
    if (we) for (int b = 0; b < 4; b++) if (wstrb[b]) mem[widx][8*b +: 8] <= wdata[8*b +: 8];

  assign lost0 = lost[0];
  assign word0 = mem[0];
endmodule
