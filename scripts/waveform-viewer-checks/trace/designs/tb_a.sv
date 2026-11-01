`timescale 1ns/1ns
module tb_a;
  logic clk = 0, rst_n = 0, en = 0;
  logic [7:0] din = 8'h03;
  logic [7:0] dout;
  a_top dut (.*);
  always #5 clk = ~clk;
  initial begin
`ifdef FSDB
    $fsdbDumpfile("a.fsdb"); $fsdbDumpvars(0, tb_a, "+all");
`endif
    $dumpfile("a.vcd"); $dumpvars(0, tb_a);
    #22 rst_n = 1;
    #18 en = 1;          // t=40: acc <= acc + din at 45 (acc is x)
    #60 $finish;         // t=100
  end
endmodule
