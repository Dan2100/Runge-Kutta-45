----------------------------------------------------------------------------------
-- Dormand-Prince RK45 K Block
-- Computes k1 through k6 using the Dormand-Prince Butcher tableau.
-- All DP coefficients are embedded as IEEE 754 constants.
--
-- Butcher tableau (a_ij):
--   k1 = f(x, y)
--   k2 = f(x + c2*h, y + h*(a21*k1))
--   k3 = f(x + c3*h, y + h*(a31*k1 + a32*k2))
--   k4 = f(x + c4*h, y + h*(a41*k1 + a42*k2 + a43*k3))
--   k5 = f(x + c5*h, y + h*(a51*k1 + a52*k2 + a53*k3 + a54*k4))
--   k6 = f(x + h,     y + h*(a61*k1 + a62*k2 + a63*k3 + a64*k4 + a65*k5))
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity k_block is
Port (     clk : in std_logic;
           x_in : in STD_LOGIC_VECTOR(31 downto 0);
           y_in : in STD_LOGIC_VECTOR(31 downto 0);
           h    : in STD_LOGIC_VECTOR(31 downto 0);
           k1 : out STD_LOGIC_VECTOR(31 downto 0);
           k2 : out STD_LOGIC_VECTOR(31 downto 0);
           k3 : out STD_LOGIC_VECTOR(31 downto 0);
           k4 : out STD_LOGIC_VECTOR(31 downto 0);
           k5 : out STD_LOGIC_VECTOR(31 downto 0);
           k6 : out STD_LOGIC_VECTOR(31 downto 0));
end k_block;

architecture Behavioral of k_block is

component func is
    Port ( x_in : in STD_LOGIC_VECTOR(31 downto 0);
           y_in : in STD_LOGIC_VECTOR(31 downto 0);
           clk  : in std_logic;
           f    : out STD_LOGIC_VECTOR(31 downto 0));
end component;

COMPONENT fpu_mul
  PORT (
    aclk : IN STD_LOGIC;
    s_axis_a_tvalid : IN STD_LOGIC;
    s_axis_a_tready : OUT STD_LOGIC;
    s_axis_a_tdata : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
    s_axis_b_tvalid : IN STD_LOGIC;
    s_axis_b_tready : OUT STD_LOGIC;
    s_axis_b_tdata : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
    m_axis_result_tvalid : OUT STD_LOGIC;
    m_axis_result_tready : IN STD_LOGIC;
    m_axis_result_tdata : OUT STD_LOGIC_VECTOR(31 DOWNTO 0)
  );
END COMPONENT;

COMPONENT fpu_fused
  PORT (
    aclk : IN STD_LOGIC;
    s_axis_a_tvalid : IN STD_LOGIC;
    s_axis_a_tready : OUT STD_LOGIC;
    s_axis_a_tdata : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
    s_axis_b_tvalid : IN STD_LOGIC;
    s_axis_b_tready : OUT STD_LOGIC;
    s_axis_b_tdata : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
    s_axis_c_tvalid : IN STD_LOGIC;
    s_axis_c_tready : OUT STD_LOGIC;
    s_axis_c_tdata : IN STD_LOGIC_VECTOR(31 DOWNTO 0);
    m_axis_result_tvalid : OUT STD_LOGIC;
    m_axis_result_tready : IN STD_LOGIC;
    m_axis_result_tdata : OUT STD_LOGIC_VECTOR(31 DOWNTO 0)
  );
END COMPONENT;

-- Dormand-Prince c-values (x offsets): x_i = x + c_i * h
constant C2 : STD_LOGIC_VECTOR(31 downto 0) := x"3E4CCCCD"; -- 1/5
constant C3 : STD_LOGIC_VECTOR(31 downto 0) := x"3E99999A"; -- 3/10
constant C4 : STD_LOGIC_VECTOR(31 downto 0) := x"3F4CCCCD"; -- 4/5
constant C5 : STD_LOGIC_VECTOR(31 downto 0) := x"3F638E39"; -- 8/9

-- Dormand-Prince a-values (Butcher tableau coefficients)
constant A21 : STD_LOGIC_VECTOR(31 downto 0) := x"3E4CCCCD"; -- 1/5
constant A31 : STD_LOGIC_VECTOR(31 downto 0) := x"3D99999A"; -- 3/40
constant A32 : STD_LOGIC_VECTOR(31 downto 0) := x"3E666666"; -- 9/40
constant A41 : STD_LOGIC_VECTOR(31 downto 0) := x"3F7A4FA5"; -- 44/45
constant A42 : STD_LOGIC_VECTOR(31 downto 0) := x"C06EEEEF"; -- -56/15
constant A43 : STD_LOGIC_VECTOR(31 downto 0) := x"40638E39"; -- 32/9
constant A51 : STD_LOGIC_VECTOR(31 downto 0) := x"403CF760"; -- 19372/6561
constant A52 : STD_LOGIC_VECTOR(31 downto 0) := x"C139885F"; -- -25360/2187
constant A53 : STD_LOGIC_VECTOR(31 downto 0) := x"411D2A92"; -- 64448/6561
constant A54 : STD_LOGIC_VECTOR(31 downto 0) := x"BE94E4F6"; -- -212/729
constant A61 : STD_LOGIC_VECTOR(31 downto 0) := x"40362960"; -- 9017/3168
constant A62 : STD_LOGIC_VECTOR(31 downto 0) := x"C12C1F08"; -- -355/33
constant A63 : STD_LOGIC_VECTOR(31 downto 0) := x"410E80B5"; -- 46732/5247
constant A64 : STD_LOGIC_VECTOR(31 downto 0) := x"3E8E8BA3"; -- 49/176
constant A65 : STD_LOGIC_VECTOR(31 downto 0) := x"BE8C0C4C"; -- -5103/18656

-- AXI-Stream handshake signals (active high, always valid)
signal tvalid : std_logic := '1';

-- Internal k signals
signal K11 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
signal K22 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
signal K33 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
signal K44 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
signal K55 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
signal K66 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

-- Stage 2: x2, y2
signal x2 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
signal s2_mul1 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- A21*k1
signal y2 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');     -- h*(A21*k1) + y

-- Stage 3: x3, y3
signal x3 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
signal s3_mul1 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- A31*k1
signal s3_acc1 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- A32*k2 + A31*k1
signal y3 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

-- Stage 4: x4, y4
signal x4 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
signal s4_mul1 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- A41*k1
signal s4_acc1 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- A42*k2 + prev
signal s4_acc2 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- A43*k3 + prev
signal y4 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

-- Stage 5: x5, y5
signal x5 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
signal s5_mul1 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- A51*k1
signal s5_acc1 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- A52*k2 + prev
signal s5_acc2 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- A53*k3 + prev
signal s5_acc3 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- A54*k4 + prev
signal y5 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

-- Stage 6: x6, y6
signal x6 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
signal s6_mul1 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- A61*k1
signal s6_acc1 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- A62*k2 + prev
signal s6_acc2 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- A63*k3 + prev
signal s6_acc3 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- A64*k4 + prev
signal s6_acc4 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- A65*k5 + prev
signal y6 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

-- Unused tready signals (required by IP but ignored)
-- tr_dummy removed (use open for unconnected tready ports)

begin

---------------------------------------------------------------------------
-- STAGE 1: k1 = f(x_in, y_in)
---------------------------------------------------------------------------
f1: func port map (
    x_in => x_in, y_in => y_in, clk => clk, f => K11);

---------------------------------------------------------------------------
-- STAGE 2: k2 = f(x + c2*h, y + h*(a21*k1))
---------------------------------------------------------------------------
-- x2 = c2*h + x_in
s2_x: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => C2,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => h,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => x_in,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => x2);

-- s2_mul1 = A21 * k1
s2_m1: fpu_mul port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A21,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K11,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => s2_mul1);

-- y2 = h * s2_mul1 + y_in
s2_y: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => h,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => s2_mul1,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => y_in,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => y2);

f2: func port map (
    x_in => x2, y_in => y2, clk => clk, f => K22);

---------------------------------------------------------------------------
-- STAGE 3: k3 = f(x + c3*h, y + h*(a31*k1 + a32*k2))
---------------------------------------------------------------------------
-- x3 = c3*h + x_in
s3_x: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => C3,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => h,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => x_in,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => x3);

-- s3_mul1 = A31 * k1
s3_m1: fpu_mul port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A31,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K11,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => s3_mul1);

-- s3_acc1 = A32 * k2 + s3_mul1
s3_a1: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A32,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K22,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => s3_mul1,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => s3_acc1);

-- y3 = h * s3_acc1 + y_in
s3_y: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => h,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => s3_acc1,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => y_in,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => y3);

f3: func port map (
    x_in => x3, y_in => y3, clk => clk, f => K33);

---------------------------------------------------------------------------
-- STAGE 4: k4 = f(x + c4*h, y + h*(a41*k1 + a42*k2 + a43*k3))
---------------------------------------------------------------------------
-- x4 = c4*h + x_in
s4_x: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => C4,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => h,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => x_in,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => x4);

-- s4_mul1 = A41 * k1
s4_m1: fpu_mul port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A41,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K11,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => s4_mul1);

-- s4_acc1 = A42*k2 + s4_mul1
s4_a1: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A42,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K22,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => s4_mul1,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => s4_acc1);

-- s4_acc2 = A43*k3 + s4_acc1
s4_a2: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A43,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K33,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => s4_acc1,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => s4_acc2);

-- y4 = h * s4_acc2 + y_in
s4_y: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => h,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => s4_acc2,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => y_in,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => y4);

f4: func port map (
    x_in => x4, y_in => y4, clk => clk, f => K44);

---------------------------------------------------------------------------
-- STAGE 5: k5 = f(x + c5*h, y + h*(a51*k1 + a52*k2 + a53*k3 + a54*k4))
---------------------------------------------------------------------------
-- x5 = c5*h + x_in
s5_x: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => C5,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => h,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => x_in,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => x5);

-- s5_mul1 = A51 * k1
s5_m1: fpu_mul port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A51,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K11,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => s5_mul1);

-- s5_acc1 = A52*k2 + s5_mul1
s5_a1: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A52,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K22,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => s5_mul1,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => s5_acc1);

-- s5_acc2 = A53*k3 + s5_acc1
s5_a2: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A53,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K33,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => s5_acc1,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => s5_acc2);

-- s5_acc3 = A54*k4 + s5_acc2
s5_a3: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A54,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K44,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => s5_acc2,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => s5_acc3);

-- y5 = h * s5_acc3 + y_in
s5_y: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => h,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => s5_acc3,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => y_in,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => y5);

f5: func port map (
    x_in => x5, y_in => y5, clk => clk, f => K55);

---------------------------------------------------------------------------
-- STAGE 6: k6 = f(x + h, y + h*(a61*k1 + a62*k2 + a63*k3 + a64*k4 + a65*k5))
-- Note: c6 = 1, so x6 = x + h (use fpu_fused with 1.0*h + x, or just add)
---------------------------------------------------------------------------
-- x6 = 1.0*h + x_in  (c6 = 1)
s6_x: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => x"3F800000",
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => h,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => x_in,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => x6);

-- s6_mul1 = A61 * k1
s6_m1: fpu_mul port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A61,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K11,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => s6_mul1);

-- s6_acc1 = A62*k2 + s6_mul1
s6_a1: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A62,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K22,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => s6_mul1,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => s6_acc1);

-- s6_acc2 = A63*k3 + s6_acc1
s6_a2: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A63,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K33,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => s6_acc1,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => s6_acc2);

-- s6_acc3 = A64*k4 + s6_acc2
s6_a3: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A64,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K44,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => s6_acc2,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => s6_acc3);

-- s6_acc4 = A65*k5 + s6_acc3
s6_a4: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A65,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K55,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => s6_acc3,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => s6_acc4);

-- y6 = h * s6_acc4 + y_in
s6_y: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => h,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => s6_acc4,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => y_in,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => y6);

f6: func port map (
    x_in => x6, y_in => y6, clk => clk, f => K66);

---------------------------------------------------------------------------
-- Output assignments
---------------------------------------------------------------------------
k1 <= K11;
k2 <= K22;
k3 <= K33;
k4 <= K44;
k5 <= K55;
k6 <= K66;

end Behavioral;
