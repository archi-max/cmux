`timescale 1ns/1ns
// Design G: a default then an override in one run (two writes to one target; the last one
// that runs is the active driver), nonblocking in a flop and blocking in a comb block.
module g_top (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       en,
  input  logic [7:0] d,
  output logic [7:0] q,
  output logic [7:0] y
);
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) q <= '0;
    else begin
      q <= 8'h0f;
      if (en) q <= d;
    end

  always_comb begin
    y = 8'h00;
    if (en) y = d ^ 8'hff;
  end
endmodule
