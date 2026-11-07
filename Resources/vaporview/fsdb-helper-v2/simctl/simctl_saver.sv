// SPDX-License-Identifier: MIT
// simctl fork-save helper: a second top for builds that want file saves without pausing the simulation
// (vcs ... simctl_saver.sv -top <your top> -top simctl_saver). It only runs the documented $save when the
// library, in a forked copy of the simulation, sets `name` and toggles `go`; it never acts otherwise.
module simctl_saver;
  reg [8*1024-1:0] name;
  reg go = 0;
  // `reg go = 0` can wake this at time 0 (seen as "[VCS_SAVE_RESTORE] Failed to rename '' to ''"): an
  // empty name is no request
  always @(go) if (name != 0) $save(name);
endmodule
