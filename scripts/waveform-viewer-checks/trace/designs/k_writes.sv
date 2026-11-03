`timescale 1ns/1ps
// Design K: writes the model can't re-execute but must still see, so that the signal's driver is
// approximate rather than a confident "nothing writes it": a simulator's own task (one slang
// doesn't know) given a variable by name, a task whose body writes a module variable, and a
// function called in an assignment's right side whose body writes one. Also guards: a later if in
// the block that doesn't write the signal isn't why it has its value (ky), and a flop that went x
// at an edge, then forced to x by the testbench: later edges, whose runs write known values,
// didn't make the x in effect (fr).
module k_writes (
  input  logic       clk,
  input  logic       go,
  input  logic [7:0] a,
  input  logic [7:0] xa,
  output logic [7:0] fq
);
  logic [7:0] vq;
`ifdef __ICARUS__
  always @(posedge clk) if (go) $deposit(vq, a);    // the dump's stand-in for the vendor task
`else
  always @(posedge clk) if (go) $cmux_poke(vq, a);
`endif

  logic [7:0] tq;
  task clear_t;
    tq = 8'h00;
  endtask
  always @(posedge clk) if (go) clear_t;

  logic [7:0] fcnt;
  function [7:0] bump(input [7:0] v);
    fcnt = v + 8'd1;
    bump = v;
  endfunction
  always @(posedge clk) fq <= bump(a);

  logic [7:0] ky, kz;
  always @* begin
    ky = a;
    if (go) kz = a;
  end

  logic [7:0] fr;
  always @(posedge clk) fr <= xa;
endmodule
