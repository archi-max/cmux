`timescale 1ns/1ps
module tb_k;
  logic       clk = 0, go = 0;
  logic [7:0] a = 8'h00, xa = 8'h03;
  logic [7:0] fq;
  k_writes dut (.*);
  always #5 clk = ~clk;
  initial begin
`ifdef FSDB
    $fsdbDumpfile("k.fsdb"); $fsdbDumpvars(0, tb_k, "+all");
`endif
    $dumpfile("k.vcd"); $dumpvars(0, tb_k);
    #2  a = 8'h11;                   // t=2
    #10 begin go = 1; xa = 8'hxx; end  // t=12: vq, tq, fcnt written at 15; fr x at 15
    #10 begin go = 0; a = 8'h22; xa = 8'h05; force dut.fr = 8'bx; end  // t=22: fcnt, fq at 25; fr stays x
    #20 $finish;                     // t=42
  end
endmodule
