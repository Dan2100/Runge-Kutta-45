transcript off
onbreak {quit -force}
onerror {quit -force}
transcript on

asim +access +r +m+fpu_mul  -L xil_defaultlib -L xbip_utils_v3_0_15 -L axi_utils_v2_0_11 -L xbip_pipe_v3_0_11 -L xbip_dsp48_wrapper_v3_0_7 -L mult_gen_v12_0_24 -L floating_point_v7_1_21 -L secureip -O5 xil_defaultlib.fpu_mul

do {fpu_mul.udo}

run 1000ns

endsim

quit -force
