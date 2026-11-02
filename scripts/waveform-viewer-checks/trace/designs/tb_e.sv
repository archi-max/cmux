`timescale 1ns/1ns
module tb_e;
  logic clk = 0, rst_n = 0, en = 0, sel = 0;
  logic [3:0] op = 0;
  logic [7:0] a = 8'h12, b = 8'h34;
  logic [7:0] lat, y, hi_lo, xf, xc, pk, t2;
  logic [3:0] dec;
  logic [0:7] asc;
  e_top dut (.*);
  always #5 clk = ~clk;
  initial begin
`ifdef FSDB
    $fsdbDumpfile("e.fsdb"); $fsdbDumpvars(0, tb_e, "+all");
`endif
    $dumpfile("e.vcd"); $dumpvars(0, tb_e);
    #22 rst_n = 1;
    #8  begin en = 1; op = 4'b0110; end   // t=30: lat follows a; dec = 4
    #10 begin en = 0; a = 8'h56; end      // t=40: lat holds 8'h12
    #10 begin sel = 1'bx; op = 4'b1001; b = 8'h56; end  // t=50: sel x; a == b: merges agree
    #20 b = 8'h78;                        // t=70: sel still x, a != b
    #20 begin sel = 1; op = 4'b0010; end  // t=90
    #20 $finish;                          // t=110
  end
endmodule
