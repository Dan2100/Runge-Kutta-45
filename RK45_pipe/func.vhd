
-- Engineer: Soham Bhattacharya.
-- 
-- Create Date: 11/03/2022 05:17:08 PM
-- Design Name: 
-- Module Name: FEB1 - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- 
----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
--use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity func is
    Port ( clk: in std_logic;
           x_in : in STD_LOGIC_VECTOR(31 downto 0);
           y_in : in STD_LOGIC_VECTOR(31 downto 0);
          --           add1: inout STD_LOGIC_VECTOR(31 downto 0);
--           sub1: inout STD_LOGIC_VECTOR(31 downto 0);
           f : out STD_LOGIC_VECTOR(31 downto 0)
         --  clk: in std_logic
           );
end func;



architecture Behavioral of func is
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

COMPONENT fpu_sub
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

-- f(x,y) = -50(y - x) + 1 = 50(x - y) + 1
-- Pipeline: fpu_sub(x,y) -> fpu_mul(50.0, result) -> fpu_add(result, 1.0)

-- IEEE 754 constants
constant CONST_50 : STD_LOGIC_VECTOR(31 downto 0) := x"42480000"; -- 50.0
constant CONST_1 : STD_LOGIC_VECTOR(31 downto 0) := x"3F800000"; -- 1.0

signal s_axis_a_tvalid: std_logic := '1';
signal s_axis_b_tvalid: std_logic := '1';
signal s_axis_a_tready1: std_logic := '1';
signal s_axis_b_tready1: std_logic := '1';
signal s_axis_a_tready2: std_logic := '1';
signal s_axis_b_tready2: std_logic := '1';
signal s_axis_a_tready3: std_logic := '1';
signal s_axis_b_tready3: std_logic := '1';
signal sub_result: STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
signal mul_result: STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
signal add_result: STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
signal m_axis_result_tvalid1: std_logic := '0';
signal m_axis_result_tvalid2: std_logic := '0';
signal m_axis_result_tvalid3: std_logic := '0';

begin

-- Stage 1: x - y
sub_inst: fpu_sub
  PORT MAP (
    aclk => clk,
    s_axis_a_tready => s_axis_a_tready1,
    s_axis_b_tready => s_axis_b_tready1,
    s_axis_a_tvalid => s_axis_a_tvalid,
    s_axis_a_tdata => x_in,
    s_axis_b_tvalid => s_axis_b_tvalid,
    s_axis_b_tdata => y_in,
    m_axis_result_tvalid => m_axis_result_tvalid1,
    m_axis_result_tready => '1',
    m_axis_result_tdata => sub_result
  );

-- Stage 2: 50 * (x - y)
mul_inst: fpu_mul
  PORT MAP (
    aclk => clk,
    s_axis_a_tready => s_axis_a_tready2,
    s_axis_b_tready => s_axis_b_tready2,
    s_axis_a_tvalid => s_axis_a_tvalid,
    s_axis_a_tdata => CONST_50,
    s_axis_b_tvalid => s_axis_b_tvalid,
    s_axis_b_tdata => sub_result,
    m_axis_result_tvalid => m_axis_result_tvalid2,
    m_axis_result_tready => '1',
    m_axis_result_tdata => mul_result
  );

-- Stage 3: 50(x - y) + 1.0
add_inst: fpu_add
  PORT MAP (
    aclk => clk,
    s_axis_a_tready => s_axis_a_tready3,
    s_axis_b_tready => s_axis_b_tready3,
    s_axis_a_tvalid => s_axis_a_tvalid,
    s_axis_a_tdata => mul_result,
    s_axis_b_tvalid => s_axis_b_tvalid,
    s_axis_b_tdata => CONST_1,
    m_axis_result_tvalid => m_axis_result_tvalid3,
    m_axis_result_tready => '1',
    m_axis_result_tdata => add_result
  );

f <= add_result;

 

end Behavioral;
