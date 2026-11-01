`timescale 1ns/1ns
// Design F (cmux trace fixtures): signals of an interface instance that other instances write
// through modport ports, the way typical testbenches' memory models answer the CPU. The
// memory model drives rdata (comb) and resp (a flop); the dut drives addr (an assign) and req
// (a flop), and reads rdata and resp back through its own port. store[3] is never written.
interface f_bus (input logic clk);
  logic [7:0] addr;
  logic [7:0] rdata;
  logic       req;
  logic       resp;
  modport ctrl (input clk, output addr, output req, input rdata, input resp);
  modport mem  (input clk, input addr, input req, output rdata, output resp);
endinterface

module f_mem (f_bus.mem bus, input logic rst_n);
  logic [7:0] store [4];
  initial begin
    store[0] = 8'h10;
    store[1] = 8'h21;
    store[2] = 8'h32;
  end
  always_comb begin
    if (bus.req) bus.rdata = store[bus.addr[1:0]];
    else bus.rdata = 8'h00;
  end
  always_ff @(posedge bus.clk or negedge rst_n)
    if (!rst_n) bus.resp <= 1'b0;
    else bus.resp <= bus.req;
endmodule

module f_top (f_bus.ctrl bus, input logic rst_n, input logic [7:0] a, output logic [7:0] q);
  assign bus.addr = a;
  always_ff @(posedge bus.clk or negedge rst_n)
    if (!rst_n) begin
      bus.req <= 1'b0;
      q <= '0;
    end else begin
      bus.req <= 1'b1;
      if (bus.resp) q <= bus.rdata;
    end
endmodule
