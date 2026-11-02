`timescale 1ns/1ns
// Design B: x from an x select index (raddr_q from a primary input), a read of an
// unwritten memory entry, an X-assignment in a case default, and an x case selector.
module b_top (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       we,
  input  logic [1:0] waddr,
  input  logic [7:0] wdata,
  input  logic [1:0] raddr,
  input  logic [1:0] mode,
  output logic [7:0] rdata
);
  logic [7:0] mem [4];
  logic [1:0] raddr_q;
  logic [1:0] mode_q;

  always_ff @(posedge clk)
    if (we) mem[waddr] <= wdata;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      raddr_q <= '0;
      mode_q  <= '0;
    end else begin
      raddr_q <= raddr;
      mode_q  <= mode;
    end

  always_comb begin
    case (mode_q)
      2'd0:    rdata = mem[raddr_q];
      2'd1:    rdata = ~mem[raddr_q];
      2'd2:    rdata = 8'h00;
      default: rdata = 'x;
    endcase
  end
endmodule
