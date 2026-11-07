`timescale 1ns/1ps
// A: a testbench like the oracle's: a reset declared low and raised by the initial block after
// some clock edges, values from plusargs, and a counter incremented in a clocked block.
module tb_l;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic       sel = 1'b1;
  logic [7:0] a = 8'h11, b = 8'h22;
  logic [7:0] y, r;
  logic       c, go;
  logic [31:0] epoch_iters;
  int unsigned iters, settle;

  l_dut dut (.clk(clk), .rst_n(rst_n), .sel(sel), .go(go), .a(a), .b(b), .y(y), .r(r), .c(c));

  initial begin
`ifdef FSDB
    $fsdbDumpfile("l.fsdb"); $fsdbDumpvars(0, tb_l, "+all");
`endif
    $dumpfile("l.vcd"); $dumpvars(0, tb_l);
    if (!$value$plusargs("iters=%d", iters)) iters = 4;
    epoch_iters = iters;
    #2 go = 1'b0;                         // t=2: c = 0 by the override (in reset)
    repeat (3) @(posedge clk);            // edges at 5, 15, 25
    #1 rst_n = 1'b1;                      // t=26 (after the edge: no race with r)
    #9 b = 8'h33;                         // t=35: y = b (the override) = 33
    #10 begin a = 8'h33; sel = 1'b0; end  // t=45: y = a (the default), still 33: no change
    #20 $finish;                          // t=65
  end

  always @(posedge clk)
    if (rst_n) settle++;
endmodule
