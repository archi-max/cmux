`timescale 1ns/1ns
module tb_g;
  logic clk = 0, rst_n = 0, en = 0;
  logic [7:0] d = 8'h33;
  logic [7:0] q, y;
  g_top dut (.*);
  always #5 clk = ~clk;
  initial begin
`ifdef FSDB
    $fsdbDumpfile("g.fsdb"); $fsdbDumpvars(0, tb_g, "+all");
`endif
    $dumpfile("g.vcd"); $dumpvars(0, tb_g);
    #12 rst_n = 1;
    #8  begin en = 1; d = 8'h5a; end  // t=20: q = d at 25 (the override)
    #20 en = 0;                       // t=40: q = 8'h0f at 45 (the default)
    #10 begin en = 1; d = 8'hxx; end  // t=50: q = x at 55
    #20 $finish;                      // t=70
  end
endmodule
