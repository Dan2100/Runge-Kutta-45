# 100 MHz clock constraint (10 ns period)
create_clock -period 10.000 -name sys_clk [get_ports clock]

set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]