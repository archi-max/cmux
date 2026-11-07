// SPDX-License-Identifier: MIT
// simctl reusable-testbench pieces: stimulus as data, chosen at run time, so a stimulus change needs no rebuild.
//
//   simctl_cfg   one per testbench. The scenario (one of SCENARIOS, the testbench's own compiled branches) and
//                the arm point: stimulus starts only once armed. Armed by simctl (`arm`), or, without simctl,
//                by +simctl_test=<name> or +simctl_arm at the first rising clock edge with `ready` high
//                (connect the testbench's end of reset). Never armed: nothing here does anything.
//   simctl_port  one per drivable interface. Reads a packed stimulus file (simctl packs the agent's text file:
//                the format is in tb.js) and drives it once armed. KIND "pins": `data` takes each value at the clock
//                edge of its cycle. KIND "vr": each value is presented with `valid` (non-blocking, at a rising
//                edge) and held until `ready` is seen high at a rising edge; then the next one, or valid low.
//                `active` is high while a file is being driven, for a testbench that muxes its own driver.
//                The file comes from +simctl_stim_<NAME>=<packed file> or from simctl (`stim`). Transactions can
//                also be pushed over the pipe (simctl `push`): simctl queues them and changes push_req, and the
//                driver pulls them with $simctl_next. A file is driven first, then what was pushed. No pull
//                happens unless simctl pushed something, so a run without simctl makes no extra calls.
// Packed file, one transaction per line: `<how> <n> <hex value>`; how 0: wait n rising edges after the previous
// transaction (the first: after the arm), how 1: not before the n-th rising edge after the arm. A `#` line is
// a comment. Driving uses only $fopen/$fscanf: no VPI access is needed for it (simctl uses VPI only to set
// the scenario, the file and the arm, and to describe the build).
`timescale 1ns/1ps

module simctl_cfg #(
  parameter string SCENARIOS = ""          // "name:what it does;name:..." (the testbench's scenarios)
) (
  input logic clk,
  input logic ready                        // the testbench's end of reset: plusarg arming waits for it
);
  reg [8*64-1:0] scenario_r = '0;          // written by simctl (a deposit), then arm_req toggled
  reg            arm_req;                  // no initial value: `= 0` would wake @(arm_req) at time 0
  string         scenario = "";
  bit            armed = 1'b0;
  longint unsigned arm_cycle = 0;          // rising edges since the arm (the ports' absolute times)
  bit            plus_arm = 1'b0;
  initial begin
    string s;
    if ($value$plusargs("simctl_test=%s", s)) begin scenario = s; plus_arm = 1'b1; end
    if ($test$plusargs("simctl_arm")) plus_arm = 1'b1;
  end
  always @(posedge clk) begin
    if (armed) arm_cycle <= arm_cycle + 1;
    else if (plus_arm && ready) begin armed <= 1'b1; $display("[simctl] armed at %0t, scenario '%s' (plusargs)", $time, scenario); end
  end
  always @(arm_req) if (!armed && arm_req !== 1'bx) begin
    if (scenario_r != '0) scenario = string'(scenario_r);
    armed = 1'b1;
    $display("[simctl] armed at %0t, scenario '%s'", $time, scenario);
  end
endmodule

module simctl_port #(
  parameter string NAME   = "port",
  parameter int    W      = 32,
  parameter string KIND   = "vr",          // "vr" (valid/ready) or "pins"
  parameter string FIELDS = ""             // default layout over data, msb first: "addr[31:0] len[7:0]"
) (
  input  logic         clk,
  input  logic         armed,              // connect simctl_cfg's armed
  input  longint unsigned arm_cycle,       // and its arm_cycle
  input  logic         ready,              // vr: the sink's ready (unused for pins)
  output logic         valid,
  output logic [W-1:0] data,
  output logic         active
);
  reg [8*1024-1:0] file_r = '0;            // written by simctl, then load_req toggled
  reg              load_req;               // no initial value: `= 0` would wake @(load_req) at time 0
  string           file = "";
  int              fd = 0;
  longint unsigned driven = 0;             // transactions driven so far (simctl reads it)
  reg              push_req;               // changed by simctl after a push (no initial value, as load_req)
  bit              pushed = 1'b0;
  integer          p_how, p_ok;            // $simctl_next's outputs (module-level: VPI writes them)
  longint unsigned p_n;
  logic [W-1:0]    p_v;
  initial begin
    string f;
    valid = 1'b0; data = '0; active = 1'b0;
    if ($value$plusargs({"simctl_stim_", NAME, "=%s"}, f)) file = f;
    if (file != "") open_file();
  end
  always @(push_req) if (push_req !== 1'bx) pushed = 1'b1;
  always @(load_req) if (load_req !== 1'bx && file_r != '0) begin
    file = string'(file_r);
    open_file();
  end
  function void open_file();
    if (fd) $fclose(fd);
    fd = $fopen(file, "r");
    if (!fd) $display("[simctl] port %s: cannot open stimulus %s", NAME, file);
  endfunction
  // the next transaction, or 0 at the end of the file
  function automatic bit next(output int how, output longint unsigned n, output logic [W-1:0] v);
    string line; int k;
    while (fd && !$feof(fd)) begin
      line = "";
      k = $fgets(line, fd);
      if (k <= 0) break;
      if (line.len() == 0 || line[0] == "#" || line[0] == "\n") continue;
      if ($sscanf(line, "%d %d %h", how, n, v) == 3) return 1'b1;
    end
    return 1'b0;
  endfunction

  // the next pushed transaction, or 0 when none is queued
  function automatic bit pull(output int how, output longint unsigned n, output logic [W-1:0] v);
    p_ok = 0;
    $simctl_next(NAME, p_how, p_n, p_v, p_ok);
    how = p_how; n = p_n; v = p_v;
    return p_ok == 1;
  endfunction
  task automatic drive_one(input int how, input longint unsigned n, input logic [W-1:0] v);
    if (how == 1) while (arm_cycle < n) @(posedge clk);
    else for (longint unsigned k = 0; k < n; k++) @(posedge clk);
    if (KIND == "pins") begin
      @(posedge clk); data <= v;
    end else begin
      @(posedge clk); valid <= 1'b1; data <= v;
      do @(posedge clk); while (!ready);
      valid <= 1'b0;
    end
    driven++;
  endtask

  initial begin : drive
    int how; longint unsigned n; logic [W-1:0] v;
    forever begin
      wait (armed && (fd != 0 || pushed));
      active = 1'b1;
      if (fd != 0) begin
        while (next(how, n, v)) drive_one(how, n, v);
        $fclose(fd); fd = 0;
      end else begin
        pushed = 1'b0;
        while (pull(how, n, v)) drive_one(how, n, v);
      end
      active = 1'b0;
    end
  end
endmodule
