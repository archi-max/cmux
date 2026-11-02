`timescale 1ns/1ps
module tb_h;
  logic clk = 0, rst_n = 0, oe_a = 0, oe_b = 0, c = 0;
  logic [3:0] sel = 4'b0000;
  logic [1:0] widx = 2'd1, pr = 2'b00;
  logic [7:0] din = 8'h10;
  logic [7:0] q, r, cx, rd0, rd1, pv, uv, mv, dly, ms;
  wire  [7:0] bus;
  logic [3:0] sel_o;
  h_mix dut (.*);
  always #5 clk = ~clk;
  initial begin
`ifdef FSDB
    $fsdbDumpfile("h.fsdb"); $fsdbDumpvars(0, tb_h, "+all");
`endif
    $dumpfile("h.vcd"); $dumpvars(0, tb_h);
    $dumpvars(0, tb_h.dut.mem[0], tb_h.dut.mem[1], tb_h.dut.mem[2], tb_h.dut.mem[3]);
    #12 rst_n = 1;
    #10 begin din = 8'h21; sel = 4'b1000; oe_a = 1; pr = 2'b10; end   // t=22
    #10 begin din = 8'h32; sel = 4'b0110; pr = 2'b11; c = 1; end      // t=32
    #10 begin din = 8'h43; sel = 4'b0011; widx = 2'bx1; end           // t=42: x-index write at 45
    #10 begin din = 8'h54; sel = 4'b0100; widx = 2'd0; oe_a = 0; oe_b = 1; c = 1'bx; end  // t=52
    #10 begin sel = 4'bx000; din = 8'h65; pr = 2'b01; end             // t=62
    #10 begin sel = 4'b0z10; din = 8'h76; widx = 2'bxx; oe_b = 0; c = 0; end  // t=72
    #20 $finish;                                                     // t=92
  end
  // Two delay scales fit ms's change at 5 ns (5000 ps): 1000 (#5) and 100 (#50, the same value
  // written again, so no change). The write in effect at 30 ns is the #5 one.
  initial begin
    #5 ms = 8'h99;
    #45 ms = 8'h99;                                                  // t=50
  end
endmodule
