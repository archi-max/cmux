`timescale 1ns/1ps
module tb_j;
  logic       clk = 0, go = 0;
  logic [7:0] a = 8'h00, b = 8'h00;
  logic [7:0] q, y;
  j_temps dut (.*);
  always #5 clk = ~clk;
  initial begin
`ifdef FSDB
    $fsdbDumpfile("j.fsdb"); $fsdbDumpvars(0, tb_j, "+all");
`endif
    $dumpfile("j.vcd"); $dumpvars(0, tb_j);
    #2 begin a = 8'hx1; b = 8'h22; end      // t=2: a's high bits x; go = 0, so q takes b
    #10 begin go = 1; end                    // t=12: q takes a (x), op takes a[1:0] at 15
    #10 begin a = 8'h03; go = 0; end         // t=22
    #20 $finish;                             // t=42
  end
endmodule
