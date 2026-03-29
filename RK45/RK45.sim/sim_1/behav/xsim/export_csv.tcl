# Export per-step RK45 simulation data to CSV from xsim.
#
# Steps through simulation one FSM period (514 cycles = 5140 ns) at a time.
# ~20 run calls for 100 us total — fast and crash-safe.
#
# Usage (from compiled sim dir, Vivado Tcl console or batch):
#   xsim Top_TB_behav -tclbatch export_csv.tcl -log export_csv.log

proc safe_get {path radix} {
  if {[catch {set v [get_value -radix $radix $path]} err]} {
    return ""
  }
  return $v
}

set out_file "rk45_hw_hex.csv"
set fp [open $out_file "w"]
puts $fp "time_ns,step_index,done,mem_init,accepted,x_hex,y_hex,err_hex,h_hex"

# One FSM attempt = FLUSH(1) + COMPUTE(512) + UPDATE(1) = 514 cycles × 10 ns
# Step by this amount so we land on the UPDATE cycle each iteration.
set period_ns 5140
set elapsed   0
set step_idx  0
set done_seen 0

# Watchdog to prevent infinite loop if done never asserts.
# 200 iterations * 5140 ns ≈ 1.028 ms simulation time budget.
set max_iters 200
set iter_cnt 0

# Skip init phase: 7 init instructions × 10 ns each
run 70ns
set elapsed 70

while {$done_seen == 0 && $iter_cnt < $max_iters} {
  run ${period_ns}ns
  incr elapsed $period_ns
  incr iter_cnt

  set done_v [safe_get "/Top_TB/done"            bin]
  set init_v [safe_get "/Top_TB/uut/mem_init"    bin]
  set acc_v  [safe_get "/Top_TB/uut/sc_accepted" bin]

  if {$init_v eq "1"} {
    set x_v   [safe_get "/Top_TB/x_out"   hex]
    set y_v   [safe_get "/Top_TB/y_out"   hex]
    set err_v [safe_get "/Top_TB/err_out" hex]
    set h_v   [safe_get "/Top_TB/uut/h1"  hex]
    puts $fp "$elapsed,$step_idx,$done_v,$init_v,$acc_v,$x_v,$y_v,$err_v,$h_v"
    incr step_idx
  }

  if {$done_v eq "1"} { set done_seen 1 }
}

close $fp
puts "INFO: Wrote $step_idx rows to $out_file"
if {$done_seen == 1} {
  puts "INFO: done asserted at ${elapsed}ns (iterations=$iter_cnt)."
} else {
  puts "WARNING: done did not assert before watchdog (iterations=$iter_cnt, elapsed=${elapsed}ns)."
}
# Keep simulator session open when sourced from Vivado GUI.
