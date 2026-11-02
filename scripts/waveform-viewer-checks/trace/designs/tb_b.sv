`timescale 1ns/1ns
module tb_b;
  logic clk = 0, rst_n = 0, we = 0;
  logic [1:0] waddr = 0, raddr = 0, mode = 0;
  logic [7:0] wdata = 0, rdata;
  b_top dut (.*);
  always #5 clk = ~clk;
  initial begin
`ifdef FSDB
    $fsdbDumpfile("b.fsdb"); $fsdbDumpvars(0, tb_b, "+all");
`endif
    $dumpfile("b.vcd"); $dumpvars(0, tb_b);
    #22 rst_n = 1;
    #8  begin we = 1; waddr = 0; wdata = 8'h11; end   // t=30: mem[0] at 35
    #10 begin waddr = 1; wdata = 8'h22; end           // t=40: mem[1] at 45
    #10 begin we = 0; raddr = 2'bxx; end              // t=50: x index at 55
    #20 raddr = 2'd3;                                 // t=70: unwritten mem[3] at 75
    #20 begin raddr = 2'd1; mode = 2'd3; end          // t=90: default 'x at 95
    #20 mode = 2'bxx;                                 // t=110: x selector at 115
    #20 mode = 2'd1;                                  // t=130: ~mem[1] at 135
    #20 $finish;                                      // t=150
  end
endmodule
