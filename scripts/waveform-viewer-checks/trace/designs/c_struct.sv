`timescale 1ns/1ns
// Design C: x through a module hierarchy with a packed-struct port.
// u_src.id_q has no reset (uninitialized flop); d goes x for one cycle (primary input).
package c_pkg;
  typedef struct packed {
    logic       valid;
    logic [3:0] id;
    logic [7:0] data;
  } pkt_t;
endpackage

module c_src import c_pkg::*; (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       go,
  input  logic [7:0] d,
  output pkt_t       out
);
  logic       valid_q;
  logic [3:0] id_q;
  logic [7:0] data_q;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) valid_q <= 1'b0;
    else        valid_q <= go;

  always_ff @(posedge clk)
    if (go) begin
      id_q   <= id_q + 4'd1;
      data_q <= d;
    end

`ifdef __ICARUS__
  // Icarus has no assignment patterns: the same packed value as a concatenation.
  assign out = {valid_q, id_q, data_q};
`else
  assign out = '{valid: valid_q, id: id_q, data: data_q};
`endif
endmodule

module c_sink import c_pkg::*; (
  input  logic       clk,
  input  logic       rst_n,
  input  pkt_t       in,
  output logic [7:0] q,
  output logic [7:0] qd
);
  logic [7:0] mix;
  assign mix = in.data + {4'b0, in.id};

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      q  <= '0;
      qd <= '0;
    end else if (in.valid) begin
      q  <= mix;
      qd <= in.data;
    end
endmodule

module c_mid import c_pkg::*; (
  input  logic       clk,
  input  logic       rst_n,
  input  pkt_t       pin,
  output logic [7:0] q,
  output logic [7:0] qd
);
  c_sink u_sink (.clk, .rst_n, .in(pin), .q, .qd);
endmodule

module c_top import c_pkg::*; (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       go,
  input  logic [7:0] d,
  output logic [7:0] q,
  output logic [7:0] qd
);
  pkt_t p;
  c_src u_src (.clk, .rst_n, .go, .d, .out(p));
  c_mid u_mid (.clk, .rst_n, .pin(p), .q, .qd);
endmodule
