`timescale 1ns/1ns
module tb_c;
  logic clk = 0, rst_n = 0, go = 0;
  logic [7:0] d = 8'h10;
  logic [7:0] q, qd;
  c_top dut (.*);
  always #5 clk = ~clk;
  initial begin
`ifdef FSDB
    $fsdbDumpfile("c.fsdb"); $fsdbDumpvars(0, tb_c, "+all");
`endif
    $dumpfile("c.vcd"); $dumpvars(0, tb_c);
    #22 rst_n = 1;
    #18 go = 1;          // t=40: id_q <= x + 1 at 45, q x at 55
    #20 d = 8'hxx;       // t=60: data_q x at 65, qd x at 75
    #10 d = 8'h20;       // t=70
    #40 $finish;         // t=110
  end
endmodule
