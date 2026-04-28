----------------------------------------------------------------------------------
-- RKMod1_pipe.vhd
--
-- Pipelined Dormand-Prince RK45 Module
-- Drop-in replacement for RKMod1.vhd using k_block_pipe for the k computation
-- and properly aligned delay lines throughout the solution/error chains.
--
-- Unlike RKMod1.vhd (which relies on a long steady-state wait for all
-- combinatorial paths to settle), every inter-stage dependency here is
-- matched with a registered shift-register delay so that inputs and their
-- derived values arrive at each FPU simultaneously.
--
-- Interface is identical to RKMod1:
--   Inputs : clk, x_in, y_in, h
--   Outputs: x_out, y_out, err_out
--
-- Pipeline latency constants (derived from .xci IP configuration):
--   FMUL_LAT = 9, FADD_LAT = 12, FFMA_LAT = 17, FUNC_LAT = 33
--   K_BLOCK_PIPE_LAT = 360   (k_block_pipe PIPELINE_DEPTH)
--
-- Stage depths (absolute, from when x_in/y_in/h enter this module):
--   k1-k6 available  : 360
--   sol/err acc chain: +77  from k arrival  (4 × FFMA + 1 × FMUL lead-in)
--   y_out            : 360 + 77 + FFMA = 454
--   err_out          : 360 + 77 + FMUL = 446
--   x_out            : 454  (x_in+h delayed to align with y_out)
--
-- PIPELINE_DEPTH = 454
-- Set COMPUTE_WAIT >= 454 in Top_pipe.vhd (recommended: 460).
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity RKMod1_pipe is
    port (
        clk       : in  std_logic;
        x_in      : in  STD_LOGIC_VECTOR(31 downto 0);
        y_in      : in  STD_LOGIC_VECTOR(31 downto 0);
        h         : in  STD_LOGIC_VECTOR(31 downto 0);
        -- FSAL: pass through to k_block_pipe
        k1_in     : in  STD_LOGIC_VECTOR(31 downto 0);
        fsal_en   : in  std_logic;
        -- Streaming valid token; valid_out fires PIPELINE_DEPTH+FUNC_LAT
        -- cycles after valid_in, indicating k7_out is also stable.
        valid_in  : in  std_logic;
        valid_out : out std_logic;
        -- k7 = f(x_out, y_out): FSAL feed-forward for next step's k1
        k7_out    : out STD_LOGIC_VECTOR(31 downto 0);
        -- NaN/Inf fault on any output
        fault     : out std_logic;
        x_out     : out STD_LOGIC_VECTOR(31 downto 0);
        y_out     : out STD_LOGIC_VECTOR(31 downto 0);
        err_out   : out STD_LOGIC_VECTOR(31 downto 0)
    );
end RKMod1_pipe;

architecture Behavioral of RKMod1_pipe is

    ---------------------------------------------------------------------------
    -- Component declarations
    ---------------------------------------------------------------------------
    component k_block_pipe is
        port (
            clk       : in  std_logic;
            x_in      : in  STD_LOGIC_VECTOR(31 downto 0);
            y_in      : in  STD_LOGIC_VECTOR(31 downto 0);
            h         : in  STD_LOGIC_VECTOR(31 downto 0);
            k1_in     : in  STD_LOGIC_VECTOR(31 downto 0);
            fsal_en   : in  std_logic;
            valid_in  : in  std_logic;
            valid_out : out std_logic;
            k1        : out STD_LOGIC_VECTOR(31 downto 0);
            k2        : out STD_LOGIC_VECTOR(31 downto 0);
            k3        : out STD_LOGIC_VECTOR(31 downto 0);
            k4        : out STD_LOGIC_VECTOR(31 downto 0);
            k5        : out STD_LOGIC_VECTOR(31 downto 0);
            k6        : out STD_LOGIC_VECTOR(31 downto 0));
    end component;

    component fpu_mul
        port (
            aclk                 : in  std_logic;
            s_axis_a_tvalid      : in  std_logic;
            s_axis_a_tready      : out std_logic;
            s_axis_a_tdata       : in  STD_LOGIC_VECTOR(31 downto 0);
            s_axis_b_tvalid      : in  std_logic;
            s_axis_b_tready      : out std_logic;
            s_axis_b_tdata       : in  STD_LOGIC_VECTOR(31 downto 0);
            m_axis_result_tvalid : out std_logic;
            m_axis_result_tready : in  std_logic;
            m_axis_result_tdata  : out STD_LOGIC_VECTOR(31 downto 0));
    end component;

    component fpu_add
        port (
            aclk                 : in  std_logic;
            s_axis_a_tvalid      : in  std_logic;
            s_axis_a_tready      : out std_logic;
            s_axis_a_tdata       : in  STD_LOGIC_VECTOR(31 downto 0);
            s_axis_b_tvalid      : in  std_logic;
            s_axis_b_tready      : out std_logic;
            s_axis_b_tdata       : in  STD_LOGIC_VECTOR(31 downto 0);
            m_axis_result_tvalid : out std_logic;
            m_axis_result_tready : in  std_logic;
            m_axis_result_tdata  : out STD_LOGIC_VECTOR(31 downto 0));
    end component;

    component fpu_fused
        port (
            aclk                 : in  std_logic;
            s_axis_a_tvalid      : in  std_logic;
            s_axis_a_tready      : out std_logic;
            s_axis_a_tdata       : in  STD_LOGIC_VECTOR(31 downto 0);
            s_axis_b_tvalid      : in  std_logic;
            s_axis_b_tready      : out std_logic;
            s_axis_b_tdata       : in  STD_LOGIC_VECTOR(31 downto 0);
            s_axis_c_tvalid      : in  std_logic;
            s_axis_c_tready      : out std_logic;
            s_axis_c_tdata       : in  STD_LOGIC_VECTOR(31 downto 0);
            m_axis_result_tvalid : out std_logic;
            m_axis_result_tready : in  std_logic;
            m_axis_result_tdata  : out STD_LOGIC_VECTOR(31 downto 0));
    end component;

    component func is
        port (
            clk  : in  std_logic;
            x_in : in  STD_LOGIC_VECTOR(31 downto 0);
            y_in : in  STD_LOGIC_VECTOR(31 downto 0);
            f    : out STD_LOGIC_VECTOR(31 downto 0));
    end component;

    ---------------------------------------------------------------------------
    -- Pipeline latency constants (must match .xci configuration)
    ---------------------------------------------------------------------------
    constant FMUL_LAT         : positive := 9;
    constant FADD_LAT         : positive := 12;
    constant FFMA_LAT         : positive := 17;
    constant FUNC_LAT         : positive := 33;  -- FSUB+FMUL+FADD
    constant K_BLOCK_PIPE_LAT : positive := 360;

    -- Solution / error chain depths relative to k arrival (t = 0)
    -- Chain: mul(B1,k1) -> fused(B3,k3_d9,prev) -> fused(B4,k4_d26,prev)
    --                   -> fused(B5,k5_d43,prev) -> fused(B6,k6_d60,prev)
    --                   -> fused(h,sum,y_in)
    constant K3_DELAY   : positive := FMUL_LAT;                       --  9
    constant K4_DELAY   : positive := FMUL_LAT + FFMA_LAT;           -- 26
    constant K5_DELAY   : positive := FMUL_LAT + 2*FFMA_LAT;         -- 43
    constant K6_DELAY   : positive := FMUL_LAT + 3*FFMA_LAT;         -- 60
    constant CHAIN_DEPTH: positive := FMUL_LAT + 4*FFMA_LAT;         -- 77

    -- Absolute depths for module outputs
    -- y_out  = k arrival + chain + FFMA  = 360 + 77 + 17 = 454
    -- err_out= k arrival + chain + FMUL  = 360 + 77 +  9 = 446
    -- x_out  aligned to y_out: delay x_in/h by (454 - FADD) = 442, out at 454
    constant H_Y_DELAY  : positive := K_BLOCK_PIPE_LAT + CHAIN_DEPTH; -- 437 (for FMA/MUL)
    constant XH_DELAY   : positive := K_BLOCK_PIPE_LAT + CHAIN_DEPTH + FFMA_LAT - FADD_LAT; -- 442
    constant PIPELINE_DEPTH : positive := K_BLOCK_PIPE_LAT + CHAIN_DEPTH + FFMA_LAT; -- 454

    ---------------------------------------------------------------------------
    -- 5th-order Dormand-Prince b-coefficients (B2 = 0, k2 unused)
    ---------------------------------------------------------------------------
    constant B1 : STD_LOGIC_VECTOR(31 downto 0) := x"3DBAAAAB"; -- 35/384
    constant B3 : STD_LOGIC_VECTOR(31 downto 0) := x"3EE6024D"; -- 500/1113
    constant B4 : STD_LOGIC_VECTOR(31 downto 0) := x"3F26AAAB"; -- 125/192
    constant B5 : STD_LOGIC_VECTOR(31 downto 0) := x"BEA50E7E"; -- -2187/6784
    constant B6 : STD_LOGIC_VECTOR(31 downto 0) := x"3E061862"; -- 11/84

    -- Embedded error coefficients e_i = b5_i - b4_i (E2 = 0, k2 unused)
    constant E1 : STD_LOGIC_VECTOR(31 downto 0) := x"3AA1907F"; -- 71/57600
    constant E3 : STD_LOGIC_VECTOR(31 downto 0) := x"BB8B5AD3"; -- -71/16695
    constant E4 : STD_LOGIC_VECTOR(31 downto 0) := x"3D177777"; -- 71/1920
    constant E5 : STD_LOGIC_VECTOR(31 downto 0) := x"BD50568F"; -- -17253/339200
    constant E6 : STD_LOGIC_VECTOR(31 downto 0) := x"3D2BA454"; -- 22/525

    ---------------------------------------------------------------------------
    -- Shift-register pipeline type
    ---------------------------------------------------------------------------
    type slv32_pipe is array(natural range <>) of STD_LOGIC_VECTOR(31 downto 0);

    signal tvalid : std_logic := '1';

    ---------------------------------------------------------------------------
    -- k-values from k_block_pipe (all arrive simultaneously at depth 360)
    ---------------------------------------------------------------------------
    signal k1 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal k2 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- unused in chains
    signal k3 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal k4 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal k5 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal k6 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

    ---------------------------------------------------------------------------
    -- k alignment delay lines
    -- k3 delayed  9 cycles  → aligns with sol_mul1 / err_mul1
    -- k4 delayed 26 cycles  → aligns with sol_acc1 / err_acc1
    -- k5 delayed 43 cycles  → aligns with sol_acc2 / err_acc2
    -- k6 delayed 60 cycles  → aligns with sol_acc3 / err_acc3
    -- (delays are shared between solution and error chains)
    ---------------------------------------------------------------------------
    signal k3_dly : slv32_pipe(0 to K3_DELAY - 1) := (others => (others => '0'));
    signal k4_dly : slv32_pipe(0 to K4_DELAY - 1) := (others => (others => '0'));
    signal k5_dly : slv32_pipe(0 to K5_DELAY - 1) := (others => (others => '0'));
    signal k6_dly : slv32_pipe(0 to K6_DELAY - 1) := (others => (others => '0'));

    ---------------------------------------------------------------------------
    -- Input delay lines for h, y_in, x_in
    -- h_pipe  : 442 elements, tapped at index H_Y_DELAY-1 (436) for FMA/MUL
    --           and at XH_DELAY-1 (441) for the x_out adder
    -- y_pipe  : 437 elements, tapped at H_Y_DELAY-1 (436) for y_out FMA
    -- xin_pipe: 442 elements, tapped at XH_DELAY-1 (441) for x_out adder
    ---------------------------------------------------------------------------
    signal h_pipe   : slv32_pipe(0 to XH_DELAY   - 1) := (others => (others => '0'));
    signal y_pipe   : slv32_pipe(0 to H_Y_DELAY  - 1) := (others => (others => '0'));
    signal xin_pipe : slv32_pipe(0 to XH_DELAY   - 1) := (others => (others => '0'));

    ---------------------------------------------------------------------------
    -- Solution chain FPU outputs
    ---------------------------------------------------------------------------
    signal sol_mul1 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- B1*k1      @9
    signal sol_acc1 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- B3*k3+prev @26
    signal sol_acc2 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- B4*k4+prev @43
    signal sol_acc3 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- B5*k5+prev @60
    signal sol_acc4 : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- B6*k6+prev @77
    signal y_output : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- h*sum+y_in @94 chain-rel

    ---------------------------------------------------------------------------
    -- Error chain FPU outputs
    ---------------------------------------------------------------------------
    signal err_mul1   : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- E1*k1      @9
    signal err_acc1   : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- E3*k3+prev @26
    signal err_acc2   : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- E4*k4+prev @43
    signal err_acc3   : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- E5*k5+prev @60
    signal err_acc4   : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- E6*k6+prev @77
    signal err_result : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- h*err_sum  @86 chain-rel

    -- x_out
    signal x_output   : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

    -- k7 = f(x_output, y_output): FSAL k1 for the next step, valid at
    -- K_BLOCK_PIPE_LAT + CHAIN_DEPTH + FFMA_LAT + FUNC_LAT = 454+33 = 487
    signal k7_sig     : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

    -- valid propagation: k_block_pipe fires at 360; extend by FUNC_LAT
    -- so valid_out aligns with k7_sig becoming valid at 487.
    signal kb_valid   : std_logic := '0';
    signal k7_valid_sr: std_logic_vector(0 to FUNC_LAT - 1) := (others => '0');

begin

    ---------------------------------------------------------------------------
    -- DELAY LINE PROCESS
    ---------------------------------------------------------------------------
    delay_proc : process(clk)
    begin
        if rising_edge(clk) then

            -- k3 delay (9 cycles)
            k3_dly(0) <= k3;
            for i in 1 to K3_DELAY - 1 loop k3_dly(i) <= k3_dly(i-1); end loop;

            -- k4 delay (26 cycles)
            k4_dly(0) <= k4;
            for i in 1 to K4_DELAY - 1 loop k4_dly(i) <= k4_dly(i-1); end loop;

            -- k5 delay (43 cycles)
            k5_dly(0) <= k5;
            for i in 1 to K5_DELAY - 1 loop k5_dly(i) <= k5_dly(i-1); end loop;

            -- k6 delay (60 cycles)
            k6_dly(0) <= k6;
            for i in 1 to K6_DELAY - 1 loop k6_dly(i) <= k6_dly(i-1); end loop;

            -- h pipe (442 elements): tapped at 436 (for FMA/MUL) and 441 (for x_out ADD)
            h_pipe(0) <= h;
            for i in 1 to XH_DELAY - 1 loop h_pipe(i) <= h_pipe(i-1); end loop;

            -- y_in pipe (437 elements): tapped at 436 for y_out FMA
            y_pipe(0) <= y_in;
            for i in 1 to H_Y_DELAY - 1 loop y_pipe(i) <= y_pipe(i-1); end loop;

            -- x_in pipe (442 elements): tapped at 441 for x_out adder
            xin_pipe(0) <= x_in;
            for i in 1 to XH_DELAY - 1 loop xin_pipe(i) <= xin_pipe(i-1); end loop;

            -- Extend valid from k_block_pipe by FUNC_LAT more cycles so
            -- valid_out aligns with k7_sig (= f(x_out, y_out)) being ready.
            k7_valid_sr(0) <= kb_valid;
            for i in 1 to FUNC_LAT - 1 loop
                k7_valid_sr(i) <= k7_valid_sr(i - 1);
            end loop;

        end if;
    end process;

    ---------------------------------------------------------------------------
    -- k_block_pipe: computes k1-k6 with all outputs aligned at depth 360
    ---------------------------------------------------------------------------
    uut_kb : k_block_pipe port map (
        clk       => clk,
        x_in      => x_in,
        y_in      => y_in,
        h         => h,
        k1_in     => k1_in,
        fsal_en   => fsal_en,
        valid_in  => valid_in,
        valid_out => kb_valid,
        k1        => k1, k2 => k2, k3 => k3,
        k4        => k4, k5 => k5, k6 => k6);

    ---------------------------------------------------------------------------
    -- 5th-ORDER SOLUTION CHAIN
    -- y_out = y_in + h*(B1*k1 + B3*k3 + B4*k4 + B5*k5 + B6*k6)
    --
    -- All k values arrive simultaneously at absolute depth 360.
    -- k3-k6 are delayed so they meet their respective partial sum:
    --   k3_dly(8)  meets sol_mul1  at chain-relative depth  9
    --   k4_dly(25) meets sol_acc1  at chain-relative depth 26
    --   k5_dly(42) meets sol_acc2  at chain-relative depth 43
    --   k6_dly(59) meets sol_acc3  at chain-relative depth 60
    --   h_pipe(436) and y_pipe(436) meet sol_acc4 at chain-rel 77
    ---------------------------------------------------------------------------
    -- sol_mul1 = B1 * k1  (k1 direct, depth 360+0; sol_mul1 at 360+9)
    sol_m1 : fpu_mul port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => B1,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => k1,
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => sol_mul1);

    -- sol_acc1 = B3 * k3_d9 + sol_mul1  (both at depth 360+9)
    sol_a1 : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => B3,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open,
        s_axis_b_tdata  => k3_dly(K3_DELAY - 1),
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => sol_mul1,
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => sol_acc1);

    -- sol_acc2 = B4 * k4_d26 + sol_acc1  (both at depth 360+26)
    sol_a2 : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => B4,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open,
        s_axis_b_tdata  => k4_dly(K4_DELAY - 1),
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => sol_acc1,
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => sol_acc2);

    -- sol_acc3 = B5 * k5_d43 + sol_acc2  (both at depth 360+43)
    sol_a3 : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => B5,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open,
        s_axis_b_tdata  => k5_dly(K5_DELAY - 1),
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => sol_acc2,
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => sol_acc3);

    -- sol_acc4 = B6 * k6_d60 + sol_acc3  (both at depth 360+60)
    sol_a4 : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => B6,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open,
        s_axis_b_tdata  => k6_dly(K6_DELAY - 1),
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => sol_acc3,
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => sol_acc4);

    -- y_output = h_d437 * sol_acc4 + y_d437  (all three at absolute depth 437)
    sol_final : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open,
        s_axis_a_tdata  => h_pipe(H_Y_DELAY - 1),
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => sol_acc4,
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open,
        s_axis_c_tdata  => y_pipe(H_Y_DELAY - 1),
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => y_output);

    ---------------------------------------------------------------------------
    -- ERROR ESTIMATE CHAIN
    -- err = h * (E1*k1 + E3*k3 + E4*k4 + E5*k5 + E6*k6)
    -- Same k delays as solution chain (k3_dly..k6_dly are shared).
    ---------------------------------------------------------------------------
    -- err_mul1 = E1 * k1
    err_m1 : fpu_mul port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => E1,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => k1,
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => err_mul1);

    -- err_acc1 = E3 * k3_d9 + err_mul1
    err_a1 : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => E3,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open,
        s_axis_b_tdata  => k3_dly(K3_DELAY - 1),
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => err_mul1,
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => err_acc1);

    -- err_acc2 = E4 * k4_d26 + err_acc1
    err_a2 : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => E4,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open,
        s_axis_b_tdata  => k4_dly(K4_DELAY - 1),
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => err_acc1,
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => err_acc2);

    -- err_acc3 = E5 * k5_d43 + err_acc2
    err_a3 : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => E5,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open,
        s_axis_b_tdata  => k5_dly(K5_DELAY - 1),
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => err_acc2,
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => err_acc3);

    -- err_acc4 = E6 * k6_d60 + err_acc3
    err_a4 : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => E6,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open,
        s_axis_b_tdata  => k6_dly(K6_DELAY - 1),
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open, s_axis_c_tdata => err_acc3,
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => err_acc4);

    -- err_result = h_d437 * err_acc4  (both at absolute depth 437)
    err_final : fpu_mul port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open,
        s_axis_a_tdata  => h_pipe(H_Y_DELAY - 1),
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => err_acc4,
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => err_result);

    ---------------------------------------------------------------------------
    -- x_out = x_in_d442 + h_d442
    -- x_in and h delayed 442 cycles so x_out is valid at absolute depth 454,
    -- the same clock as y_out (454 = 442 + FADD_LAT).
    ---------------------------------------------------------------------------
    x_add : fpu_add port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open,
        s_axis_a_tdata  => xin_pipe(XH_DELAY - 1),
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open,
        s_axis_b_tdata  => h_pipe(XH_DELAY - 1),
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => x_output);

    ---------------------------------------------------------------------------
    -- k7 = f(x_out, y_out): FSAL feed-forward, valid at depth 487
    ---------------------------------------------------------------------------
    func_k7 : func port map (
        clk  => clk,
        x_in => x_output,
        y_in => y_output,
        f    => k7_sig);

    ---------------------------------------------------------------------------
    -- NaN fault detection
    -- IEEE 754 NaN: exponent bits all 1 (0xFF) AND mantissa non-zero.
    -- Checked on y_output, err_result, and k7_sig.
    ---------------------------------------------------------------------------
    fault <= '1' when
        (y_output(30 downto 23)  = "11111111" and y_output(22 downto 0)  /= (22 downto 0 => '0')) or
        (err_result(30 downto 23)= "11111111" and err_result(22 downto 0) /= (22 downto 0 => '0')) or
        (k7_sig(30 downto 23)    = "11111111" and k7_sig(22 downto 0)     /= (22 downto 0 => '0'))
        else '0';

    ---------------------------------------------------------------------------
    -- Output assignments
    ---------------------------------------------------------------------------
    valid_out <= k7_valid_sr(FUNC_LAT - 1);
    k7_out    <= k7_sig;
    x_out     <= x_output;
    y_out     <= y_output;
    err_out   <= err_result;

end Behavioral;
