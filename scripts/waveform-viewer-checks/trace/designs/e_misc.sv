`timescale 1ns/1ns
// Design E (cmux trace fixtures): constructs beyond the prototype's A-C. A latch, casez, a
// concatenation lvalue, part-select drivers of one net, an if on an x condition in a flop and in
// comb logic (X-propagation changes these), a generate array, a 2-D packed array select, an
// ascending range, a blocking temp read after its write, and an unpacked memory with a reset loop
// replaced by explicit writes.
module e_top (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       en,
  input  logic       sel,
  input  logic [3:0] op,
  input  logic [7:0] a,
  input  logic [7:0] b,
  output logic [7:0] lat,
  output logic [7:0] y,
  output logic [7:0] hi_lo,
  output logic [3:0] dec,
  output logic [7:0] xf,
  output logic [7:0] xc,
  output logic [7:0] pk,
  output logic [0:7] asc,
  output logic [7:0] t2
);
  // A latch: holds while en is low.
  always_latch
    if (en) lat = a;

  // casez with don't-cares.
  always_comb begin
    casez (op)
      4'b1???: dec = 4'd8;
      4'b01??: dec = 4'd4;
      4'b001?: dec = 4'd2;
      default: dec = 4'd0;
    endcase
  end

  // A concatenation lvalue (carry and sum).
  logic       carry;
  logic [7:0] sum;
  assign {carry, sum} = a + b;

  // Two drivers of one net, each its own bits.
  assign hi_lo[7:4] = a[3:0];
  assign hi_lo[3:0] = b[7:4];

  // An if on sel (x in the testbench for a while): in a flop and in comb logic.
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n)    xf <= 8'h00;
    else if (sel)  xf <= a;
    else           xf <= b;

  always_comb
    if (sel) xc = a;
    else     xc = b;

  // A generate array of registers.
  logic [7:0] lane_q [2];
  for (genvar g = 0; g < 2; g++) begin : lane
    logic [7:0] r;
    always_ff @(posedge clk or negedge rst_n)
      if (!rst_n) r <= 8'(g);
      else        r <= r + a;
  end
  assign y = lane[0].r ^ lane[1].r;

  // A 2-D packed array and an element select by a variable index.
  logic [3:0][7:0] words;
  assign words = {a, b, sum, 8'h5a};
  assign pk = words[op[1:0]];

  // An ascending range.
  assign asc = {a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]};

  // A blocking temp read after its write in the same flop.
  logic [7:0] tmp2;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      tmp2 = 8'h00;
      t2  <= 8'h00;
    end else begin
      tmp2 = a ^ b;
      t2  <= tmp2 + 8'd1;
    end
endmodule
