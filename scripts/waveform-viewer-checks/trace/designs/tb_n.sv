`timescale 1ns/1ns
module tb_n;
  logic clk = 0, rst_n = 0;
  logic [7:0] seen, last;
  n_if bus (.clk(clk));
  n_prod u_prod (.bus(bus), .rst_n(rst_n));
  n_mid u_mid (.bus(bus), .seen(seen));
  n_mon u_mon (.bus(bus), .last(last));
  logic top_valid;
  assign top_valid = bus.valid;  // the interface's own parent reads it directly
  always #5 clk = ~clk;
  initial begin
    $dumpfile("n.vcd"); $dumpvars(0, tb_n);
    #22 rst_n = 1;
    #40 $finish;
  end
endmodule
