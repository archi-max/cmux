`timescale 1ns/1ps
// Design J: an x reaching a flop through a blocking temp that the block sets to 'bx at its end
// (a CPU core's current_pc), and an x made by a default 'bx because no item of a later
// case (1'b1) matched (a CPU core's ALU result for an x instruction), and a flop rewritten with x
// from a different source than the one that first made it x (x to x writes aren't changes).
module j_temps (
  input  logic       clk,
  input  logic [7:0] a,
  input  logic [7:0] b,
  input  logic       go,
  input  logic [1:0] zsel,
  output logic [7:0] q,
  output logic [7:0] y
);
  logic [7:0] tmp;
  logic [1:0] op;          // never reset: x until first written
  always @(posedge clk) begin
    tmp = go ? a : b;
    q <= tmp;
    tmp = 'bx;
  end

  always @(posedge clk) if (go) op <= a[1:0];

  wire is_add = op == 2'd1;
  wire is_xor = op == 2'd2;
  always @* begin
    y = 'bx;
    case (1'b1)
      is_add: y = a + b;
      is_xor: y = a ^ b;
    endcase
  end

  logic [7:0] a2;          // never written (zsel is never 3)
  logic [7:0] zq;
  always @(posedge clk) if (zsel == 2'd3) a2 <= a;
  always @(posedge clk)
    case (zsel)
      2'd0:    zq <= 8'h00;
      2'd1:    zq <= 8'bx;
      default: zq <= a2;
    endcase
endmodule
