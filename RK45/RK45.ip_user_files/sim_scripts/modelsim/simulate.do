onbreak {quit -f}
onerror {quit -f}

vsim -voptargs="+acc"  -L xil_defaultlib -L xbip_utils_v3_0_15 -L axi_utils_v2_0_11 -L xbip_pipe_v3_0_11 -L xbip_dsp48_wrapper_v3_0_7 -L mult_gen_v12_0_24 -L floating_point_v7_1_21 -L secureip -lib xil_defaultlib xil_defaultlib.Top_TB

set NumericStdNoWarnings 1
set StdArithNoWarnings 1

do {wave.do}

view wave
view structure
view signals

do {Top_TB.udo}

run 1000ns

quit -force
