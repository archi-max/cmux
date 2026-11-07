// SPDX-License-Identifier: MIT
// simctl_hold: a held serve point for `apply` + settle (worker.js `apply`).
//
// The testbench calls point() where its own clocks and inputs can stop (for example after reset, before it starts
// its clock). While the TB is inside point(), simctl serves the controller's requests in procedural context:
//   - apply {at:"serve"} calls the already-loaded hook right here; point() then stays held while the native
//     propagation runs, and simctl replies "settled" at this time step's ReadOnlySynch;
//   - checkpoint/restore park the simulator's command line and come back into point() (one time unit later);
//   - a run releases the TB: point() returns, at once when it was serving, or one time unit later (t+1) when
//     simctl was parked at ReadOnlySynch (nothing is writable there), and the run reply says `released`.
// st: 0 go on, 1 held, 2 serve again (written by simctl before it changes rel). Leave rel uninitialised: an
// initial value can wake the @(rel) at time 0. One caller at a time (point() is a static task). It has no
// `timescale: list it after a file that sets one (or use -timescale), as for any module without one.
module simctl_hold;
  reg rel;
  integer st;
  // While the TB waits here nothing else may happen in the design, and a simulator stop (for checkpoint/restore)
  // takes effect only at HDL activity: simctl changes pulse each time unit while it waits for the stop.
  reg pulse;
  integer pulses = 0;
  always @(pulse) pulses = pulses + 1;
  task point;
    begin
      $simctl_serve(st, rel);
      while (st != 0) begin
        @(rel);
        if (st == 2) $simctl_serve(st, rel);
      end
    end
  endtask
endmodule
