// tb_vex.sv: minimal Verilator testbench for VexRiscv (FormalSimple demo config, RVFI port).
// 64 KiB RAM at 0x0: iBus/dBus cmd always ready, responses one cycle after the command.
// Reset vector 0. Clock period 10 ns (timescale 1ns/1ps); reset (active high, sync) for the
// first 5 posedges. +prog=<hex> (word 0 at address 0), +cycles=<n> posedges after reset.
`timescale 1ns/1ps
module tb;
  logic clk = 1'b0, reset = 1'b1;
  always #5 clk = ~clk;
  logic [31:0] mem [0:16383];

  logic        iBus_cmd_valid; logic [31:0] iBus_cmd_payload_pc;
  logic        iBus_rsp_valid = 1'b0; logic [31:0] iBus_rsp_payload_inst;
  logic        dBus_cmd_valid, dBus_cmd_payload_wr; logic [3:0] dBus_cmd_payload_mask;
  logic [31:0] dBus_cmd_payload_address, dBus_cmd_payload_data; logic [1:0] dBus_cmd_payload_size;
  logic        dBus_rsp_ready = 1'b0; logic [31:0] dBus_rsp_data;

  always_ff @(posedge clk) begin
    iBus_rsp_valid <= iBus_cmd_valid && !reset;
    iBus_rsp_payload_inst <= mem[iBus_cmd_payload_pc[15:2]];
    dBus_rsp_ready <= dBus_cmd_valid && !dBus_cmd_payload_wr && !reset;
    dBus_rsp_data <= mem[dBus_cmd_payload_address[15:2]];
    if (dBus_cmd_valid && dBus_cmd_payload_wr)
      for (int b = 0; b < 4; b++)
        if (dBus_cmd_payload_mask[b]) mem[dBus_cmd_payload_address[15:2]][8*b +: 8] <= dBus_cmd_payload_data[8*b +: 8];
  end

  VexRiscv cpu (
    .rvfi_valid(), .rvfi_order(), .rvfi_insn(), .rvfi_trap(), .rvfi_halt(), .rvfi_intr(), .rvfi_mode(),
    .rvfi_ixl(), .rvfi_rs1_addr(), .rvfi_rs1_rdata(), .rvfi_rs2_addr(), .rvfi_rs2_rdata(), .rvfi_rd_addr(),
    .rvfi_rd_wdata(), .rvfi_pc_rdata(), .rvfi_pc_wdata(), .rvfi_mem_addr(), .rvfi_mem_rmask(),
    .rvfi_mem_wmask(), .rvfi_mem_rdata(), .rvfi_mem_wdata(),
    .iBus_cmd_valid(iBus_cmd_valid), .iBus_cmd_ready(1'b1), .iBus_cmd_payload_pc(iBus_cmd_payload_pc),
    .iBus_rsp_valid(iBus_rsp_valid), .iBus_rsp_payload_error(1'b0), .iBus_rsp_payload_inst(iBus_rsp_payload_inst),
    .dBus_cmd_valid(dBus_cmd_valid), .dBus_cmd_ready(1'b1), .dBus_cmd_payload_wr(dBus_cmd_payload_wr),
    .dBus_cmd_payload_mask(dBus_cmd_payload_mask), .dBus_cmd_payload_address(dBus_cmd_payload_address),
    .dBus_cmd_payload_data(dBus_cmd_payload_data), .dBus_cmd_payload_size(dBus_cmd_payload_size),
    .dBus_rsp_ready(dBus_rsp_ready), .dBus_rsp_error(1'b0), .dBus_rsp_data(dBus_rsp_data),
    .clk(clk), .reset(reset));

  string prog; int cycles;
  initial begin
    for (int i = 0; i < 16384; i++) mem[i] = 32'h0000006f;  // j . everywhere else
    if (!$value$plusargs("prog=%s", prog)) prog = "vex.hex";
    if (!$value$plusargs("cycles=%d", cycles)) cycles = 1200;
    $readmemh(prog, mem);
    $dumpfile("vexriscv_full.vcd");
    $dumpvars(0, tb);
    repeat (5) @(posedge clk);
    #1 reset = 1'b0;
    repeat (cycles) @(posedge clk);
    $finish;
  end
endmodule
