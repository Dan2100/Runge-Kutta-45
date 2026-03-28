----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 02/26/2023 08:02:34 PM
-- Design Name: 
-- Module Name: Top_TB - Behavioral
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

entity Top_TB is
--  Port ( );
end Top_TB;

architecture Behavioral of Top_TB is
component Top is
 Port (

 clock: in std_logic;
 inst: in std_logic_vector(31 downto 0);
 cont: out std_logic_vector(31 downto 0);
 addr: out std_logic_vector(11 downto 0);
 x_out: out std_logic_vector(31 downto 0);
 y_out: out std_logic_vector(31 downto 0);
 err_out: out std_logic_vector(31 downto 0);
 initial: out std_logic;
 done: out std_logic
 );
end component;

signal clock: std_logic := '1';
signal x_out:  std_logic_vector(31 downto 0);
signal y_out:  std_logic_vector(31 downto 0);
signal err_out:  std_logic_vector(31 downto 0);
signal initial_sig: std_logic;
signal done:  std_logic;
signal cont:  std_logic_vector(31 downto 0);
signal inst:  std_logic_vector(31 downto 0);
signal  addr :  std_logic_vector(11 downto 0);

constant clock_period : time := 10 ns;

begin

uut: Top port map (

inst => inst,
x_out => x_out,
y_out => y_out,
err_out => err_out,
initial => initial_sig,
done => done,
clock => clock,
cont => cont,
addr => addr

);

mem_clock: process
begin

clock <= '0';
wait for clock_period/2;
  clock <= '1';
wait for clock_period/2;
   end process;

proc: process 
begin

-- Init phase: load x, y, h, tol, n_steps into memory
-- mem(0)  = x   = 2.0    (rs1=1)
inst <= "000000000000" &  "00001" & "000" & "00000" & "0001100";
wait for clock_period;

-- mem(4)  = y   = 1.0    (rs1=2)
inst <= "000000000100" &  "00010" & "000" & "00000" & "0001100";
wait for clock_period;

-- mem(8)  = h   = 0.1    (rs1=3)
inst <= "000000001000" &  "00011" & "000" & "00000" & "0001100";
wait for clock_period;

-- mem(12) = tol = 0.05   (rs1=4)
inst <= "000000001100" &  "00100" & "000" & "00000" & "0001100";
wait for clock_period;

-- mem(16) = n_steps = 5  (rs1=5)
inst <= "000000010000" &  "00101" & "000" & "00000" & "0001100";
wait for clock_period;

-- (optional 6th init, addr=20, not used by adaptive solver)
inst <= "000000010100" &  "00110" & "000" & "00000" & "0001100";
wait for clock_period;

-- Issue RKS command: func3 = "010" → triggers adaptive solver
inst <= "000000000000" &  "00001" & "010" & "00000" & "0001100";
wait for clock_period;

-- Clear instruction to avoid re-triggering
inst <= (others => '0');

-- Wait for solver to finish
wait until done = '1';
wait for clock_period * 20;

wait;

end process;



end Behavioral;