`timescale 1ns/1ps
module tb_i;
  logic        clk = 0, rst_n = 0, we = 0;
  logic [3:0]  valid = 4'b0000, wstrb = 4'b0000;
  logic [1:0]  pick = 2'd0, widx = 2'd0;
  logic [31:0] wdata = 32'h0;
  logic [3:0]  pop;
  logic [7:0]  lost0;
  logic [31:0] word0;
  int unsigned iters, settle = 0;
  logic [31:0] epoch;
  i_drivers dut (.*);
  always #5 clk = ~clk;
  always @(posedge clk) if (rst_n) settle++;
  initial begin
    if (!$value$plusargs("iters=%d", iters)) iters = 4;
    epoch = iters;
`ifndef __ICARUS__
    if ($test$plusargs("fsdb")) begin $fsdbDumpfile("i.fsdb"); $fsdbDumpvars(0, tb_i); end
`endif
`ifdef FSDB
    $fsdbDumpfile("i.fsdb"); $fsdbDumpvars(0, tb_i, "+all");
`endif
    $dumpfile("i.vcd"); $dumpvars(0, tb_i);
    $dumpvars(0, tb_i.dut.lost[0], tb_i.dut.lost[1], tb_i.dut.lost[2], tb_i.dut.lost[3]);
    $dumpvars(0, tb_i.dut.mem[0], tb_i.dut.mem[1], tb_i.dut.mem[2], tb_i.dut.mem[3]);
    #12 rst_n = 1;
    #10 begin valid = 4'b0110; pick = 2'd1; we = 1; widx = 2'd0; wstrb = 4'b0011; wdata = 32'h44332211; end  // t=22
    #10 begin valid = 4'b1001; pick = 2'd3; wstrb = 4'b1100; wdata = 32'h88776655; end                      // t=32
    #10 begin valid = 4'b0001; pick = 2'd2; we = 0; end                                                      // t=42
    #20 $finish;                                                                                            // t=62
  end
endmodule
