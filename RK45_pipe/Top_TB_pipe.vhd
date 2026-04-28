----------------------------------------------------------------------------------
-- Company:
-- Engineer:
--
-- Module Name: Top_TB_pipe - Behavioral
-- Description:
--   Testbench for the pipelined Dormand-Prince RK45 solver (Top_pipe).
--   Loads parameters via the custom instruction interface, fires the RKS
--   command, then logs every accepted integration step and prints a final
--   pass/fail summary.  Outputs are designed to be directly comparable
--   against the companion software reference (rk45_reference.py).
--
-- ODE under test:
--   dy/dx = f(x,y) = 50*(x - y) + 1
--   y(2.0) = 1.0,  solve to x = 10.0
--
-- Analytical solution:
--   y(x) = x + C*exp(-50*x),   C = -exp(100)
--   y(10.0) = 10.0 - exp(-400)  ~= 10.0000000000000 (transient negligible)
--
-- Parameters chosen for a thorough pipeline validation:
--   atol=0.01, rtol=0.001, x_end=10.0 yields ~164 total iterations
--   (~122 accepted, ~42 rejected) — well within MAX_ITER=4096.
--   Compare against 13 iterations in the short run (atol=0.05, x_end=2.5).
--
-- Hardware parameters written to memory:
--   mem[0x000]  x0   = 2.0    (rs1=1: 0x40000000)
--   mem[0x004]  y0   = 1.0    (rs1=2: 0x3F800000)
--   mem[0x008]  h    = 0.1    (rs1=3: 0x3DCCCCCD)
--   mem[0x00C]  atol = 0.01   (rs1=4: 0x3C23D70A)
--   mem[0x010]  xend = 10.0   (rs1=5: 0x41200000)
--   mem[0x014]  rtol = 0.001  (rs1=6: 0x3A83126F)
--
-- Instruction encoding  (opcode = "0001100"):
--   [31:20] imm   = byte address of target memory slot
--   [19:15] rs1   = register file index (supplies the data value)
--   [14:12] func3 = 000 INIT_WRITE | 010 RKS_RUN | 100 RKU_UPDATE
--   [11:7]  rd    = unused (zero)
--   [6:0]   opcode= 0001100
--
-- How to compare against software (rk45_reference.py):
--   1. Run the VHDL simulation in Vivado; capture the transcript.
--   2. Run:  python rk45_reference.py
--   3. Each [STEP] line in the transcript corresponds to one accepted step.
--      Compare the y hex values column-by-column.
--   4. Differences > 1 ULP indicate a pipeline alignment or coefficient bug.
--
-- Notes:
--   * f32_to_real uses MATH_REAL "**" for exponent reconstruction; the result
--     is double-precision and will match Python float to ~7 decimal digits.
--   * Denormals and NaN/Inf are handled gracefully (no simulation crash).
--   * step_accepted fires one cycle after S_UPDATE when sc_accepted='1';
--     x_out/y_out reflect the accepted solution values at that point.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;

entity Top_TB_pipe is
end Top_TB_pipe;

architecture Behavioral of Top_TB_pipe is

    ---------------------------------------------------------------------------
    -- Component: Top_pipe (must exactly match the entity declaration)
    ---------------------------------------------------------------------------
    component Top_pipe is
    Port (
        clock         : in  std_logic;
        inst          : in  std_logic_vector(31 downto 0);
        cont          : out std_logic_vector(31 downto 0);
        addr          : out std_logic_vector(11 downto 0);
        x_out         : out std_logic_vector(31 downto 0);
        y_out         : out std_logic_vector(31 downto 0);
        err_out       : out std_logic_vector(31 downto 0);
        iter_out      : out std_logic_vector(15 downto 0);
        timeout       : out std_logic;
        fault         : out std_logic;
        step_accepted : out std_logic;
        initial       : out std_logic;
        done          : out std_logic
    );
    end component;

    ---------------------------------------------------------------------------
    -- Testbench signals
    ---------------------------------------------------------------------------
    signal clock         : std_logic := '0';
    signal inst          : std_logic_vector(31 downto 0) := (others => '0');
    signal cont          : std_logic_vector(31 downto 0);
    signal addr          : std_logic_vector(11 downto 0);
    signal x_out         : std_logic_vector(31 downto 0);
    signal y_out         : std_logic_vector(31 downto 0);
    signal err_out       : std_logic_vector(31 downto 0);
    signal iter_out      : std_logic_vector(15 downto 0);
    signal timeout_sig   : std_logic;
    signal fault_sig     : std_logic;
    signal step_acc      : std_logic;
    signal initial_sig   : std_logic;
    signal done_sig      : std_logic;

    constant CLK_PERIOD  : time := 10 ns;   -- 100 MHz

    ---------------------------------------------------------------------------
    -- f32_to_real: decode an IEEE 754 single-precision bit pattern to VHDL real.
    -- Handles: signed zero, normals, denormals.
    -- For NaN/Inf (exponent = 0xFF) returns 0.0 — callers must check is_nan/is_inf
    -- first to avoid printing misleading values.
    ---------------------------------------------------------------------------
    function f32_to_real(v : std_logic_vector(31 downto 0)) return real is
        variable sgn  : real    := 1.0;
        variable expo : integer := 0;
        variable mant : real    := 0.0;
        variable bit  : real    := 0.5;
    begin
        if v(31) = '1' then sgn := -1.0; end if;
        expo := to_integer(unsigned(v(30 downto 23)));

        if expo = 255 then          -- NaN or Inf: caller handles
            return 0.0;
        end if;

        -- Reconstruct mantissa (fractional bits 22..0)
        for i in 22 downto 0 loop
            if v(i) = '1' then mant := mant + bit; end if;
            bit := bit / 2.0;
        end loop;

        if expo = 0 then            -- Denormal: hidden bit = 0
            return sgn * mant * (2.0 ** (-126));
        else                        -- Normal: hidden bit = 1
            return sgn * (1.0 + mant) * (2.0 ** (expo - 127));
        end if;
    end function;

    ---------------------------------------------------------------------------
    -- is_nan / is_inf helpers
    ---------------------------------------------------------------------------
    function is_nan(v : std_logic_vector(31 downto 0)) return boolean is
    begin
        return (unsigned(v(30 downto 23)) = 255) and
               (unsigned(v(22 downto  0)) /= 0);
    end function;

    function is_inf(v : std_logic_vector(31 downto 0)) return boolean is
    begin
        return (unsigned(v(30 downto 23)) = 255) and
               (unsigned(v(22 downto  0))  = 0);
    end function;

    ---------------------------------------------------------------------------
    -- float_image: format a 32-bit float as "hex(real)" for report strings.
    ---------------------------------------------------------------------------
    function float_image(v : std_logic_vector(31 downto 0)) return string is
    begin
        if is_nan(v) then
            return "0x" & to_hstring(v) & "(NaN)";
        elsif is_inf(v) then
            if v(31) = '1' then
                return "0x" & to_hstring(v) & "(-Inf)";
            else
                return "0x" & to_hstring(v) & "(+Inf)";
            end if;
        else
            return "0x" & to_hstring(v) &
                   "(" & real'image(f32_to_real(v)) & ")";
        end if;
    end function;

begin

    ---------------------------------------------------------------------------
    -- UUT instantiation
    ---------------------------------------------------------------------------
    uut: Top_pipe port map (
        clock         => clock,
        inst          => inst,
        cont          => cont,
        addr          => addr,
        x_out         => x_out,
        y_out         => y_out,
        err_out       => err_out,
        iter_out      => iter_out,
        timeout       => timeout_sig,
        fault         => fault_sig,
        step_accepted => step_acc,
        initial       => initial_sig,
        done          => done_sig
    );

    ---------------------------------------------------------------------------
    -- Clock generator  (100 MHz, 10 ns period)
    ---------------------------------------------------------------------------
    clk_gen: process
    begin
        clock <= '0'; wait for CLK_PERIOD / 2;
        clock <= '1'; wait for CLK_PERIOD / 2;
    end process;

    ---------------------------------------------------------------------------
    -- Step logger
    -- Monitors step_accepted (one-cycle pulse from Top_pipe) and prints the
    -- accepted (x, y, err) triplet on every rising edge where it is asserted.
    -- The output format is designed to be diff-able against rk45_reference.py.
    ---------------------------------------------------------------------------
    step_log: process
        variable step_n : integer := 0;
    begin
        wait until rising_edge(clock) and step_acc = '1';

        step_n := step_n + 1;

        report "[STEP " & integer'image(step_n) & "]" &
               "  x="   & float_image(x_out)   &
               "  y="   & float_image(y_out)   &
               "  err=" & float_image(err_out)
        severity note;
    end process;

    ---------------------------------------------------------------------------
    -- Fault monitor
    -- Immediately reports if the NaN/Inf fault line rises during a run.
    ---------------------------------------------------------------------------
    fault_mon: process
    begin
        wait until rising_edge(clock) and fault_sig = '1';
        report "[FAULT] NaN or Inf detected in pipeline — solver aborting." &
               "  x=" & float_image(x_out) &
               "  y=" & float_image(y_out) &
               "  err=" & float_image(err_out)
        severity warning;
    end process;

    ---------------------------------------------------------------------------
    -- Stimulus process
    -- Phase 1: Write all six parameter slots via INIT_WRITE instructions.
    -- Phase 2: Issue the RKS (Run Solver) command.
    -- Phase 3: Wait for done, then print the final summary.
    ---------------------------------------------------------------------------
    stimulus: process
        variable y_f : real;
        variable x_f : real;
        variable err_f : real;
        variable pass  : boolean := true;
    begin

        -----------------------------------------------------------------------
        -- PHASE 1: Memory initialisation
        -- Each instruction: imm[31:20] | rs1[19:15] | func3=000 | rd=0 | op
        -----------------------------------------------------------------------

        -- mem[0x000] = x0 = 2.0  (rs1=1 → 0x40000000)
        inst <= "000000000000" & "00001" & "000" & "00000" & "0001100";
        wait for CLK_PERIOD;

        -- mem[0x004] = y0 = 1.0  (rs1=2 → 0x3F800000)
        inst <= "000000000100" & "00010" & "000" & "00000" & "0001100";
        wait for CLK_PERIOD;

        -- mem[0x008] = h  = 0.1  (rs1=3 → 0x3DCCCCCD)
        inst <= "000000001000" & "00011" & "000" & "00000" & "0001100";
        wait for CLK_PERIOD;

        -- mem[0x00C] = atol = 0.01 (rs1=4 → 0x3C23D70A)
        inst <= "000000001100" & "00100" & "000" & "00000" & "0001100";
        wait for CLK_PERIOD;

        -- mem[0x010] = xend = 10.0 (rs1=5 → 0x41200000)
        inst <= "000000010000" & "00101" & "000" & "00000" & "0001100";
        wait for CLK_PERIOD;

        -- mem[0x014] = rtol = 0.001 (rs1=6 → 0x3A83126F)
        -- This slot (c_in / mem[20]) is repurposed as relative tolerance.
        inst <= "000000010100" & "00110" & "000" & "00000" & "0001100";
        wait for CLK_PERIOD;

        -- Clear instruction bus
        inst <= (others => '0');
        wait for CLK_PERIOD;

        report "==========================================================" severity note;
        report "=== RK45 Pipe Testbench ===" severity note;
        report "    ODE      : dy/dx = 50*(x-y)+1" severity note;
        report "    IC       : y(2.0) = 1.0" severity note;
        report "    x_end    : 10.0" severity note;
        report "    atol     : 0.01    (0x3C23D70A)" severity note;
        report "    rtol     : 0.001   (0x3A83126F)" severity note;
        report "    h_init   : 0.1     (0x3DCCCCCD)" severity note;
        report "    Expected : ~164 iterations (122 accepted, 42 rejected)" severity note;
        report "    Analytical y(10.0) = 10.0 - exp(-400) ~= 10.0000000000" severity note;
        report "==========================================================" severity note;

        -----------------------------------------------------------------------
        -- PHASE 2: Issue RKS (Run Solver) command
        -- func3 = "010" triggers the autonomous adaptive FSM
        -----------------------------------------------------------------------
        inst <= "000000000000" & "00001" & "010" & "00000" & "0001100";
        wait for CLK_PERIOD;

        -- Hold instruction clear to prevent re-triggering on next cycle
        inst <= (others => '0');

        report "--- RKS issued: solver pipeline running ---" severity note;

        -----------------------------------------------------------------------
        -- PHASE 3: Wait for solver completion
        -----------------------------------------------------------------------
        wait until done_sig = '1';
        wait for CLK_PERIOD * 4;    -- let final registered values settle

        -----------------------------------------------------------------------
        -- PHASE 4: Final summary
        -----------------------------------------------------------------------
        x_f   := f32_to_real(x_out);
        y_f   := f32_to_real(y_out);
        err_f := f32_to_real(err_out);

        report "==========================================================" severity note;
        report "=== SOLVER COMPLETE ===" severity note;
        report "  iterations : " &
               integer'image(to_integer(unsigned(iter_out))) severity note;
        report "  fault      : " & std_logic'image(fault_sig) severity note;
        report "  timeout    : " & std_logic'image(timeout_sig) severity note;
        report "  x_final    : " & float_image(x_out) severity note;
        report "  y_final    : " & float_image(y_out) severity note;
        report "  err_final  : " & float_image(err_out) severity note;

        -----------------------------------------------------------------------
        -- Pass/fail checks
        -----------------------------------------------------------------------

        -- 1. No fault
        if fault_sig = '1' then
            report "  [FAIL] fault flag asserted — NaN/Inf in pipeline" severity error;
            pass := false;
        end if;

        -- 2. No timeout
        if timeout_sig = '1' then
            report "  [FAIL] MAX_ITER watchdog fired" severity error;
            pass := false;
        end if;

        -- 3. x_final should equal x_end = 10.0
        if abs(x_f - 10.0) > 0.1 then
            report "  [FAIL] x_final = " & real'image(x_f) &
                   " expected ~10.0" severity error;
            pass := false;
        end if;

        -- 4. y_final within atol of analytical answer (10.0 - exp(-400) ≈ 10.0)
        if abs(y_f - 10.0) < 0.01 then
            report "  [PASS] |y_final - 10.0| = " &
                   real'image(abs(y_f - 10.0)) &
                   "  (within atol=0.01)" severity note;
        else
            report "  [FAIL] |y_final - 10.0| = " &
                   real'image(abs(y_f - 10.0)) &
                   "  (exceeds atol=0.01)" severity error;
            pass := false;
        end if;

        if pass then
            report "  === ALL CHECKS PASSED ===" severity note;
        else
            report "  === ONE OR MORE CHECKS FAILED ===" severity error;
        end if;

        report "==========================================================" severity note;

        wait;   -- simulation stops here
    end process;

end Behavioral;
