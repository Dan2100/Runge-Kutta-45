----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 02/26/2023 07:30:53 PM
-- Design Name: 
-- Module Name: Top - Behavioral
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
use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity Top is
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
end Top;

architecture Behavioral of Top is

component Mem is
Port (   
           cont: in std_logic_vector(31 downto 0);
           addr : in std_logic_vector(11 downto 0);
           x_in: out STD_LOGIC_VECTOR(31 downto 0);
           y_in : out STD_LOGIC_VECTOR(31 downto 0);
           h : out STD_LOGIC_VECTOR(31 downto 0);
           p_in : out STD_LOGIC_VECTOR(31 downto 0);
           p1_in : out STD_LOGIC_VECTOR(31 downto 0);
           c_in : out STD_LOGIC_VECTOR(31 downto 0);
           tol : out STD_LOGIC_VECTOR(31 downto 0);
           x_end : out STD_LOGIC_VECTOR(31 downto 0);
           write_en: in std_logic;
           clock: in std_logic;
           flush : in std_logic;
           init: in std_logic;
           x_out: in STD_LOGIC_VECTOR(31 downto 0);
           y_out : in STD_LOGIC_VECTOR(31 downto 0);
           h_new : in STD_LOGIC_VECTOR(31 downto 0);
           step_ok : in std_logic
            );
end component;

component reg is
Port (
        clk: in std_logic;
        rs1 : in std_logic_vector(4 downto 0);
        regwr : in std_logic;
        wrdata: out std_logic_vector(31 downto 0)
--        x_out : out std_logic_vector(31 downto 0);
--        y_out: out std_logic_vector(31 downto 0)
        );
 end component;

component Control is
Port (
clock: in std_logic;
inst: in std_logic_vector(31 downto 0);
addr: out std_logic_vector(11 downto 0);
flush: out std_logic;
write_en: out std_logic;
init: out std_logic
 );
end component;

component RKMod1 is
Port (
  clk: in std_logic;
   x_in: in STD_LOGIC_VECTOR(31 downto 0);
           y_in : in STD_LOGIC_VECTOR(31 downto 0);
           h : in STD_LOGIC_VECTOR(31 downto 0);
           x_out: out STD_LOGIC_VECTOR(31 downto 0);
           y_out: out STD_LOGIC_VECTOR(31 downto 0);
           err_out: out STD_LOGIC_VECTOR(31 downto 0)
    );
end component;

component step_ctrl is
Port (
    err_in   : in  STD_LOGIC_VECTOR(31 downto 0);
    h_in     : in  STD_LOGIC_VECTOR(31 downto 0);
    tol      : in  STD_LOGIC_VECTOR(31 downto 0);
    h_out    : out STD_LOGIC_VECTOR(31 downto 0);
    accepted : out std_logic
);
end component;

-- Pipeline wait cycles (must exceed RK45 pipeline latency)
constant COMPUTE_WAIT : integer := 512;

-- Adaptive solver state machine
type state_type is (S_IDLE, S_FLUSH, S_COMPUTE, S_UPDATE, S_DONE);
signal state : state_type := S_IDLE;
signal running : std_logic := '0';
signal done_reg : std_logic := '0';
signal wait_cnt : unsigned(9 downto 0) := (others => '0');
signal iter_cnt : unsigned(15 downto 0) := (others => '0');
constant MAX_ITER : unsigned(15 downto 0) := to_unsigned(4096, 16);

-- State machine outputs to Mem
signal sm_flush    : std_logic := '0';
signal sm_write_en : std_logic := '0';
signal sm_init     : std_logic := '0';

-- Muxed control signals to Mem
signal mem_flush    : std_logic;
signal mem_write_en : std_logic;
signal mem_init     : std_logic;
signal mem_h_new    : STD_LOGIC_VECTOR(31 downto 0);
signal mem_step_ok  : std_logic;

-- step_ctrl signals
signal sc_h_out    : STD_LOGIC_VECTOR(31 downto 0);
signal sc_accepted : std_logic;

-- Tolerance and bound from memory
signal tol1     : STD_LOGIC_VECTOR(31 downto 0);
signal x_end1   : STD_LOGIC_VECTOR(31 downto 0);
 
signal addr1: std_logic_vector(11 downto 0);
signal wdata:  std_logic_vector(31 downto 0);
signal  rs :  std_logic_vector(4 downto 0);
signal flush : std_logic;
signal write_en: std_logic;
signal   x_in1:  STD_LOGIC_VECTOR(31 downto 0);
signal  y_in1 :  STD_LOGIC_VECTOR(31 downto 0);
signal    h1 :  STD_LOGIC_VECTOR(31 downto 0);
signal  p_in1 :  STD_LOGIC_VECTOR(31 downto 0);
signal  p1_in1 :  STD_LOGIC_VECTOR(31 downto 0);
signal   c_in1 :  STD_LOGIC_VECTOR(31 downto 0);
signal x_output:  STD_LOGIC_VECTOR(31 downto 0);
signal y_output :  STD_LOGIC_VECTOR(31 downto 0);
signal err_output :  STD_LOGIC_VECTOR(31 downto 0);
signal init : std_logic;

signal  init_flag :  std_logic;
--signal inst:  std_logic_vector(31 downto 0);
begin

---------------------------------------------------------------------------
-- Control signal muxing: instruction mode vs autonomous run mode
---------------------------------------------------------------------------
mem_flush    <= sm_flush    when running = '1' else flush;
mem_write_en <= sm_write_en when running = '1' else write_en;
mem_init     <= sm_init     when running = '1' else init;
mem_h_new    <= sc_h_out    when running = '1' else h1;
mem_step_ok  <= sc_accepted when running = '1' else '1';

---------------------------------------------------------------------------
-- Module instances
---------------------------------------------------------------------------
uut1: Mem port map (
cont => wdata,
addr =>  addr1,
write_en => mem_write_en,
clock => clock,
x_in => x_in1,
y_in => y_in1,
h => h1,
p_in => p_in1,
c_in => c_in1,
p1_in => p1_in1,
tol => tol1,
x_end => x_end1,
flush => mem_flush,
init => mem_init,
x_out => x_output,
y_out => y_output,
h_new => mem_h_new,
step_ok => mem_step_ok
);

uut2: reg port map (
 clk => clock,
 rs1 => inst(19 downto 15), 
 regwr => write_en,
 wrdata => wdata
);

uut3: Control port map (
clock => clock,
inst => inst,
addr => addr1,
flush => flush,
write_en => write_en,
init => init );

uut4: RKMod1 port map (
clk => clock,
x_in => x_in1,
y_in => y_in1,
h => h1,
x_out => x_output,
y_out => y_output,
err_out => err_output
);

uut5: step_ctrl port map (
err_in   => err_output,
h_in     => h1,
tol      => tol1,
h_out    => sc_h_out,
accepted => sc_accepted
);

---------------------------------------------------------------------------
-- Adaptive solver state machine
-- Triggered by instruction with func3="010" (RKS = Run Solver).
-- Autonomously cycles: flush → compute → update, adjusting h on each step.
---------------------------------------------------------------------------
adaptive_fsm: process(clock)
begin
    if rising_edge(clock) then
        case state is

            when S_IDLE =>
                sm_flush <= '0'; sm_write_en <= '0'; sm_init <= '0';
                running <= '0';
                -- Detect RKS instruction: func3 = "010", opcode = "0001100"
                if inst(14 downto 12) = "010" and inst(6 downto 0) = "0001100" then
                    running <= '1';
                    done_reg <= '0';
                    iter_cnt <= (others => '0');
                    state <= S_FLUSH;
                end if;

            when S_FLUSH =>
                -- Assert flush for one cycle to load x, y, h from memory
                sm_flush <= '1'; sm_write_en <= '0'; sm_init <= '0';
                wait_cnt <= (others => '0');
                state <= S_COMPUTE;

            when S_COMPUTE =>
                -- Wait for RK45 pipeline to produce valid output
                sm_flush <= '0'; sm_write_en <= '0'; sm_init <= '0';
                if wait_cnt = to_unsigned(COMPUTE_WAIT - 1, 10) then
                    state <= S_UPDATE;
                else
                    wait_cnt <= wait_cnt + 1;
                end if;

            when S_UPDATE =>
                -- Write results to memory (step_ctrl decides h_new and step_ok)
                sm_flush <= '0'; sm_write_en <= '1'; sm_init <= '1';
                iter_cnt <= iter_cnt + 1;
                if sc_accepted = '1' then
                    -- Bound check: x_output >= x_end (unsigned magnitude comparison)
                    -- IEEE 754 positive floats are ordered as unsigned integers
                    if unsigned(x_output(30 downto 0)) >= unsigned(x_end1(30 downto 0)) then
                        state <= S_DONE;
                    else
                        state <= S_FLUSH;
                    end if;
                else
                    -- Rejected: h was halved, retry same step
                    state <= S_FLUSH;
                end if;
                -- Safety: max-iteration watchdog
                if iter_cnt + 1 >= MAX_ITER then
                    state <= S_DONE;
                end if;

            when S_DONE =>
                sm_flush <= '0'; sm_write_en <= '0'; sm_init <= '0';
                running <= '0';
                done_reg <= '1';
                -- Stay done until a new init instruction resets
                if inst(14 downto 12) = "000" and inst(6 downto 0) = "0001100" then
                    done_reg <= '0';
                    state <= S_IDLE;
                end if;

        end case;
    end if;
end process;

---------------------------------------------------------------------------
-- Output assignments
---------------------------------------------------------------------------
cont <= wdata;
addr <= addr1;
initial <= init;
x_out <= x_output;
y_out <= y_output;
err_out <= err_output;
done <= done_reg;

end Behavioral;