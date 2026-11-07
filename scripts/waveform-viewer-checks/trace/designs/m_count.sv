`timescale 1ns/1ps
// Design M: a counter held in reset, under a testbench shaped like a large SoC run's (tb_m.sv).
// It counts on the falling edge: the testbench raises the reset at a rising one (no race). With
// MISSING_TASK its block also calls a task the model wasn't given (models/m.missing.json).
module m_count (
  input  logic       clk,
  input  logic       rst_n,
  output logic [7:0] q
);
  always_ff @(negedge clk or negedge rst_n)
    if (!rst_n) q <= 8'd0;
    else begin
`ifdef MISSING_TASK
      count_event();
`endif
      q <= q + 8'd1;
    end
endmodule
