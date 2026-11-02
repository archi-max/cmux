// Two FSMs: an enum two-process one (ctl) and a localparam one-process one (lp).
module ctl (input logic clk, input logic rst, input logic go, input logic stall, output logic busy);
  import fsm_pkg::*;
  state_t state, next_state;
  always_ff @(posedge clk)
    if (rst) state <= IDLE;
    else state <= next_state;
  always_comb begin
    next_state = state;
    unique case (state)
      IDLE: if (go) next_state = FETCH;
      FETCH: next_state = DECODE;
      DECODE: if (!stall) next_state = EXEC;
      EXEC: if (go) next_state = FETCH; else next_state = DONE;
      DONE: next_state = IDLE;
      default: next_state = IDLE;
    endcase
  end
  assign busy = state != IDLE;
endmodule
module lp (input logic clk, input logic rst, input logic a, input logic b, output logic y);
  localparam logic [1:0] S_A = 2'd0, S_B = 2'd1, S_C = 2'd2;
  logic [1:0] st;
  always_ff @(posedge clk)
    if (rst) st <= S_A;
    else case (st)
      S_A: st <= a ? S_B : S_A;
      S_B: st <= b ? S_C : S_A;
      S_C: st <= S_A;
      default: st <= S_A;
    endcase
  assign y = st == S_C;
endmodule
module top (input logic clk, input logic rst, input logic go, input logic stall, input logic a, input logic b,
            output logic busy, output logic y);
  ctl u_ctl (.clk, .rst, .go, .stall, .busy);
  lp u_lp (.clk, .rst, .a, .b, .y);
endmodule
