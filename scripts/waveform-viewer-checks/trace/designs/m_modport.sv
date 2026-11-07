`timescale 1ns/1ns
// Design M (cmux trace fixtures): an interface's signals read through modport ports passed down
// two levels (tb -> m_mid -> m_leaf), and by a monitor that only reads them (it writes nothing
// into the interface). The producer drives data and valid through its own modport.
interface m_if (input logic clk);
  logic [7:0] data;
  logic       valid;
  logic       ready;
  modport prod (input clk, output data, output valid, input ready);
  modport cons (input clk, input data, input valid, output ready);
  modport mon  (input data, input valid);
endinterface

module m_prod (m_if.prod bus, input logic rst_n);
  always_ff @(posedge bus.clk or negedge rst_n)
    if (!rst_n) begin
      bus.data <= '0;
      bus.valid <= 1'b0;
    end else if (bus.ready) begin
      bus.data <= bus.data + 8'd1;
      bus.valid <= 1'b1;
    end
endmodule

module m_leaf (m_if.cons bus, output logic [7:0] seen);
  assign bus.ready = 1'b1;
  always_ff @(posedge bus.clk)
    if (bus.valid) seen <= bus.data;
endmodule

module m_mid (m_if.cons bus, output logic [7:0] seen);
  m_leaf u_leaf (.bus(bus), .seen(seen));
endmodule

module m_mon (m_if.mon bus, output logic [7:0] last);
  always_comb last = bus.valid ? bus.data : 8'h00;
endmodule
