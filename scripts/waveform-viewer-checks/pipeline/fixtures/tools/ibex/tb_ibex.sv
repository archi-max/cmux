// tb_ibex.sv: minimal Verilator testbench for lowRISC Ibex (ibex_top, RVFI defined).
// 64 KiB RAM at 0x0 shared by the instruction and data ports (grant in the request
// cycle, rvalid one cycle later). boot_addr = 0, so the first fetch is at 0x80.
// Clock period 10 ns (timescale 1ns/1ps). Reset (rst_ni low) for the first 5 posedges.
// +prog=<hex> loads the program (word 0 at address 0x80); runs +cycles=<n> posedges.
`timescale 1ns/1ps
module tb;
  logic clk = 1'b0, rst_ni = 1'b0;
  always #5 clk = ~clk;

  logic [31:0] mem [0:16383];
  logic        instr_req, instr_gnt, instr_rvalid; logic [31:0] instr_addr, instr_rdata;
  logic        data_req, data_gnt, data_rvalid, data_we; logic [3:0] data_be;
  logic [31:0] data_addr, data_wdata, data_rdata;

  assign instr_gnt = instr_req;
  assign data_gnt  = data_req;
  always_ff @(posedge clk) begin
    instr_rvalid <= instr_req & rst_ni;
    data_rvalid  <= data_req & rst_ni;
    if (instr_req) instr_rdata <= mem[instr_addr[15:2]];
    if (data_req) begin
      if (data_we) begin
        for (int b = 0; b < 4; b++) if (data_be[b]) mem[data_addr[15:2]][8*b +: 8] <= data_wdata[8*b +: 8];
      end else data_rdata <= mem[data_addr[15:2]];
    end
  end

  ibex_top #(.WritebackStage(1'b1), .RV32M(ibex_pkg::RV32MFast)) u_top (
    .clk_i(clk), .rst_ni(rst_ni), .test_en_i(1'b0), .scan_rst_ni(1'b1),
    .ram_cfg_icache_tag_i('{default: prim_ram_1p_pkg::RAM_1P_CFG_REQ_DEFAULT}), .ram_cfg_icache_tag_o(),
    .ram_cfg_icache_data_i('{default: prim_ram_1p_pkg::RAM_1P_CFG_REQ_DEFAULT}), .ram_cfg_icache_data_o(),
    .cheriot_enable_i(ibex_pkg::IbexMuBiOff),
    .hart_id_i(32'b0), .boot_addr_i(32'h0), .trvk_heap_base_addr_i(32'h0),
    .instr_req_o(instr_req), .instr_gnt_i(instr_gnt), .instr_rvalid_i(instr_rvalid),
    .instr_addr_o(instr_addr), .instr_rdata_i(instr_rdata), .instr_rdata_intg_i(7'b0), .instr_err_i(1'b0),
    .data_req_o(data_req), .data_gnt_i(data_gnt), .data_rvalid_i(data_rvalid), .data_we_o(data_we),
    .data_be_o(data_be), .data_addr_o(data_addr), .data_wdata_o(data_wdata), .data_wdata_intg_o(),
    .data_tag_o(), .data_rdata_i(data_rdata), .data_rdata_intg_i(7'b0), .data_tag_i(1'b0), .data_err_i(1'b0),
    .trvk_revbm_req_o(), .trvk_revbm_gnt_i(1'b0), .trvk_revbm_rvalid_i(1'b0), .trvk_revbm_addr_o(),
    .trvk_revbm_rdata_i('0), .trvk_revbm_rdata_intg_i('0), .trvk_revbm_err_i(1'b0),
    .irq_software_i(1'b0), .irq_timer_i(1'b0), .irq_external_i(1'b0), .irq_fast_i(15'b0), .irq_nm_i(1'b0),
    .scramble_key_valid_i('0), .scramble_key_i('0), .scramble_nonce_i('0), .scramble_req_o(),
    .debug_req_i(1'b0), .crash_dump_o(), .double_fault_seen_o(),
    .fetch_enable_i(ibex_pkg::IbexMuBiOn), .mcounteren_writable_i(ibex_pkg::IbexMuBiOn),
    .alert_minor_o(), .alert_major_internal_o(), .alert_major_bus_o(), .core_sleep_o(),
    .lockstep_cmp_en_o(), .data_req_shadow_o(), .data_we_shadow_o(), .data_be_shadow_o(),
    .data_addr_shadow_o(), .data_wdata_shadow_o(), .data_wdata_intg_shadow_o(),
    .instr_req_shadow_o(), .instr_addr_shadow_o()
  );

  string prog; int cycles;
  initial begin
    for (int i = 0; i < 16384; i++) mem[i] = 32'h0000006f;  // j . everywhere else
    if (!$value$plusargs("prog=%s", prog)) prog = "ibex.hex";
    if (!$value$plusargs("cycles=%d", cycles)) cycles = 1200;
    $readmemh(prog, mem, 32'h80 >> 2);
    $dumpfile("ibex_full.vcd");
    $dumpvars(0, tb);
    repeat (5) @(posedge clk);
    #1 rst_ni = 1'b1;
    repeat (cycles) @(posedge clk);
    $finish;
  end
endmodule
