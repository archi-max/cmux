`timescale 1ns/1ns
// Design A: x from an uninitialized flop (acc, no reset) through combinational logic,
// an always_comb with an undumped blocking temp, into a reset flop.
module a_top (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       en,
  input  logic [7:0] din,
  output logic [7:0] dout
);
  logic [7:0] acc;
  logic       valid_q;
  logic [7:0] sum;
  logic [7:0] stage;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) valid_q <= 1'b0;
    else        valid_q <= en;

  always_ff @(posedge clk)
    if (en) acc <= acc + din;

  assign sum = acc ^ {8{valid_q}};

  always_comb begin
    logic [7:0] tmp;
    tmp = sum + 8'd1;
    if (valid_q) stage = tmp;
    else         stage = din;
  end

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) dout <= '0;
    else        dout <= stage;
endmodule
