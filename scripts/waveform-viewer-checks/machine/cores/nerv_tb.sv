`timescale 1ns/1ps
// Machine-state fixture wrapper for NERV (our own; the memory protocol follows NERV's testbench.sv,
// ISC, YosysHQ). 64 KiB at 0x80000000 from prog.hex, .bss zero; a store to `tohost` ends the run.
// Built with NERV_RVFI. Stalls come from a fixed-seed LFSR, so rvfi_valid has gaps. Only clock, reset and the RVFI ports (two CSRs) are dumped.
module tb;
  reg clock = 0, reset = 1;
  always #5 clock = !clock;
  reg [7:0] lfsr = 8'h5a;
  wire stall = lfsr[0] & lfsr[3];
  always @(posedge clock) lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
  reg [31:0] mem [0:16383];
  wire [31:0] imem_addr; reg [31:0] imem_data;
  wire dmem_valid; wire [31:0] dmem_addr; wire [3:0] dmem_wstrb; wire [31:0] dmem_wdata; reg [31:0] dmem_rdata;
  wire trap;
  integer i, cycles = 0;
  initial begin
    for (i = 0; i < 16384; i = i + 1) mem[i] = 0;
    $readmemh("prog.hex", mem);
    $dumpfile("nerv.vcd");
    $dumpvars(1, tb.clock, tb.reset);
    $dumpvars(0, tb.dut.rvfi_valid);
    $dumpvars(0, tb.dut.rvfi_order);
    $dumpvars(0, tb.dut.rvfi_insn);
    $dumpvars(0, tb.dut.rvfi_trap);
    $dumpvars(0, tb.dut.rvfi_halt);
    $dumpvars(0, tb.dut.rvfi_intr);
    $dumpvars(0, tb.dut.rvfi_mode);
    $dumpvars(0, tb.dut.rvfi_ixl);
    $dumpvars(0, tb.dut.rvfi_rs1_addr);
    $dumpvars(0, tb.dut.rvfi_rs2_addr);
    $dumpvars(0, tb.dut.rvfi_rs1_rdata);
    $dumpvars(0, tb.dut.rvfi_rs2_rdata);
    $dumpvars(0, tb.dut.rvfi_rd_addr);
    $dumpvars(0, tb.dut.rvfi_rd_wdata);
    $dumpvars(0, tb.dut.rvfi_pc_rdata);
    $dumpvars(0, tb.dut.rvfi_pc_wdata);
    $dumpvars(0, tb.dut.rvfi_mem_addr);
    $dumpvars(0, tb.dut.rvfi_mem_rmask);
    $dumpvars(0, tb.dut.rvfi_mem_wmask);
    $dumpvars(0, tb.dut.rvfi_mem_rdata);
    $dumpvars(0, tb.dut.rvfi_mem_wdata);
    $dumpvars(0, tb.dut.rvfi_csr_mscratch_rmask);
    $dumpvars(0, tb.dut.rvfi_csr_mscratch_wmask);
    $dumpvars(0, tb.dut.rvfi_csr_mscratch_rdata);
    $dumpvars(0, tb.dut.rvfi_csr_mscratch_wdata);
    $dumpvars(0, tb.dut.rvfi_csr_mstatus_rmask);
    $dumpvars(0, tb.dut.rvfi_csr_mstatus_wmask);
    $dumpvars(0, tb.dut.rvfi_csr_mstatus_rdata);
    $dumpvars(0, tb.dut.rvfi_csr_mstatus_wdata);
    repeat (3) @(posedge clock);
    reset <= 0;
  end
  always @(posedge clock) begin
    cycles <= cycles + 1;
    if (!stall && !reset) begin
      imem_data <= mem[imem_addr[15:2]];
      if (dmem_valid) begin
        dmem_rdata <= mem[dmem_addr[15:2]];
        for (i = 0; i < 4; i = i + 1) if (dmem_wstrb[i]) begin
          mem[dmem_addr[15:2]][i*8 +: 8] <= dmem_wdata[i*8 +: 8];
          dmem_rdata <= 32'hx;
        end
        if (|dmem_wstrb && dmem_addr == `TOHOST) begin $display("tohost %0d at %0t", dmem_wdata, $time); #20 $finish; end
      end else dmem_rdata <= 32'hx;
    end
    if (trap || cycles > 200000) begin $display("trap/timeout at %0t", $time); $finish; end
  end
  nerv #(.RESET_ADDR(32'h80000080)) dut (.clock(clock), .reset(reset), .stall(stall), .trap(trap),
    .imem_addr(imem_addr), .imem_data(stall ? 32'bx : imem_data),
    .dmem_valid(dmem_valid), .dmem_addr(dmem_addr), .dmem_wstrb(dmem_wstrb), .dmem_wdata(dmem_wdata),
    .dmem_rdata(stall ? 32'bx : dmem_rdata), .irq(32'b0));
endmodule
