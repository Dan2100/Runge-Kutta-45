-- Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
-- Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
-- --------------------------------------------------------------------------------
-- Tool Version: Vivado v.2025.2 (win64) Build 6299465 Fri Nov 14 19:35:11 GMT 2025
-- Date        : Tue Mar 24 23:39:12 2026
-- Host        : Harry running 64-bit major release  (build 9200)
-- Command     : write_vhdl -force -mode synth_stub
--               c:/Users/lehar/OneDrive/Documents/GitHub/Runge-Kutta-45/RK45/RK45.gen/sources_1/ip/fpu_sub/fpu_sub_stub.vhdl
-- Design      : fpu_sub
-- Purpose     : Stub declaration of top-level module interface
-- Device      : xc7k70tfbv676-1
-- --------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity fpu_sub is
  Port ( 
    aclk : in STD_LOGIC;
    s_axis_a_tvalid : in STD_LOGIC;
    s_axis_a_tready : out STD_LOGIC;
    s_axis_a_tdata : in STD_LOGIC_VECTOR ( 31 downto 0 );
    s_axis_b_tvalid : in STD_LOGIC;
    s_axis_b_tready : out STD_LOGIC;
    s_axis_b_tdata : in STD_LOGIC_VECTOR ( 31 downto 0 );
    m_axis_result_tvalid : out STD_LOGIC;
    m_axis_result_tready : in STD_LOGIC;
    m_axis_result_tdata : out STD_LOGIC_VECTOR ( 31 downto 0 )
  );

  attribute CHECK_LICENSE_TYPE : string;
  attribute CHECK_LICENSE_TYPE of fpu_sub : entity is "fpu_sub,floating_point_v7_1_21,{}";
  attribute core_generation_info : string;
  attribute core_generation_info of fpu_sub : entity is "fpu_sub,floating_point_v7_1_21,{x_ipProduct=Vivado 2025.2,x_ipVendor=xilinx.com,x_ipLibrary=ip,x_ipName=floating_point,x_ipVersion=7.1,x_ipCoreRevision=21,x_ipLanguage=VERILOG,x_ipSimLanguage=MIXED,C_XDEVICEFAMILY=kintex7,C_PART=xc7k70tfbv676-1,C_HAS_ADD=0,C_HAS_SUBTRACT=1,C_HAS_MULTIPLY=0,C_HAS_DIVIDE=0,C_HAS_SQRT=0,C_HAS_COMPARE=0,C_HAS_FIX_TO_FLT=0,C_HAS_FLT_TO_FIX=0,C_HAS_FLT_TO_FLT=0,C_HAS_RECIP=0,C_HAS_RECIP_SQRT=0,C_HAS_ABSOLUTE=0,C_HAS_LOGARITHM=0,C_HAS_EXPONENTIAL=0,C_HAS_FMA=0,C_HAS_FMS=0,C_HAS_UNFUSED_MULTIPLY_ADD=0,C_HAS_UNFUSED_MULTIPLY_SUB=0,C_HAS_UNFUSED_MULTIPLY_ACCUMULATOR_A=0,C_HAS_UNFUSED_MULTIPLY_ACCUMULATOR_S=0,C_HAS_ACCUMULATOR_A=0,C_HAS_ACCUMULATOR_S=0,C_HAS_ACCUMULATOR_PRIMITIVE_A=0,C_HAS_ACCUMULATOR_PRIMITIVE_S=0,C_A_WIDTH=32,C_A_FRACTION_WIDTH=24,C_B_WIDTH=32,C_B_FRACTION_WIDTH=24,C_C_WIDTH=32,C_C_FRACTION_WIDTH=24,C_RESULT_WIDTH=32,C_RESULT_FRACTION_WIDTH=24,C_COMPARE_OPERATION=8,C_LATENCY=12,C_OPTIMIZATION=1,C_MULT_USAGE=2,C_BRAM_USAGE=0,C_RATE=1,C_ACCUM_INPUT_MSB=32,C_ACCUM_MSB=32,C_ACCUM_LSB=-31,C_HAS_UNDERFLOW=0,C_HAS_OVERFLOW=0,C_HAS_INVALID_OP=0,C_HAS_DIVIDE_BY_ZERO=0,C_HAS_ACCUM_OVERFLOW=0,C_HAS_ACCUM_INPUT_OVERFLOW=0,C_HAS_ACLKEN=0,C_HAS_ARESETN=0,C_THROTTLE_SCHEME=1,C_HAS_A_TUSER=0,C_HAS_A_TLAST=0,C_HAS_B=1,C_HAS_B_TUSER=0,C_HAS_B_TLAST=0,C_HAS_C=0,C_HAS_C_TUSER=0,C_HAS_C_TLAST=0,C_HAS_OPERATION=0,C_HAS_OPERATION_TUSER=0,C_HAS_OPERATION_TLAST=0,C_HAS_RESULT_TUSER=0,C_HAS_RESULT_TLAST=0,C_TLAST_RESOLUTION=0,C_A_TDATA_WIDTH=32,C_A_TUSER_WIDTH=1,C_B_TDATA_WIDTH=32,C_B_TUSER_WIDTH=1,C_C_TDATA_WIDTH=32,C_C_TUSER_WIDTH=1,C_OPERATION_TDATA_WIDTH=8,C_OPERATION_TUSER_WIDTH=1,C_RESULT_TDATA_WIDTH=32,C_RESULT_TUSER_WIDTH=1,C_FIXED_DATA_UNSIGNED=0}";
  attribute downgradeipidentifiedwarnings : string;
  attribute downgradeipidentifiedwarnings of fpu_sub : entity is "yes";
end fpu_sub;

architecture stub of fpu_sub is
  attribute syn_black_box : boolean;
  attribute black_box_pad_pin : string;
  attribute syn_black_box of stub : architecture is true;
  attribute black_box_pad_pin of stub : architecture is "aclk,s_axis_a_tvalid,s_axis_a_tready,s_axis_a_tdata[31:0],s_axis_b_tvalid,s_axis_b_tready,s_axis_b_tdata[31:0],m_axis_result_tvalid,m_axis_result_tready,m_axis_result_tdata[31:0]";
  attribute x_interface_info : string;
  attribute x_interface_info of aclk : signal is "xilinx.com:signal:clock:1.0 aclk_intf CLK";
  attribute x_interface_mode : string;
  attribute x_interface_mode of aclk : signal is "slave aclk_intf";
  attribute x_interface_parameter : string;
  attribute x_interface_parameter of aclk : signal is "XIL_INTERFACENAME aclk_intf, ASSOCIATED_BUSIF S_AXIS_OPERATION:M_AXIS_RESULT:S_AXIS_C:S_AXIS_B:S_AXIS_A, ASSOCIATED_RESET aresetn, ASSOCIATED_CLKEN aclken, FREQ_HZ 10000000, FREQ_TOLERANCE_HZ 0, PHASE 0.0, INSERT_VIP 0";
  attribute x_interface_info of s_axis_a_tvalid : signal is "xilinx.com:interface:axis:1.0 S_AXIS_A TVALID";
  attribute x_interface_mode of s_axis_a_tvalid : signal is "slave S_AXIS_A";
  attribute x_interface_parameter of s_axis_a_tvalid : signal is "XIL_INTERFACENAME S_AXIS_A, TDATA_NUM_BYTES 4, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 100000000, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0";
  attribute x_interface_info of s_axis_a_tready : signal is "xilinx.com:interface:axis:1.0 S_AXIS_A TREADY";
  attribute x_interface_info of s_axis_a_tdata : signal is "xilinx.com:interface:axis:1.0 S_AXIS_A TDATA";
  attribute x_interface_info of s_axis_b_tvalid : signal is "xilinx.com:interface:axis:1.0 S_AXIS_B TVALID";
  attribute x_interface_mode of s_axis_b_tvalid : signal is "slave S_AXIS_B";
  attribute x_interface_parameter of s_axis_b_tvalid : signal is "XIL_INTERFACENAME S_AXIS_B, TDATA_NUM_BYTES 4, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 100000000, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0";
  attribute x_interface_info of s_axis_b_tready : signal is "xilinx.com:interface:axis:1.0 S_AXIS_B TREADY";
  attribute x_interface_info of s_axis_b_tdata : signal is "xilinx.com:interface:axis:1.0 S_AXIS_B TDATA";
  attribute x_interface_info of m_axis_result_tvalid : signal is "xilinx.com:interface:axis:1.0 M_AXIS_RESULT TVALID";
  attribute x_interface_mode of m_axis_result_tvalid : signal is "master M_AXIS_RESULT";
  attribute x_interface_parameter of m_axis_result_tvalid : signal is "XIL_INTERFACENAME M_AXIS_RESULT, TDATA_NUM_BYTES 4, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 0, HAS_TREADY 1, HAS_TSTRB 0, HAS_TKEEP 0, HAS_TLAST 0, FREQ_HZ 100000000, PHASE 0.0, LAYERED_METADATA undef, INSERT_VIP 0";
  attribute x_interface_info of m_axis_result_tready : signal is "xilinx.com:interface:axis:1.0 M_AXIS_RESULT TREADY";
  attribute x_interface_info of m_axis_result_tdata : signal is "xilinx.com:interface:axis:1.0 M_AXIS_RESULT TDATA";
  attribute x_core_info : string;
  attribute x_core_info of stub : architecture is "floating_point_v7_1_21,Vivado 2025.2";
begin
end;
