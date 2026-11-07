`timescale 1ns/1ns
module tb_m;
  logic clk = 0, rst_n = 0;
  logic [7:0] seen, last;
  m_if bus (.clk(clk));
  m_prod u_prod (.bus(bus), .rst_n(rst_n));
  m_mid u_mid (.bus(bus), .seen(seen));
  m_mon u_mon (.bus(bus), .last(last));
  always #5 clk = ~clk;
  initial begin
    $dumpfile("m.vcd"); $dumpvars(0, tb_m);
    #22 rst_n = 1;
    #40 $finish;
  end
endmodule
