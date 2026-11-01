`timescale 1ns/1ps
// Design H: z and tri-state (a two-driver bus, a z through ports, implicit .* connections),
// nonblocking read-after-write, casex wildcards, a write through an x index, priority and
// unique cases with several matching items, an if on x under X-propagation (merge), and an
// RTL delay. The testbench's timescale precision (1ps) puts the dump in ps, the delays in ns.
module h_leaf (
  input  logic [3:0] sel,
  output logic [3:0] sel_o
);
  assign sel_o = sel;
endmodule

module h_mix (
  input  logic       clk,
  input  logic       rst_n,
  input  logic [3:0] sel,
  input  logic [1:0] widx,
  input  logic [7:0] din,
  input  logic       oe_a,
  input  logic       oe_b,
  input  logic [1:0] pr,
  input  logic       c,
  output logic [7:0] q,
  output logic [7:0] r,
  output logic [7:0] cx,
  output logic [7:0] rd0,
  output logic [7:0] rd1,
  output logic [7:0] pv,
  output logic [7:0] uv,
  output logic [7:0] mv,
  output logic [7:0] dly,
  output wire  [7:0] bus,
  output logic [3:0] sel_o
);
  logic [7:0] mem [0:3];
  logic [7:0] tmp;
  // Nonblocking read-after-write: r takes the old q.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin q <= 8'h00; r <= 8'h00; end
    else begin q <= din; r <= q + 8'h01; end
  end
  // casex: x and z bits in the selector and the items match anything.
  always @* begin
    casex (sel)
      4'b1xxx: cx = 8'ha1;
      4'b01x0: cx = 8'hb2;
      4'b001?: cx = 8'hc3;
      default: cx = 8'hd4;
    endcase
  end
  // A write through an x index writes no element.
  always_ff @(posedge clk) begin
    tmp = din ^ 8'h0f;
    if (!rst_n) begin mem[0] <= 8'h00; mem[1] <= 8'h00; mem[2] <= 8'h00; mem[3] <= 8'h00; end
    else mem[widx] <= tmp;
  end
  assign rd0 = mem[0];
  assign rd1 = mem[1];
  // A tri-state bus with two drivers: the second is the active one when oe_b is high.
  assign bus = oe_a ? din : 8'bz;
  assign bus = oe_b ? ~din : 8'bz;
  // priority: several items may match (no violation); unique: they may not.
  always_comb begin
    priority casez (pr)
      2'b1?:   pv = 8'h01;
      2'b?1:   pv = 8'h02;
      default: pv = 8'h03;
    endcase
  end
  always_comb begin
    unique casez (pr)
      2'b1?:   uv = 8'h11;
      2'b?1:   uv = 8'h12;
      default: uv = 8'h13;
    endcase
  end
  // An if on x: X-propagation merges both branches' writes.
  always_ff @(posedge clk) begin
    if (c) mv <= din;
    else   mv <= 8'h5a;
  end
  // An RTL delay: the step is approximate.
  assign #1 dly = din;
  // Implicit connections: sel (which carries a z) passes through the ports.
  h_leaf u_leaf (.*);
endmodule
