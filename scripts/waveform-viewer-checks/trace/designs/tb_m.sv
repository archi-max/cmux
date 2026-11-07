`timescale 1ns/1ps
// M: a testbench shaped like a large SoC run's. Its initial block reads plusargs, starts an FSDB
// dump with the simulator's own tasks (which slang doesn't know), then raises the reset after 20
// clock edges. With MISSING_TASK it also calls a task from a file the model wasn't given, so slang
// can't bind the block at all (models/m.missing.json).
module tb_m;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  int unsigned iters;
  logic [31:0] epoch_iters;
  logic [7:0]  q;

  m_count dut (.clk(clk), .rst_n(rst_n), .q(q));

  initial begin
    if (!$value$plusargs("iters=%d", iters)) iters = 4;
    epoch_iters = iters;
`ifndef __ICARUS__
    $fsdbDumpfile("m.fsdb");
    $fsdbDumpvars(0, tb_m, "+all");
`endif
`ifdef MISSING_TASK
    load_memories();
`endif
    $dumpfile("m.vcd"); $dumpvars(0, tb_m);
    repeat (20) @(posedge clk);         // edges at 5, 15, ..., 195
    rst_n = 1'b1;                       // t=195
    repeat (5) @(posedge clk);
    $finish;                            // t=245
  end
endmodule
