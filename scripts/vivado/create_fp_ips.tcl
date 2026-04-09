# =============================================================================
# create_fp_ips.tcl — Generate Xilinx Floating Point v7.1 IP Cores
# =============================================================================
# Run from Vivado Tcl Console after opening a project, OR in batch mode:
#   vivado -mode tcl -source scripts/vivado/create_fp_ips.tcl
#
# Generated IPs (all double-precision, IEEE 754, non-blocking):
#   fp_add_sub_dp  — Add/Subtract  (latency 11)
#   fp_mul_dp      — Multiply      (latency  6)
#   fp_div_dp      — Divide        (latency 28)
#   fp_gt_dp       — Compare GT    (latency  2)
#
# Latencies MUST match the `define values in rtl/fp/fp_pkg.svh
# =============================================================================

# ---------------------------------------------------------------------------
# Double-Precision Add/Subtract
# ---------------------------------------------------------------------------
create_ip \
    -name floating_point \
    -vendor xilinx.com \
    -library ip \
    -version 7.1 \
    -module_name fp_add_sub_dp

set_property -dict {
    CONFIG.Operation_Type           Add_Subtract
    CONFIG.A_Precision_Type         Double
    CONFIG.B_Precision_Type         Double
    CONFIG.Result_Precision_Type    Double
    CONFIG.C_Latency                11
    CONFIG.Flow_Control             NonBlocking
    CONFIG.Has_ARESETn              false
    CONFIG.Has_ACLKEN               false
    CONFIG.Has_Operation_Pinout     true
    CONFIG.C_Mult_Usage             Full_Usage
} [get_ips fp_add_sub_dp]

generate_target all [get_ips fp_add_sub_dp]
puts "Created: fp_add_sub_dp  (Add/Subtract, DP, latency=11)"

# ---------------------------------------------------------------------------
# Double-Precision Multiply
# ---------------------------------------------------------------------------
create_ip \
    -name floating_point \
    -vendor xilinx.com \
    -library ip \
    -version 7.1 \
    -module_name fp_mul_dp

set_property -dict {
    CONFIG.Operation_Type           Multiply
    CONFIG.A_Precision_Type         Double
    CONFIG.B_Precision_Type         Double
    CONFIG.Result_Precision_Type    Double
    CONFIG.C_Latency                6
    CONFIG.Flow_Control             NonBlocking
    CONFIG.Has_ARESETn              false
    CONFIG.Has_ACLKEN               false
    CONFIG.C_Mult_Usage             Full_Usage
} [get_ips fp_mul_dp]

generate_target all [get_ips fp_mul_dp]
puts "Created: fp_mul_dp       (Multiply, DP, latency=6)"

# ---------------------------------------------------------------------------
# Double-Precision Divide
# ---------------------------------------------------------------------------
create_ip \
    -name floating_point \
    -vendor xilinx.com \
    -library ip \
    -version 7.1 \
    -module_name fp_div_dp

set_property -dict {
    CONFIG.Operation_Type           Divide
    CONFIG.A_Precision_Type         Double
    CONFIG.B_Precision_Type         Double
    CONFIG.Result_Precision_Type    Double
    CONFIG.C_Latency                28
    CONFIG.Flow_Control             NonBlocking
    CONFIG.Has_ARESETn              false
    CONFIG.Has_ACLKEN               false
} [get_ips fp_div_dp]

generate_target all [get_ips fp_div_dp]
puts "Created: fp_div_dp       (Divide, DP, latency=28)"

# ---------------------------------------------------------------------------
# Double-Precision Compare — Greater Than
# ---------------------------------------------------------------------------
# Derived operations (swap a/b or invert output as needed):
#   a <  b  → swap inputs:   fp_gt_dp(b, a)
#   a >= b  → invert output: ~fp_gt_dp(b, a)
#   a <= b  → invert output: ~fp_gt_dp(a, b)
# ---------------------------------------------------------------------------
create_ip \
    -name floating_point \
    -vendor xilinx.com \
    -library ip \
    -version 7.1 \
    -module_name fp_gt_dp

set_property -dict {
    CONFIG.Operation_Type           Compare
    CONFIG.A_Precision_Type         Double
    CONFIG.B_Precision_Type         Double
    CONFIG.C_Compare_Operation      Greater_Than
    CONFIG.C_Latency                2
    CONFIG.Flow_Control             NonBlocking
    CONFIG.Has_ARESETn              false
    CONFIG.Has_ACLKEN               false
} [get_ips fp_gt_dp]

generate_target all [get_ips fp_gt_dp]
puts "Created: fp_gt_dp        (Compare GT, DP, latency=2)"

puts ""
puts "All FP IPs generated. Latencies in rtl/fp/fp_pkg.svh must match:"
puts "  FP_ADDSUB_LATENCY = 11"
puts "  FP_MUL_LATENCY    =  6"
puts "  FP_DIV_LATENCY    = 28"
puts "  FP_CMP_LATENCY    =  2"
