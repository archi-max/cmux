`timescale 1ns/1ps
// Design J: an x reaching a flop through a blocking temp that the block sets to 'bx at its end
// (a CPU core's current_pc), and an x made by a default 'bx because no item of a later
// case (1'b1) matched (a CPU core's ALU result for an x instruction), and a flop rewritten with x
// from a different source than the one that first made it x (x to x writes aren't changes), and a
// word whose x bits came from a whole write that a later part-select write (of known bits) overlaid.
module automatic j_temps (
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

  logic [15:0] p0, p1;
  always @(posedge clk) p0 <= {a, b};
  always @(posedge clk) begin
    p1 <= p0;
    p1[3:0] <= 4'h0;
  end

  // An x part-select write a later narrower write of known bits overlays (the x write chosen,
  // compared over its own bits), also inside a wider word; a local declared with an initializer
  // that a flop reads (its fan-in goes on through the initializer); a net declaration assignment
  // with a width extension (no source text for the initializer); and an unreset counter (x from
  // the start, written with x every clock: uninitialised, not a loop).
  logic [7:0] st;
  logic [15:0] w16;
  always @* begin
    st[7:2] = 6'bx;
    st[3:0] = a[3:0];
  end
  always @* begin
    w16 = '0;
    w16[7:0] = 'bx;
    w16[3:0] = a[3:0];
  end
  logic [7:0] dq;
  always @(posedge clk) begin
    logic [7:0] t2 = b + 8'd1;
    dq <= t2;
  end
  wire [7:0] wz = go;
  logic [3:0] cnt;
  always @(posedge clk) cnt <= cnt + 4'd1;
endmodule
