transcript off
onbreak {quit -force}
onerror {quit -force}
transcript on

vlib work
vlib activehdl/xbip_utils_v3_0_15
vlib activehdl/axi_utils_v2_0_11
vlib activehdl/xbip_pipe_v3_0_11
vlib activehdl/xbip_dsp48_wrapper_v3_0_7
vlib activehdl/mult_gen_v12_0_24
vlib activehdl/floating_point_v7_1_21
vlib activehdl/xil_defaultlib

vmap xbip_utils_v3_0_15 activehdl/xbip_utils_v3_0_15
vmap axi_utils_v2_0_11 activehdl/axi_utils_v2_0_11
vmap xbip_pipe_v3_0_11 activehdl/xbip_pipe_v3_0_11
vmap xbip_dsp48_wrapper_v3_0_7 activehdl/xbip_dsp48_wrapper_v3_0_7
vmap mult_gen_v12_0_24 activehdl/mult_gen_v12_0_24
vmap floating_point_v7_1_21 activehdl/floating_point_v7_1_21
vmap xil_defaultlib activehdl/xil_defaultlib

vcom -work xbip_utils_v3_0_15 -93  \
"../../ipstatic/hdl/xbip_utils_v3_0_vh_rfs.vhd" \

vcom -work axi_utils_v2_0_11 -93  \
"../../ipstatic/hdl/axi_utils_v2_0_vh_rfs.vhd" \

vcom -work xbip_pipe_v3_0_11 -93  \
"../../ipstatic/hdl/xbip_pipe_v3_0_vh_rfs.vhd" \

vcom -work xbip_dsp48_wrapper_v3_0_7 -93  \
"../../ipstatic/hdl/xbip_dsp48_wrapper_v3_0_vh_rfs.vhd" \

vcom -work mult_gen_v12_0_24 -93  \
"../../ipstatic/hdl/mult_gen_v12_0_vh_rfs.vhd" \

vcom -work floating_point_v7_1_21 -93  \
"../../ipstatic/hdl/floating_point_v7_1_vh_rfs.vhd" \

vcom -work xil_defaultlib -93  \
"../../../RK45.gen/sources_1/ip/fpu_mul/sim/fpu_mul.vhd" \
"../../../RK45.gen/sources_1/ip/fpu_fused/sim/fpu_fused.vhd" \
"../../../RK45.gen/sources_1/ip/fpu_add/sim/fpu_add.vhd" \
"../../../RK45.gen/sources_1/ip/fpu_sub/sim/fpu_sub.vhd" \
"../../../RK45.srcs/sources_1/imports/RK4/Control.vhd" \
"../../../RK45.srcs/sources_1/imports/RK4/Mem.vhd" \
"../../../RK45.srcs/sources_1/imports/RK4/RKMod1.vhd" \
"../../../RK45.srcs/sources_1/imports/RK4/Top.vhd" \
"../../../RK45.srcs/sources_1/imports/RK4/func.vhd" \
"../../../RK45.srcs/sources_1/imports/RK4/k_block.vhd" \
"../../../RK45.srcs/sources_1/imports/RK4/reg.vhd" \
"../../../RK45.srcs/sources_1/imports/RK4/step_ctrl.vhd" \
"../../../RK45.srcs/sources_1/imports/RK4/Top_TB.vhd" \

