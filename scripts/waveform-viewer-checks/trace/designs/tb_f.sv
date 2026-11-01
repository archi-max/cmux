`timescale 1ns/1ns
module tb_f;
  logic clk = 0, rst_n = 0;
  logic [7:0] a = 0;
  logic [7:0] q;
  f_bus bus (.clk(clk));
  f_mem u_mem (.bus(bus), .rst_n(rst_n));
  f_top dut (.bus(bus), .rst_n(rst_n), .a(a), .q(q));
  always #5 clk = ~clk;
  initial begin
`ifdef FSDB
    $fsdbDumpfile("f.fsdb"); $fsdbDumpvars(0, tb_f, "+all");
`endif
    $dumpfile("f.vcd"); $dumpvars(0, tb_f);
    #22 rst_n = 1;
    #8  a = 1;   // t=30: store[1] once req is up
    #20 a = 3;   // t=50: store[3], never written: x
    #20 a = 2;   // t=70
    #20 $finish; // t=90
  end
endmodule
