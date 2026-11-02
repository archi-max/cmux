`timescale 1ns/1ps
// Machine-state fixture wrapper for PicoRV32 (our own). 64 KiB at 0x80000000 from prog.hex, .bss
// zero; one-cycle memory with a fixed-seed wait-state pattern; a store to `tohost` ends the run.
// Built with RISCV_FORMAL so the core drives rvfi_*; only clock, reset and rvfi_* are dumped.
module tb;
  reg clk = 0, resetn = 0;
  always #5 clk = !clk;
  reg [31:0] mem [0:16383];
  wire mem_valid, mem_instr; reg mem_ready = 0; wire [31:0] mem_addr, mem_wdata; wire [3:0] mem_wstrb; reg [31:0] mem_rdata;
  reg [7:0] lfsr = 8'h3c;
  integer i, cycles = 0;
  initial begin
    for (i = 0; i < 16384; i = i + 1) mem[i] = 0;
    $readmemh("prog.hex", mem);
    $dumpfile("picorv32.vcd");
    $dumpvars(1, tb.clk, tb.resetn);
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
    repeat (3) @(posedge clk);
    resetn <= 1;
  end
  always @(posedge clk) begin
    cycles <= cycles + 1;
    lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
    mem_ready <= 0;
    if (mem_valid && !mem_ready && !lfsr[1]) begin
      mem_ready <= 1;
      mem_rdata <= mem[mem_addr[15:2]];
      for (i = 0; i < 4; i = i + 1) if (mem_wstrb[i]) mem[mem_addr[15:2]][i*8 +: 8] <= mem_wdata[i*8 +: 8];
      if (|mem_wstrb && mem_addr == `TOHOST) begin $display("tohost %0d at %0t", mem_wdata, $time); #20 $finish; end
    end
    if (cycles > 400000) begin $display("timeout"); $finish; end
  end
  picorv32 #(.COMPRESSED_ISA(`COMPRESSED), .ENABLE_MUL(`MULDIV), .ENABLE_DIV(`MULDIV), .PROGADDR_RESET(32'h80000080),
    .ENABLE_COUNTERS(0), .CATCH_MISALIGN(1), .CATCH_ILLINSN(1), .REGS_INIT_ZERO(0)) dut (
    .clk(clk), .resetn(resetn), .mem_valid(mem_valid), .mem_instr(mem_instr), .mem_ready(mem_ready),
    .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb), .mem_rdata(mem_rdata),
    .pcpi_wr(1'b0), .pcpi_rd(32'b0), .pcpi_wait(1'b0), .pcpi_ready(1'b0), .irq(32'b0));
endmodule
