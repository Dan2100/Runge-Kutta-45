----------------------------------------------------------------------------------
-- Dormand-Prince RK45 Module
-- Computes 5th-order solution:
--   y_{n+1} = y_n + h*(b1*k1 + b3*k3 + b4*k4 + b5*k5 + b6*k6)
--   x_{n+1} = x_n + h
-- Also computes embedded error estimate using (b5-b4) coefficients.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity RKMod1 is
Port (
    clk   : in std_logic;
    x_in  : in STD_LOGIC_VECTOR(31 downto 0);
    y_in  : in STD_LOGIC_VECTOR(31 downto 0);
    h     : in STD_LOGIC_VECTOR(31 downto 0);
    x_out : out STD_LOGIC_VECTOR(31 downto 0);
    y_out : out STD_LOGIC_VECTOR(31 downto 0);
    err_out : out STD_LOGIC_VECTOR(31 downto 0));
end RKMod1;

architecture Behavioral of RKMod1 is

component k_block is
Port (
    clk  : in std_logic;
    x_in : in STD_LOGIC_VECTOR(31 downto 0);
    y_in : in STD_LOGIC_VECTOR(31 downto 0);
    h    : in STD_LOGIC_VECTOR(31 downto 0);
    k1 : out STD_LOGIC_VECTOR(31 downto 0);
    k2 : out STD_LOGIC_VECTOR(31 downto 0);
    k3 : out STD_LOGIC_VECTOR(31 downto 0);
    k4 : out STD_LOGIC_VECTOR(31 downto 0);
    k5 : out STD_LOGIC_VECTOR(31 downto 0);
    k6 : out STD_LOGIC_VECTOR(31 downto 0));
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

COMPONENT fpu_add
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

-- 5th-order Dormand-Prince b-coefficients (b2 = 0, so k2 is skipped)
constant B1 : STD_LOGIC_VECTOR(31 downto 0) := x"3DBAAAAB"; -- 35/384
constant B3 : STD_LOGIC_VECTOR(31 downto 0) := x"3EE6024D"; -- 500/1113
constant B4 : STD_LOGIC_VECTOR(31 downto 0) := x"3F26AAAB"; -- 125/192
constant B5 : STD_LOGIC_VECTOR(31 downto 0) := x"BEA50E7E"; -- -2187/6784
constant B6 : STD_LOGIC_VECTOR(31 downto 0) := x"3E061862"; -- 11/84

-- Error coefficients e_i = b5_i - b4_i (for embedded error estimate)
constant E1 : STD_LOGIC_VECTOR(31 downto 0) := x"3AA1907F"; -- 71/57600
constant E3 : STD_LOGIC_VECTOR(31 downto 0) := x"BB8B5AD3"; -- -71/16695
constant E4 : STD_LOGIC_VECTOR(31 downto 0) := x"3D177777"; -- 71/1920
constant E5 : STD_LOGIC_VECTOR(31 downto 0) := x"BD50568F"; -- -17253/339200
constant E6 : STD_LOGIC_VECTOR(31 downto 0) := x"3D2BA454"; -- 22/525

signal tvalid : std_logic := '1';
-- tr_dummy removed (use open for unconnected tready ports)

-- k-values from k_block
signal k1 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
signal k2 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
signal k3 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
signal k4 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
signal k5 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
signal k6 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

-- 5th-order solution chain: b1*k1, then accumulate b3*k3, b4*k4, b5*k5, b6*k6
signal sol_mul1 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- B1*k1
signal sol_acc1 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- B3*k3 + prev
signal sol_acc2 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- B4*k4 + prev
signal sol_acc3 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- B5*k5 + prev
signal sol_acc4 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- B6*k6 + prev
signal y_output : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- h*sum + y_in
signal x_output : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

-- Error estimate chain: e1*k1, then accumulate e3*k3, e4*k4, e5*k5, e6*k6
signal err_mul1 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- E1*k1
signal err_acc1 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- E3*k3 + prev
signal err_acc2 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- E4*k4 + prev
signal err_acc3 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- E5*k5 + prev
signal err_acc4 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- E6*k6 + prev
signal err_result : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- h*err_sum

begin

---------------------------------------------------------------------------
-- Compute k1 through k6 via Dormand-Prince k_block
---------------------------------------------------------------------------
uut_kb: k_block port map (
    clk => clk, x_in => x_in, y_in => y_in, h => h,
    k1 => k1, k2 => k2, k3 => k3, k4 => k4, k5 => k5, k6 => k6);

---------------------------------------------------------------------------
-- 5th-order solution: y_out = y_in + h*(B1*k1 + B3*k3 + B4*k4 + B5*k5 + B6*k6)
-- Chain: mul(B1,k1) -> fused(B3,k3,prev) -> fused(B4,k4,prev) ->
--        fused(B5,k5,prev) -> fused(B6,k6,prev) -> fused(h,sum,y_in)
---------------------------------------------------------------------------
-- sol_mul1 = B1 * k1
sol_m1: fpu_mul port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => B1,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => k1,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => sol_mul1);

-- sol_acc1 = B3*k3 + sol_mul1
sol_a1: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => B3,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => k3,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => sol_mul1,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => sol_acc1);

-- sol_acc2 = B4*k4 + sol_acc1
sol_a2: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => B4,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => k4,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => sol_acc1,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => sol_acc2);

-- sol_acc3 = B5*k5 + sol_acc2
sol_a3: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => B5,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => k5,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => sol_acc2,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => sol_acc3);

-- sol_acc4 = B6*k6 + sol_acc3
sol_a4: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => B6,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => k6,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => sol_acc3,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => sol_acc4);

-- y_output = h * sol_acc4 + y_in
sol_final: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => h,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => sol_acc4,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => y_in,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => y_output);

---------------------------------------------------------------------------
-- x_out = x_in + h
---------------------------------------------------------------------------
x_add: fpu_add port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => x_in,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => h,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => x_output);

---------------------------------------------------------------------------
-- Error estimate (without k7 term):
--   err = h * (E1*k1 + E3*k3 + E4*k4 + E5*k5 + E6*k6)
---------------------------------------------------------------------------
-- err_mul1 = E1 * k1
err_m1: fpu_mul port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => E1,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => k1,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => err_mul1);

-- err_acc1 = E3*k3 + err_mul1
err_a1: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => E3,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => k3,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => err_mul1,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => err_acc1);

-- err_acc2 = E4*k4 + err_acc1
err_a2: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => E4,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => k4,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => err_acc1,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => err_acc2);

-- err_acc3 = E5*k5 + err_acc2
err_a3: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => E5,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => k5,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => err_acc2,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => err_acc3);

-- err_acc4 = E6*k6 + err_acc3
err_a4: fpu_fused port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => E6,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => k6,
    s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => err_acc3,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => err_acc4);

-- err_result = h * err_acc4
err_final: fpu_mul port map (
    aclk => clk,
    s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => h,
    s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => err_acc4,
    m_axis_result_tvalid => open, m_axis_result_tready => '1', m_axis_result_tdata => err_result);

---------------------------------------------------------------------------
-- Output assignments
---------------------------------------------------------------------------
x_out   <= x_output;
y_out   <= y_output;
err_out <= err_result;

end Behavioral;
