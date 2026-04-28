----------------------------------------------------------------------------------
-- Company:
-- Engineer:
--
-- Create Date: 02/26/2023 08:02:34 PM
-- Design Name:
-- Module Name: Top_TB_pipe - Behavioral
-- Project Name:
-- Target Devices:
-- Tool Versions:
-- Description:  Testbench for the pipelined RK45 top level (Top_pipe).
--               Loads x=2.0, y=1.0, h=0.1, tol=0.05, x_end=2.5 into
--               memory via the custom instruction interface, then fires
--               the RKS command and waits for done='1'.
--               Register file values (reg.vhd):
--                 rs1=1 -> 0x40000000 (2.0)   [NOTE: fix reg.vhd if rs1=1 is 0.0]
--                 rs1=2 -> 0x3F800000 (1.0)
--                 rs1=3 -> 0x3DCCCCCD (0.1)
--                 rs1=4 -> 0x3D4CCCCD (~0.05)
--                 rs1=5 -> 0x40200000 (2.5)   [NOTE: fix reg.vhd if rs1=5 is 3.0]
--
-- Dependencies:  Top_pipe
--
-- Revision:
-- Revision 0.01 - File Created (pipelined testbench)
-- Additional Comments:
--
----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity Top_TB_pipe is
--  Port ( );
end Top_TB_pipe;

architecture Behavioral of Top_TB_pipe is

component Top_pipe is
 Port (
 clock   : in  std_logic;
 inst    : in  std_logic_vector(31 downto 0);
 cont    : out std_logic_vector(31 downto 0);
 addr    : out std_logic_vector(11 downto 0);
 x_out   : out std_logic_vector(31 downto 0);
 y_out   : out std_logic_vector(31 downto 0);
 err_out : out std_logic_vector(31 downto 0);
 initial : out std_logic;
 done    : out std_logic
 );
end component;

signal clock       : std_logic := '1';
signal x_out       : std_logic_vector(31 downto 0);
signal y_out       : std_logic_vector(31 downto 0);
signal err_out     : std_logic_vector(31 downto 0);
signal initial_sig : std_logic;
signal done        : std_logic;
signal cont        : std_logic_vector(31 downto 0);
signal inst        : std_logic_vector(31 downto 0);
signal addr        : std_logic_vector(11 downto 0);

constant clock_period : time := 10 ns;

begin

uut: Top_pipe port map (
    inst    => inst,
    x_out   => x_out,
    y_out   => y_out,
    err_out => err_out,
    initial => initial_sig,
    done    => done,
    clock   => clock,
    cont    => cont,
    addr    => addr
);

mem_clock: process
begin
    clock <= '0';
    wait for clock_period / 2;
    clock <= '1';
    wait for clock_period / 2;
end process;

proc: process
begin

    ---------------------------------------------------------------------------
    -- Init phase: write x, y, h, tol, x_end into memory via INIT WRITE
    -- Instruction encoding:
    --   [31:20] = imm (word address)
    --   [19:15] = rs1 (register index)
    --   [14:12] = func3  "000" = INIT WRITE
    --   [11:7]  = rd     (unused, tied to 0)
    --   [6:0]   = opcode "0001100"
    ---------------------------------------------------------------------------

    -- mem(0)  = x   = 2.0    (rs1=1 -> reg value 0x40000000)
    inst <= "000000000000" & "00001" & "000" & "00000" & "0001100";
    wait for clock_period;

    -- mem(4)  = y   = 1.0    (rs1=2 -> reg value 0x3F800000)
    inst <= "000000000100" & "00010" & "000" & "00000" & "0001100";
    wait for clock_period;

    -- mem(8)  = h   = 0.1    (rs1=3 -> reg value 0x3DCCCCCD)
    inst <= "000000001000" & "00011" & "000" & "00000" & "0001100";
    wait for clock_period;

    -- mem(12) = tol = 0.05   (rs1=4 -> reg value 0x3D4CCCCD)
    inst <= "000000001100" & "00100" & "000" & "00000" & "0001100";
    wait for clock_period;

    -- mem(16) = x_end = 2.5  (rs1=5 -> reg value 0x40200000)
    inst <= "000000010000" & "00101" & "000" & "00000" & "0001100";
    wait for clock_period;

    -- (optional 6th init slot, addr=20, not used by adaptive solver)
    inst <= "000000010100" & "00110" & "000" & "00000" & "0001100";
    wait for clock_period;

    ---------------------------------------------------------------------------
    -- Issue RKS command: func3 = "010" → triggers autonomous adaptive solver
    ---------------------------------------------------------------------------
    inst <= "000000000000" & "00001" & "010" & "00000" & "0001100";
    wait for clock_period;

    -- Clear instruction to avoid re-triggering
    inst <= (others => '0');

    ---------------------------------------------------------------------------
    -- Wait for solver to finish
    ---------------------------------------------------------------------------
    wait until done = '1';
    wait for clock_period * 20;

    wait;

end process;

end Behavioral;
