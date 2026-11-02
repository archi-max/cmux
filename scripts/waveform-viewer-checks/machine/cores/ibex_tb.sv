// Machine-state fixture wrapper for Ibex (our own). 64 KiB at 0x80000000 from prog.hex, .bss zero;
// instruction and data ports grant at once and answer the next cycle, with fixed-seed wait states
// on data; a store to `tohost` ends the run. Built with RVFI (Verilator --binary); only clock,
// reset and the standard rvfi_* outputs are dumped. CHERIoT is off (cheriot_enable_i = Off).
`timescale 1ns/1ps
module tb;
  import ibex_pkg::*;
  logic clk_i = 0, rst_ni = 0;
  always #5 clk_i = !clk_i;
  logic [31:0] mem [0:16383];
  logic instr_req, instr_gnt, instr_rvalid = 0; logic [31:0] instr_addr, instr_rdata;
  logic data_req, data_gnt, data_rvalid = 0, data_we; logic [3:0] data_be; logic [31:0] data_addr, data_wdata, data_rdata;
  logic [7:0] lfsr = 8'h96;
  assign instr_gnt = instr_req;
  assign data_gnt = data_req && !lfsr[2];
  int cycles = 0;
  initial begin
    for (int i = 0; i < 16384; i++) mem[i] = 0;
    $readmemh("prog.hex", mem);
    $dumpfile("ibex.vcd");
    $dumpvars(1, tb.clk_i, tb.rst_ni);
`include "ibex_dumps.svh"
    repeat (3) @(posedge clk_i);
    rst_ni <= 1;
  end
  always @(posedge clk_i) begin
    cycles <= cycles + 1;
    lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
    instr_rvalid <= instr_req && instr_gnt;
    if (instr_req && instr_gnt) instr_rdata <= mem[instr_addr[15:2]];
    data_rvalid <= data_req && data_gnt;
    if (data_req && data_gnt) begin
      data_rdata <= mem[data_addr[15:2]];
      if (data_we) begin
        for (int i = 0; i < 4; i++) if (data_be[i]) mem[data_addr[15:2]][i*8 +: 8] <= data_wdata[i*8 +: 8];
        if (data_addr == `TOHOST) begin $display("tohost %0d at %0t", data_wdata, $time); #20 $finish; end
      end
    end
    if (cycles > 400000) begin $display("timeout"); $finish; end
  end
  ibex_top #(.RV32M(RV32MFast), .RV32B(RV32BNone)) dut (
    .clk_i, .rst_ni, .test_en_i(1'b0), .scan_rst_ni(1'b1),
    .ram_cfg_icache_tag_i('0), .ram_cfg_icache_data_i('0),
    .cheriot_enable_i(IbexMuBiOff), .hart_id_i(32'b0), .boot_addr_i(32'h80000000), .trvk_heap_base_addr_i(32'b0),
    .instr_req_o(instr_req), .instr_gnt_i(instr_gnt), .instr_rvalid_i(instr_rvalid), .instr_addr_o(instr_addr),
    .instr_rdata_i(instr_rdata), .instr_rdata_intg_i(7'b0), .instr_err_i(1'b0),
    .data_req_o(data_req), .data_gnt_i(data_gnt), .data_rvalid_i(data_rvalid), .data_we_o(data_we), .data_be_o(data_be),
    .data_addr_o(data_addr), .data_wdata_o(data_wdata), .data_rdata_i(data_rdata), .data_rdata_intg_i(7'b0),
    .data_tag_i(1'b0), .data_err_i(1'b0),
    .trvk_revbm_gnt_i(1'b0), .trvk_revbm_rvalid_i(1'b0), .trvk_revbm_rdata_i(32'b0), .trvk_revbm_rdata_intg_i(7'b0), .trvk_revbm_err_i(1'b0),
    .irq_software_i(1'b0), .irq_timer_i(1'b0), .irq_external_i(1'b0), .irq_fast_i(15'b0), .irq_nm_i(1'b0),
    .scramble_key_valid_i(1'b0), .scramble_key_i('0), .scramble_nonce_i('0), .debug_req_i(1'b0),
    .fetch_enable_i(IbexMuBiOn), .mcounteren_writable_i(IbexMuBiOff));
endmodule
