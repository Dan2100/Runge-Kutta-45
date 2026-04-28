----------------------------------------------------------------------------------
-- Company:
-- Engineer:
--
-- Create Date: 02/26/2023 07:30:53 PM
-- Design Name:
-- Module Name: Top_pipe - Behavioral
-- Project Name:
-- Target Devices:
-- Tool Versions:
-- Description:  Pipelined RK45 top level.
--               Instantiates RKMod1_pipe (which uses k_block_pipe internally).
--               COMPUTE_WAIT = 500:
--                 k_block_pipe depth  = 360 cycles
--                 RKMod1_pipe chain   =  94 cycles (17*4 + 9 + 3 extra)
--                 k7 FSAL extension   =  33 cycles (FUNC_LAT, valid_out fires at 487)
--                 Safety margin       =  13 cycles
--               Features added:
--                 - FSAL: k7 from step N fed back as k1 for step N+1
--                 - valid_out-driven S_UPDATE transition (wait_cnt is fallback)
--                 - iter_out: 16-bit saturating iteration counter
--                 - timeout: asserted when MAX_ITER watchdog fires
--                 - fault: NaN/Inf propagated from RKMod1_pipe
--
-- Dependencies:  RKMod1_pipe, Mem, reg, Control, step_ctrl
--
-- Revision:
-- Revision 0.01 - File Created (pipelined variant)
-- Additional Comments:
--
----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity Top_pipe is
 Port (
 clock    : in  std_logic;
 inst     : in  std_logic_vector(31 downto 0);
 cont     : out std_logic_vector(31 downto 0);
 addr     : out std_logic_vector(11 downto 0);
 x_out    : out std_logic_vector(31 downto 0);
 y_out    : out std_logic_vector(31 downto 0);
 err_out  : out std_logic_vector(31 downto 0);
 iter_out      : out std_logic_vector(15 downto 0);  -- iteration counter
 timeout       : out std_logic;                       -- MAX_ITER watchdog fired
 fault         : out std_logic;                       -- NaN/Inf in pipeline
 step_accepted : out std_logic;                       -- one-cycle pulse per accepted step
 initial       : out std_logic;
 done          : out std_logic
 );
end Top_pipe;

architecture Behavioral of Top_pipe is

---------------------------------------------------------------------------
-- Component declarations
---------------------------------------------------------------------------
component Mem is
Port (
           cont    : in  std_logic_vector(31 downto 0);
           addr    : in  std_logic_vector(11 downto 0);
           x_in    : out STD_LOGIC_VECTOR(31 downto 0);
           y_in    : out STD_LOGIC_VECTOR(31 downto 0);
           h       : out STD_LOGIC_VECTOR(31 downto 0);
           p_in    : out STD_LOGIC_VECTOR(31 downto 0);
           p1_in   : out STD_LOGIC_VECTOR(31 downto 0);
           c_in    : out STD_LOGIC_VECTOR(31 downto 0);
           tol     : out STD_LOGIC_VECTOR(31 downto 0);
           x_end   : out STD_LOGIC_VECTOR(31 downto 0);
           write_en: in  std_logic;
           clock   : in  std_logic;
           flush   : in  std_logic;
           x_out   : in  STD_LOGIC_VECTOR(31 downto 0);
           y_out   : in  STD_LOGIC_VECTOR(31 downto 0);
           h_new   : in  STD_LOGIC_VECTOR(31 downto 0);
           step_ok : in  std_logic;
           init    : in  std_logic
            );
end component;

component reg is
Port (
        clk     : in  std_logic;
        rs1     : in  std_logic_vector(4 downto 0);
        regwr   : in  std_logic;
        wrdata  : out std_logic_vector(31 downto 0)
        );
end component;

component Control is
Port (
        clock    : in  std_logic;
        inst     : in  std_logic_vector(31 downto 0);
        addr     : out std_logic_vector(11 downto 0);
        flush    : out std_logic;
        write_en : out std_logic;
        init     : out std_logic
        );
end component;

-- Pipelined RK45 solver module (uses k_block_pipe internally)
component RKMod1_pipe is
Port (
        clk       : in  std_logic;
        x_in      : in  STD_LOGIC_VECTOR(31 downto 0);
        y_in      : in  STD_LOGIC_VECTOR(31 downto 0);
        h         : in  STD_LOGIC_VECTOR(31 downto 0);
        k1_in     : in  STD_LOGIC_VECTOR(31 downto 0);
        fsal_en   : in  std_logic;
        valid_in  : in  std_logic;
        valid_out : out std_logic;
        k7_out    : out STD_LOGIC_VECTOR(31 downto 0);
        fault     : out std_logic;
        x_out     : out STD_LOGIC_VECTOR(31 downto 0);
        y_out     : out STD_LOGIC_VECTOR(31 downto 0);
        err_out   : out STD_LOGIC_VECTOR(31 downto 0)
        );
end component;

component step_ctrl is
Port (
        err_in   : in  STD_LOGIC_VECTOR(31 downto 0);
        h_in     : in  STD_LOGIC_VECTOR(31 downto 0);
        atol     : in  STD_LOGIC_VECTOR(31 downto 0);  -- absolute tolerance
        rtol     : in  STD_LOGIC_VECTOR(31 downto 0);  -- relative tolerance
        y_in     : in  STD_LOGIC_VECTOR(31 downto 0);  -- current y output
        h_out    : out STD_LOGIC_VECTOR(31 downto 0);
        accepted : out std_logic
        );
end component;

---------------------------------------------------------------------------
-- Pipeline wait cycles
--   k_block_pipe latency  = 360 cycles (D_K6)
--   RKMod1_pipe tail chain =  94 cycles (4 x FFMA_17 + FMUL_9 + 3 reg)
--   func_k7 (FSAL k7)     =  33 cycles (FUNC_LAT)  → valid_out at 487
--   Safety margin          =  13 cycles
--   Total                  = 500 cycles
-- valid_out from RKMod1_pipe triggers S_UPDATE early if it arrives before
-- COMPUTE_WAIT expires (wait_cnt is kept as a safety fallback).
---------------------------------------------------------------------------
constant COMPUTE_WAIT : integer := 500;

-- Adaptive solver state machine
type state_type is (S_IDLE, S_FLUSH, S_COMPUTE, S_UPDATE, S_DONE);
signal state    : state_type := S_IDLE;
signal running  : std_logic  := '0';
signal done_reg : std_logic  := '0';
signal wait_cnt : unsigned(9 downto 0) := (others => '0');   -- max 1023
signal iter_cnt : unsigned(15 downto 0) := (others => '0');
constant MAX_ITER : unsigned(15 downto 0) := to_unsigned(4096, 16);

-- Solver pipeline new signals
signal solver_valid : std_logic := '0';    -- valid_out from RKMod1_pipe
signal solver_fault : std_logic := '0';    -- NaN/Inf fault from RKMod1_pipe
signal k7_reg       : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- k7 FSAL latch
signal fsal_en_reg  : std_logic := '0';    -- '1' after first accepted step
signal valid_pulse  : std_logic := '0';    -- one-cycle strobe for valid_out rising edge
signal valid_prev   : std_logic := '0';    -- previous value of solver_valid
signal timeout_reg  : std_logic := '0';    -- watchdog fired
signal step_acc_reg : std_logic := '0';    -- one-cycle pulse on accepted step
signal sm_valid_in  : std_logic := '0';    -- valid_in to RKMod1_pipe
signal k7_raw       : STD_LOGIC_VECTOR(31 downto 0);  -- k7_out wire from RKMod1_pipe

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
signal atol1  : STD_LOGIC_VECTOR(31 downto 0);  -- absolute tolerance (mem[12])
signal x_end1 : STD_LOGIC_VECTOR(31 downto 0);

-- Internal wiring
signal addr1    : std_logic_vector(11 downto 0);
signal wdata    : std_logic_vector(31 downto 0);
signal flush    : std_logic;
signal write_en : std_logic;
signal x_in1    : STD_LOGIC_VECTOR(31 downto 0);
signal y_in1    : STD_LOGIC_VECTOR(31 downto 0);
signal h1       : STD_LOGIC_VECTOR(31 downto 0);
signal p_in1    : STD_LOGIC_VECTOR(31 downto 0);
signal p1_in1   : STD_LOGIC_VECTOR(31 downto 0);
signal c_in1    : STD_LOGIC_VECTOR(31 downto 0);
signal x_output : STD_LOGIC_VECTOR(31 downto 0);
signal y_output : STD_LOGIC_VECTOR(31 downto 0);
signal err_output : STD_LOGIC_VECTOR(31 downto 0);
signal init     : std_logic;

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
    cont     => wdata,
    addr     => addr1,
    write_en => mem_write_en,
    clock    => clock,
    x_in     => x_in1,
    y_in     => y_in1,
    h        => h1,
    p_in     => p_in1,
    c_in     => c_in1,
    p1_in    => p1_in1,
    tol      => atol1,
    x_end    => x_end1,
    flush    => mem_flush,
    init     => mem_init,
    x_out    => x_output,
    y_out    => y_output,
    h_new    => mem_h_new,
    step_ok  => mem_step_ok
);

uut2: reg port map (
    clk    => clock,
    rs1    => inst(19 downto 15),
    regwr  => write_en,
    wrdata => wdata
);

uut3: Control port map (
    clock    => clock,
    inst     => inst,
    addr     => addr1,
    flush    => flush,
    write_en => write_en,
    init     => init
);

-- Pipelined solver: k_block_pipe inside RKMod1_pipe
uut4: RKMod1_pipe port map (
    clk       => clock,
    x_in      => x_in1,
    y_in      => y_in1,
    h         => h1,
    k1_in     => k7_reg,       -- FSAL: k7 from previous step
    fsal_en   => fsal_en_reg,  -- enable FSAL bypass after first step
    valid_in  => sm_valid_in,
    valid_out => solver_valid,
    k7_out    => k7_raw,       -- latched into k7_reg on valid_pulse in FSM
    fault     => solver_fault,
    x_out     => x_output,
    y_out     => y_output,
    err_out   => err_output
);

-- c_in1 (mem[20]) repurposed as rtol; y_output gives the current solution
-- value for the relative-tolerance term rtol * |y|.
uut5: step_ctrl port map (
    err_in   => err_output,
    h_in     => h1,
    atol     => atol1,
    rtol     => c_in1,       -- relative tolerance stored at mem[20]
    y_in     => y_output,    -- current solution for rtol * |y| term
    h_out    => sc_h_out,
    accepted => sc_accepted
);

---------------------------------------------------------------------------
-- valid_pulse: one-cycle strobe on the rising edge of solver_valid.
-- Used to trigger S_UPDATE early when the pipeline signals completion
-- rather than waiting the full COMPUTE_WAIT guard.
---------------------------------------------------------------------------
edge_detect: process(clock)
begin
    if rising_edge(clock) then
        valid_prev  <= solver_valid;
        valid_pulse <= solver_valid and (not valid_prev);
    end if;
end process;

---------------------------------------------------------------------------
-- Adaptive solver state machine
-- Triggered by instruction with func3="010" (RKS = Run Solver).
-- Autonomously cycles: flush → compute → update, adjusting h each step.
--
-- New behaviour vs. original:
--   - sm_valid_in pulses '1' for one cycle when entering S_COMPUTE so
--     RKMod1_pipe's valid token is injected exactly once per step.
--   - valid_pulse (rising edge of solver_valid) triggers S_UPDATE early;
--     wait_cnt reaching COMPUTE_WAIT acts as a safety fallback.
--   - solver_fault causes an immediate transition to S_DONE.
--   - k7_raw is latched into k7_reg on valid_pulse; fsal_en_reg set '1'
--     after the first accepted step so that k1 bypass is active from
--     step 2 onward.
--   - timeout_reg is asserted when the MAX_ITER watchdog fires.
---------------------------------------------------------------------------
adaptive_fsm: process(clock)
begin
    if rising_edge(clock) then
        -- Per-cycle defaults (last assignment wins inside the case)
        sm_valid_in <= '0';
        step_acc_reg <= '0';

        case state is

            when S_IDLE =>
                sm_flush    <= '0'; sm_write_en <= '0'; sm_init <= '0';
                running     <= '0';
                timeout_reg <= '0';
                -- Detect RKS instruction: func3 = "010", opcode = "0001100"
                if inst(14 downto 12) = "010" and inst(6 downto 0) = "0001100" then
                    running      <= '1';
                    done_reg     <= '0';
                    iter_cnt     <= (others => '0');
                    fsal_en_reg  <= '0';   -- FSAL disabled until first accepted step
                    state        <= S_FLUSH;
                end if;

            when S_FLUSH =>
                -- Assert flush for one cycle to load x, y, h from memory
                sm_flush <= '1'; sm_write_en <= '0'; sm_init <= '0';
                wait_cnt <= (others => '0');
                state    <= S_COMPUTE;

            when S_COMPUTE =>
                -- Pulse valid_in on the first cycle of S_COMPUTE so the
                -- pipeline's valid token is injected exactly once per step.
                sm_flush <= '0'; sm_write_en <= '0'; sm_init <= '0';
                if wait_cnt = to_unsigned(0, 10) then
                    sm_valid_in <= '1';   -- one-cycle injection
                end if;

                -- Latch k7 on valid_pulse so it is stable for the FSAL bypass
                if valid_pulse = '1' then
                    k7_reg <= k7_raw;
                end if;

                -- Fault: NaN/Inf detected — abort immediately
                if solver_fault = '1' then
                    state <= S_DONE;
                -- valid_pulse: pipeline signalled completion early
                elsif valid_pulse = '1' then
                    state <= S_UPDATE;
                -- Fallback: safety counter expired
                elsif wait_cnt = to_unsigned(COMPUTE_WAIT - 1, 10) then
                    state <= S_UPDATE;
                else
                    wait_cnt <= wait_cnt + 1;
                end if;

            when S_UPDATE =>
                -- Write results to memory (step_ctrl decides h_new and step_ok)
                sm_flush <= '0'; sm_write_en <= '1'; sm_init <= '1';
                iter_cnt <= iter_cnt + 1;

                if sc_accepted = '1' then
                    step_acc_reg <= '1';  -- one-cycle pulse visible to testbench
                    fsal_en_reg  <= '1';  -- FSAL active from next step onward
                    -- Bound check: x_output >= x_end (unsigned magnitude comparison)
                    -- IEEE 754 positive floats are ordered as unsigned integers
                    if unsigned(x_output(30 downto 0)) >= unsigned(x_end1(30 downto 0)) then
                        state <= S_DONE;
                    else
                        state <= S_FLUSH;
                    end if;
                else
                    -- Rejected: h was halved, retry same step.
                    -- Keep fsal_en_reg as-is (k7 was computed but step not accepted;
                    -- the recomputed step will produce a fresh k7.)
                    state <= S_FLUSH;
                end if;

                -- Safety: max-iteration watchdog (evaluated last so it wins)
                if iter_cnt + 1 >= MAX_ITER then
                    timeout_reg <= '1';
                    state       <= S_DONE;
                end if;

            when S_DONE =>
                sm_flush <= '0'; sm_write_en <= '0'; sm_init <= '0';
                running  <= '0';
                done_reg <= '1';
                -- Stay done until a new init instruction resets
                if inst(14 downto 12) = "000" and inst(6 downto 0) = "0001100" then
                    done_reg    <= '0';
                    timeout_reg <= '0';
                    fsal_en_reg <= '0';
                    state       <= S_IDLE;
                end if;

        end case;
    end if;
end process;

---------------------------------------------------------------------------
-- Output assignments
---------------------------------------------------------------------------
cont     <= wdata;
addr     <= addr1;
initial  <= init;
x_out    <= x_output;
y_out    <= y_output;
err_out  <= err_output;
done     <= done_reg;
iter_out      <= std_logic_vector(iter_cnt);
timeout       <= timeout_reg;
fault         <= solver_fault;
step_accepted <= step_acc_reg;

end Behavioral;
