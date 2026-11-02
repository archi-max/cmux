module tb;
  logic clk = 0, rst = 1, go = 0, stall = 0, a = 0, b = 0, busy, y;
  top dut (.*);
  always #5 clk = ~clk;
  int unsigned seed = 7;
  initial begin
`ifdef FSDB
    $fsdbDumpfile("fsm.fsdb"); $fsdbDumpvars(0, tb);
`else
    $dumpfile("fsm.vcd"); $dumpvars(0, tb);
`endif
    #12 rst = 0;
    repeat (60) begin
      @(negedge clk);
      go = ($random(seed) % 3) == 0; stall = ($random(seed) % 2) == 0;
      a = $random(seed) % 2; b = $random(seed) % 2;
    end
    $finish;
  end
endmodule
