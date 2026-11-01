// Source of fsm.vcd (run.sh enum): iverilog -g2012 -o sim fsm.sv && vvp sim
module top;
  typedef enum logic [2:0] { IDLE, FETCH, DECODE = 3'd4, EXEC, DONE = 3'b111 } state_t;
  logic clk = 0;
  state_t state, other;
  logic [2:0] plain;
  always #5 clk = ~clk;
  initial begin
    $dumpfile("fsm.vcd"); $dumpvars(0, top);
    #10 state = IDLE; other = IDLE; plain = 0;
    #10 state = FETCH; other = DECODE; plain = 1;
    #10 state = state_t'(3'd2); other = EXEC; plain = 2;
    #10 state = DONE; other = DONE; plain = 7;
    #10 $finish;
  end
endmodule
