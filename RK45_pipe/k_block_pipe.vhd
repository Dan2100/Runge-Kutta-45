----------------------------------------------------------------------------------
-- k_block_pipe.vhd
--
-- Properly Pipelined Dormand-Prince RK45 K-Block
--
-- Unlike k_block.vhd (which holds inputs stable for a fixed 512-cycle wait
-- to let all paths settle), this module inserts registered delay lines at
-- every inter-stage dependency so that inputs and their dependent k-values
-- always arrive at each FPU simultaneously.
--
-- Result: a new (x_in, y_in, h) triple may be accepted every clock cycle.
-- k1-k6 outputs for that input emerge PIPELINE_DEPTH = 360 cycles later,
-- all aligned to the same clock cycle.
--
-- FPU latencies read from .xci IP configuration:
--   fpu_mul   : FMUL_LAT = 9  cycles
--   fpu_add   : FADD_LAT = 12 cycles
--   fpu_sub   : FSUB_LAT = 12 cycles
--   fpu_fused : FFMA_LAT = 17 cycles
--
-- Derived constants (see comment block in architecture):
--   FUNC_LAT       = FSUB + FMUL + FADD = 33  (func pipeline depth)
--   PIPELINE_DEPTH = 6*FUNC + FMUL + 9*FFMA  = 360
--
-- To use this block in place of k_block, instantiate k_block_pipe and update
-- COMPUTE_WAIT in Top.vhd to PIPELINE_DEPTH (360) or a small margin above it.
-- k_block_pipe can also be used in a streaming mode where new inputs are
-- pushed every cycle; in that case no wait counter is needed at all.
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity k_block_pipe is
    port (
        clk      : in  std_logic;
        x_in     : in  STD_LOGIC_VECTOR(31 downto 0);
        y_in     : in  STD_LOGIC_VECTOR(31 downto 0);
        h        : in  STD_LOGIC_VECTOR(31 downto 0);
        -- FSAL: when fsal_en='1', k1_in (k7 from previous step) is used
        -- directly as k1, bypassing the func f1 computation.
        k1_in    : in  STD_LOGIC_VECTOR(31 downto 0);
        fsal_en  : in  std_logic;
        -- Streaming valid token: valid_out pulses PIPELINE_DEPTH cycles
        -- after each valid_in pulse, indicating all k outputs are stable.
        valid_in : in  std_logic;
        valid_out: out std_logic;
        k1       : out STD_LOGIC_VECTOR(31 downto 0);
        k2       : out STD_LOGIC_VECTOR(31 downto 0);
        k3       : out STD_LOGIC_VECTOR(31 downto 0);
        k4       : out STD_LOGIC_VECTOR(31 downto 0);
        k5       : out STD_LOGIC_VECTOR(31 downto 0);
        k6       : out STD_LOGIC_VECTOR(31 downto 0)
    );
end k_block_pipe;

architecture Behavioral of k_block_pipe is

    ---------------------------------------------------------------------------
    -- Component declarations
    ---------------------------------------------------------------------------
    component func is
        port (
            clk  : in  std_logic;
            x_in : in  STD_LOGIC_VECTOR(31 downto 0);
            y_in : in  STD_LOGIC_VECTOR(31 downto 0);
            f    : out STD_LOGIC_VECTOR(31 downto 0));
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

    ---------------------------------------------------------------------------
    -- Pipeline latency constants — must match .xci IP configuration
    ---------------------------------------------------------------------------
    constant FMUL_LAT : positive := 9;
    constant FADD_LAT : positive := 12;
    constant FSUB_LAT : positive := 12;
    constant FFMA_LAT : positive := 17;
    -- func pipeline depth  = sub -> mul -> add chained
    constant FUNC_LAT : positive := FSUB_LAT + FMUL_LAT + FADD_LAT;  -- 33

    ---------------------------------------------------------------------------
    -- k-stage absolute pipeline depths
    -- D_Kn = clock cycle (relative to input) at which k_n first becomes valid.
    --
    --   D_K1 = FUNC_LAT                              =  33
    --   D_K2 = 2*FUNC + FMUL + FFMA                 =  92
    --   D_K3 = D_K2 + 2*FFMA + FUNC                 = 159
    --   D_K4 = D_K3 + 2*FFMA + FUNC                 = 226
    --   D_K5 = D_K4 + 2*FFMA + FUNC                 = 293
    --   D_K6 = D_K5 + 2*FFMA + FUNC                 = 360
    ---------------------------------------------------------------------------
    constant D_K1 : positive := FUNC_LAT;
    constant D_K2 : positive := 2*FUNC_LAT + FMUL_LAT + FFMA_LAT;
    constant D_K3 : positive := D_K2 + 2*FFMA_LAT + FUNC_LAT;
    constant D_K4 : positive := D_K3 + 2*FFMA_LAT + FUNC_LAT;
    constant D_K5 : positive := D_K4 + 2*FFMA_LAT + FUNC_LAT;
    constant D_K6 : positive := D_K5 + 2*FFMA_LAT + FUNC_LAT;

    -- Total pipeline depth.  Set COMPUTE_WAIT >= PIPELINE_DEPTH in Top.vhd.
    constant PIPELINE_DEPTH : positive := D_K6;  -- 360

    ---------------------------------------------------------------------------
    -- Stage input alignment delays
    --
    -- For stage n, h, y_in, and x_n_raw (the output of the fpu_fused that
    -- computes C_n*h + x_in) must all arrive at func_n at the same time:
    --   depth = D_Kn - FUNC_LAT
    --
    -- x_n_raw is produced by one fpu_fused, so it is already at depth FFMA_LAT.
    -- The extra delay needed to advance it to D_Kn - FUNC_LAT is:
    --   S_n_ALIGN = (D_Kn - FUNC_LAT) - FFMA_LAT
    --
    -- h and y_in start at depth 0, so they need delay = D_Kn - FUNC_LAT:
    --   S_n_ALIGN = D_Kn - FUNC_LAT - FFMA_LAT  for x
    --             = D_Kn - FUNC_LAT              for h/y_in (use h_pipe/y_pipe tapped at that index)
    --
    -- For h_pipe and y_pipe, which are tapped at S_n_ALIGN (as an index):
    --   h_pipe(S_n_ALIGN - 1) = h delayed by S_n_ALIGN cycles.
    --   Using the pipe index as (D_Kn - FUNC_LAT - 1) makes the tap
    --   at exactly D_Kn - FUNC_LAT cycles of delay.
    --
    -- S2_ALIGN = FUNC_LAT + FMUL_LAT    =  42
    -- S3_ALIGN = D_K2 + FFMA_LAT        = 109
    -- S4_ALIGN = D_K3 + FFMA_LAT        = 176
    -- S5_ALIGN = D_K4 + FFMA_LAT        = 243
    -- S6_ALIGN = D_K5 + FFMA_LAT        = 310
    ---------------------------------------------------------------------------
    constant S2_ALIGN : positive := FUNC_LAT + FMUL_LAT;
    constant S3_ALIGN : positive := D_K2 + FFMA_LAT;
    constant S4_ALIGN : positive := D_K3 + FFMA_LAT;
    constant S5_ALIGN : positive := D_K4 + FFMA_LAT;
    constant S6_ALIGN : positive := D_K5 + FFMA_LAT;

    ---------------------------------------------------------------------------
    -- s_mul1 alignment: A_n1 * k1 raw is at depth FUNC_LAT + FMUL_LAT = 42.
    -- It must be aligned to D_K2 (= 92) to feed the first accumulator of each
    -- stage (which uses k2 as the other input, and k2 arrives at D_K2).
    --
    --   MUL1_ALIGN = D_K2 - (FUNC_LAT + FMUL_LAT) = 50
    ---------------------------------------------------------------------------
    constant MUL1_ALIGN : positive := D_K2 - (FUNC_LAT + FMUL_LAT);  -- 50

    ---------------------------------------------------------------------------
    -- Inter-accumulator delay: each consecutive acc stage feeds into the next
    -- with an inter-stage delay of:
    --   ACC_INTER = FUNC_LAT + FFMA_LAT = 50
    -- (= D_K_{n+1} - D_K_n - FFMA_LAT, constant for all stages)
    ---------------------------------------------------------------------------
    constant ACC_INTER : positive := FUNC_LAT + FFMA_LAT;  -- 50

    ---------------------------------------------------------------------------
    -- Output alignment: bring k1-k5 from their native depths to D_K6 = 360
    --   K1_ALIGN = 327,  K2_ALIGN = 268,  K3_ALIGN = 201
    --   K4_ALIGN = 134,  K5_ALIGN =  67,  k6 needs no extra delay
    ---------------------------------------------------------------------------
    constant K1_ALIGN : positive := D_K6 - D_K1;  -- 327
    constant K2_ALIGN : positive := D_K6 - D_K2;  -- 268
    constant K3_ALIGN : positive := D_K6 - D_K3;  -- 201
    constant K4_ALIGN : positive := D_K6 - D_K4;  -- 134
    constant K5_ALIGN : positive := D_K6 - D_K5;  --  67

    ---------------------------------------------------------------------------
    -- Shift-register type for delay lines
    ---------------------------------------------------------------------------
    type slv32_pipe is array(natural range <>) of STD_LOGIC_VECTOR(31 downto 0);

    -- AXI-Stream tvalid: held '1' (streaming, no backpressure)
    signal tvalid : std_logic := '1';

    ---------------------------------------------------------------------------
    -- Dormand-Prince Butcher tableau constants (IEEE 754 single precision)
    ---------------------------------------------------------------------------
    -- c-values (node offsets)
    constant C2 : STD_LOGIC_VECTOR(31 downto 0) := x"3E4CCCCD"; -- 1/5
    constant C3 : STD_LOGIC_VECTOR(31 downto 0) := x"3E99999A"; -- 3/10
    constant C4 : STD_LOGIC_VECTOR(31 downto 0) := x"3F4CCCCD"; -- 4/5
    constant C5 : STD_LOGIC_VECTOR(31 downto 0) := x"3F638E39"; -- 8/9
    -- a-values (tableau entries)
    constant A21 : STD_LOGIC_VECTOR(31 downto 0) := x"3E4CCCCD"; --  1/5
    constant A31 : STD_LOGIC_VECTOR(31 downto 0) := x"3D99999A"; --  3/40
    constant A32 : STD_LOGIC_VECTOR(31 downto 0) := x"3E666666"; --  9/40
    constant A41 : STD_LOGIC_VECTOR(31 downto 0) := x"3F7A4FA5"; --  44/45
    constant A42 : STD_LOGIC_VECTOR(31 downto 0) := x"C06EEEEF"; -- -56/15
    constant A43 : STD_LOGIC_VECTOR(31 downto 0) := x"40638E39"; --  32/9
    constant A51 : STD_LOGIC_VECTOR(31 downto 0) := x"403CF760"; --  19372/6561
    constant A52 : STD_LOGIC_VECTOR(31 downto 0) := x"C139885F"; -- -25360/2187
    constant A53 : STD_LOGIC_VECTOR(31 downto 0) := x"411D2A92"; --  64448/6561
    constant A54 : STD_LOGIC_VECTOR(31 downto 0) := x"BE94E4F6"; -- -212/729
    constant A61 : STD_LOGIC_VECTOR(31 downto 0) := x"40362960"; --  9017/3168
    constant A62 : STD_LOGIC_VECTOR(31 downto 0) := x"C12C1F08"; -- -355/33
    constant A63 : STD_LOGIC_VECTOR(31 downto 0) := x"410E80B5"; --  46732/5247
    constant A64 : STD_LOGIC_VECTOR(31 downto 0) := x"3E8E8BA3"; --  49/176
    constant A65 : STD_LOGIC_VECTOR(31 downto 0) := x"BE8C0C4C"; -- -5103/18656

    ---------------------------------------------------------------------------
    -- FPU raw output signals (direct wires from IP instances)
    ---------------------------------------------------------------------------
    -- Stage 1: K11_func is the raw func output; K11_mux selects between
    -- K11_func (normal mode) and the FSAL-delayed k1_in (FSAL mode).
    signal K11_func  : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal K11_mux   : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');

    -- Stage 2: x2_raw now computed at depth S2_ALIGN+FFMA_LAT=59 from
    -- x_in_pipe tap (see consolidated delay line below).
    signal x2_raw    : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- @59
    signal s2_mul1   : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- A21*k1 @42
    signal y2_raw    : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- y2      @59
    signal K22       : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- k2      @92

    -- Stage 3
    signal x3_raw    : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- @126
    signal s3_mul1_r : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- A31*k1 @42
    signal s3_acc1   : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- @109
    signal y3_raw    : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- @126
    signal K33       : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- @159

    -- Stage 4
    signal x4_raw    : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- @193
    signal s4_mul1_r : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- A41*k1 @42
    signal s4_acc1   : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- @109
    signal s4_acc2   : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- @176
    signal y4_raw    : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- @193
    signal K44       : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- @226

    -- Stage 5
    signal x5_raw    : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- @260
    signal s5_mul1_r : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- A51*k1 @42
    signal s5_acc1   : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- @109
    signal s5_acc2   : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- @176
    signal s5_acc3   : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- @243
    signal y5_raw    : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- @260
    signal K55       : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- @293

    -- Stage 6
    signal x6_raw    : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- @327
    signal s6_mul1_r : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- A61*k1 @42
    signal s6_acc1   : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- @109
    signal s6_acc2   : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- @176
    signal s6_acc3   : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- @243
    signal s6_acc4   : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- @310
    signal y6_raw    : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- @327
    signal K66       : STD_LOGIC_VECTOR(31 downto 0) := (others => '0'); -- @360

    ---------------------------------------------------------------------------
    -- Delay line shift registers
    --
    -- Naming convention: pipe(0) is loaded from the source signal each clock.
    -- pipe(N-1) holds the value from N cycles ago.
    -- A pipe of declared size N provides N cycles of delay.
    ---------------------------------------------------------------------------

    -- h, y_in, x_in: one long pipe each, length S6_ALIGN=310.
    -- All three are tapped at S2..S6 alignment indices.
    -- Consolidating x_in into a single shared pipe replaces the five
    -- previous separate x_n_raw alignment pipes (x2_pipe..x6_pipe),
    -- saving ~570 flip-flops at a cost of five later fpu_fused evaluations.
    signal h_pipe    : slv32_pipe(0 to S6_ALIGN - 1) := (others => (others => '0'));
    signal y_pipe    : slv32_pipe(0 to S6_ALIGN - 1) := (others => (others => '0'));
    signal x_in_pipe : slv32_pipe(0 to S6_ALIGN - 1) := (others => (others => '0'));

    -- FSAL delay line: k1_in (k7 of previous step) shifted by FUNC_LAT=33
    -- cycles so it arrives at the same time as K11_func would have.
    signal k1_fsal_pipe : slv32_pipe(0 to FUNC_LAT - 1) := (others => (others => '0'));

    -- Valid streaming token: shift register of length PIPELINE_DEPTH.
    -- valid_sr(PIPELINE_DEPTH-1) goes high exactly when k1-k6 are all valid.
    signal valid_sr  : std_logic_vector(0 to PIPELINE_DEPTH - 1) := (others => '0');

    -- s_n_mul1 delay: A_n1*k1 raw (at depth 42) → aligned to D_K2 (92)
    -- All four have identical delay = MUL1_ALIGN = 50
    signal s3_m1_pipe : slv32_pipe(0 to MUL1_ALIGN - 1) := (others => (others => '0'));
    signal s4_m1_pipe : slv32_pipe(0 to MUL1_ALIGN - 1) := (others => (others => '0'));
    signal s5_m1_pipe : slv32_pipe(0 to MUL1_ALIGN - 1) := (others => (others => '0'));
    signal s6_m1_pipe : slv32_pipe(0 to MUL1_ALIGN - 1) := (others => (others => '0'));

    -- Accumulator inter-stage delay pipes (ACC_INTER = 50 cycles each)
    -- s4: acc1 (109) → delayed to 159 to meet k3
    signal s4_acc1_pipe : slv32_pipe(0 to ACC_INTER - 1) := (others => (others => '0'));
    -- s5: acc1→acc2 (109→159), acc2→acc3 (176→226)
    signal s5_acc1_pipe : slv32_pipe(0 to ACC_INTER - 1) := (others => (others => '0'));
    signal s5_acc2_pipe : slv32_pipe(0 to ACC_INTER - 1) := (others => (others => '0'));
    -- s6: acc1→acc2 (109→159), acc2→acc3 (176→226), acc3→acc4 (243→293)
    signal s6_acc1_pipe : slv32_pipe(0 to ACC_INTER - 1) := (others => (others => '0'));
    signal s6_acc2_pipe : slv32_pipe(0 to ACC_INTER - 1) := (others => (others => '0'));
    signal s6_acc3_pipe : slv32_pipe(0 to ACC_INTER - 1) := (others => (others => '0'));

    -- Output alignment: bring k1-k5 to D_K6 = 360
    signal k1_pipe   : slv32_pipe(0 to K1_ALIGN - 1) := (others => (others => '0'));
    signal k2_pipe   : slv32_pipe(0 to K2_ALIGN - 1) := (others => (others => '0'));
    signal k3_pipe   : slv32_pipe(0 to K3_ALIGN - 1) := (others => (others => '0'));
    signal k4_pipe   : slv32_pipe(0 to K4_ALIGN - 1) := (others => (others => '0'));
    signal k5_pipe   : slv32_pipe(0 to K5_ALIGN - 1) := (others => (others => '0'));

begin

    ---------------------------------------------------------------------------
    -- DELAY LINE PROCESS
    -- Advances every shift register by one position on each rising clock edge.
    -- Xilinx synthesis infers SRL primitives for long chains automatically.
    ---------------------------------------------------------------------------
    delay_proc : process(clk)
    begin
        if rising_edge(clk) then

            -- h, y_in, x_in: shared tapped delay lines (length S6_ALIGN=310).
            -- x_in_pipe replaces the five previous x_n_raw alignment pipes.
            h_pipe(0)    <= h;
            y_pipe(0)    <= y_in;
            x_in_pipe(0) <= x_in;
            for i in 1 to S6_ALIGN - 1 loop
                h_pipe(i)    <= h_pipe(i - 1);
                y_pipe(i)    <= y_pipe(i - 1);
                x_in_pipe(i) <= x_in_pipe(i - 1);
            end loop;

            -- FSAL: delay k1_in by FUNC_LAT=33 cycles so it aligns with
            -- the cycle at which K11_func would become valid.
            k1_fsal_pipe(0) <= k1_in;
            for i in 1 to FUNC_LAT - 1 loop
                k1_fsal_pipe(i) <= k1_fsal_pipe(i - 1);
            end loop;

            -- Valid streaming token: propagate one bit through PIPELINE_DEPTH stages.
            valid_sr(0) <= valid_in;
            for i in 1 to PIPELINE_DEPTH - 1 loop
                valid_sr(i) <= valid_sr(i - 1);
            end loop;

            -- s_n_mul1 alignment (raw @42 → D_K2 @92, delay = 50)
            s3_m1_pipe(0) <= s3_mul1_r;
            s4_m1_pipe(0) <= s4_mul1_r;
            s5_m1_pipe(0) <= s5_mul1_r;
            s6_m1_pipe(0) <= s6_mul1_r;
            for i in 1 to MUL1_ALIGN - 1 loop
                s3_m1_pipe(i) <= s3_m1_pipe(i-1);
                s4_m1_pipe(i) <= s4_m1_pipe(i-1);
                s5_m1_pipe(i) <= s5_m1_pipe(i-1);
                s6_m1_pipe(i) <= s6_m1_pipe(i-1);
            end loop;

            -- Accumulator inter-stage pipes (all 50 cycles)
            s4_acc1_pipe(0) <= s4_acc1;
            s5_acc1_pipe(0) <= s5_acc1;
            s5_acc2_pipe(0) <= s5_acc2;
            s6_acc1_pipe(0) <= s6_acc1;
            s6_acc2_pipe(0) <= s6_acc2;
            s6_acc3_pipe(0) <= s6_acc3;
            for i in 1 to ACC_INTER - 1 loop
                s4_acc1_pipe(i) <= s4_acc1_pipe(i-1);
                s5_acc1_pipe(i) <= s5_acc1_pipe(i-1);
                s5_acc2_pipe(i) <= s5_acc2_pipe(i-1);
                s6_acc1_pipe(i) <= s6_acc1_pipe(i-1);
                s6_acc2_pipe(i) <= s6_acc2_pipe(i-1);
                s6_acc3_pipe(i) <= s6_acc3_pipe(i-1);
            end loop;

            -- Output alignment pipes
            k1_pipe(0) <= K11_mux;
            for i in 1 to K1_ALIGN - 1 loop k1_pipe(i) <= k1_pipe(i-1); end loop;

            k2_pipe(0) <= K22;
            for i in 1 to K2_ALIGN - 1 loop k2_pipe(i) <= k2_pipe(i-1); end loop;

            k3_pipe(0) <= K33;
            for i in 1 to K3_ALIGN - 1 loop k3_pipe(i) <= k3_pipe(i-1); end loop;

            k4_pipe(0) <= K44;
            for i in 1 to K4_ALIGN - 1 loop k4_pipe(i) <= k4_pipe(i-1); end loop;

            k5_pipe(0) <= K55;
            for i in 1 to K5_ALIGN - 1 loop k5_pipe(i) <= k5_pipe(i-1); end loop;

        end if;
    end process;

    ---------------------------------------------------------------------------
    -- STAGE 1:  k1 = f(x_in, y_in)                          valid @ 33
    -- FSAL mux: when fsal_en='1', k1_fsal_pipe(FUNC_LAT-1) — the k7 value
    -- from the previous step delayed to align with cycle 33 — is used
    -- in place of K11_func, saving one func evaluation per step.
    ---------------------------------------------------------------------------
    f1 : func port map (clk => clk, x_in => x_in, y_in => y_in, f => K11_func);
    K11_mux <= k1_fsal_pipe(FUNC_LAT - 1) when fsal_en = '1' else K11_func;
    valid_out <= valid_sr(PIPELINE_DEPTH - 1);

    ---------------------------------------------------------------------------
    -- STAGE 2:  k2 = f(x + C2*h,  y + h*A21*k1)            valid @ 92
    --
    --  x2_raw   = C2*h + x_in                                      @  17
    --  s2_mul1  = A21 * k1                                          @  42
    --  y2_raw   = h_d42 * s2_mul1 + y_d42                          @  59
    --  func2 inputs (x2_pipe(41), y2_raw) both arrive              @  59
    ---------------------------------------------------------------------------
    -- x2_raw = C2*h_d42 + x_in_d42  — both inputs tapped from shared pipes
    -- at index S2_ALIGN-1=41.  Output x2_raw valid at 42+FFMA=59.
    s2_x : fpu_fused port map (
        aclk                 => clk,
        s_axis_a_tvalid      => tvalid, s_axis_a_tready => open,
        s_axis_a_tdata       => C2,
        s_axis_b_tvalid      => tvalid, s_axis_b_tready => open,
        s_axis_b_tdata       => h_pipe(S2_ALIGN - 1),
        s_axis_c_tvalid      => tvalid, s_axis_c_tready => open,
        s_axis_c_tdata       => x_in_pipe(S2_ALIGN - 1),
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => x2_raw);

    -- s2_mul1 = A21 * K11_mux
    s2_m1 : fpu_mul port map (
        aclk                 => clk,
        s_axis_a_tvalid      => tvalid, s_axis_a_tready => open,
        s_axis_a_tdata       => A21,
        s_axis_b_tvalid      => tvalid, s_axis_b_tready => open,
        s_axis_b_tdata       => K11_mux,
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => s2_mul1);

    -- y2 = h_pipe(41) * s2_mul1 + y_pipe(41)  — all at depth 42, output @59
    s2_y : fpu_fused port map (
        aclk                 => clk,
        s_axis_a_tvalid      => tvalid, s_axis_a_tready => open,
        s_axis_a_tdata       => h_pipe(S2_ALIGN - 1),
        s_axis_b_tvalid      => tvalid, s_axis_b_tready => open,
        s_axis_b_tdata       => s2_mul1,
        s_axis_c_tvalid      => tvalid, s_axis_c_tready => open,
        s_axis_c_tdata       => y_pipe(S2_ALIGN - 1),
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => y2_raw);

    -- k2 = f(x2_raw, y2_raw)  both at depth 59
    f2 : func port map (
        clk  => clk,
        x_in => x2_raw,
        y_in => y2_raw,
        f    => K22);

    ---------------------------------------------------------------------------
    -- STAGE 3:  k3 = f(x + C3*h,  y + h*(A31*k1 + A32*k2)) valid @ 159
    --
    --  x3_raw     = C3*h + x_in                                    @  17
    --  s3_mul1_r  = A31 * k1                                       @  42
    --  s3_m1_pipe(49) aligned to D_K2                              @  92
    --  s3_acc1    = A32*k2 + s3_mul1_aligned                       @ 109
    --  y3_raw     = h_d109 * s3_acc1 + y_d109                      @ 126
    --  func3 inputs (x3_pipe(108), y3_raw) both                    @ 126
    ---------------------------------------------------------------------------
    -- x3_raw = C3*h_d109 + x_in_d109  → valid at S3_ALIGN+FFMA = 126
    s3_x : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => C3,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open,
        s_axis_b_tdata  => h_pipe(S3_ALIGN - 1),
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open,
        s_axis_c_tdata  => x_in_pipe(S3_ALIGN - 1),
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => x3_raw);

    s3_m1 : fpu_mul port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A31,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K11_mux,
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => s3_mul1_r);

    -- s3_acc1 = A32*k2 + s3_mul1_aligned
    -- k2 (K22) arrives at D_K2=92; s3_m1_pipe(49) also at 92
    s3_a1 : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A32,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K22,
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open,
        s_axis_c_tdata  => s3_m1_pipe(MUL1_ALIGN - 1),
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => s3_acc1);

    -- y3 = h_d109 * s3_acc1 + y_d109
    s3_y : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open,
        s_axis_a_tdata  => h_pipe(S3_ALIGN - 1),
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => s3_acc1,
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open,
        s_axis_c_tdata  => y_pipe(S3_ALIGN - 1),
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => y3_raw);

    f3 : func port map (
        clk  => clk,
        x_in => x3_raw,
        y_in => y3_raw,
        f    => K33);

    ---------------------------------------------------------------------------
    -- STAGE 4:  k4 = f(x + C4*h,  y + h*(A41*k1+A42*k2+A43*k3))  valid @ 226
    --
    --  s4_mul1_r  = A41*k1                                         @  42
    --  s4_m1_pipe(49) aligned to D_K2                              @  92
    --  s4_acc1    = A42*k2 + s4_mul1_aligned                       @ 109
    --  s4_acc1_pipe(49) aligned to D_K3                            @ 159
    --  s4_acc2    = A43*k3 + s4_acc1_delayed                       @ 176
    --  y4_raw     = h_d176 * s4_acc2 + y_d176                      @ 193
    --  func4 inputs at                                              @ 193
    ---------------------------------------------------------------------------
    -- x4_raw = C4*h_d176 + x_in_d176  → valid at S4_ALIGN+FFMA = 193
    s4_x : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => C4,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open,
        s_axis_b_tdata  => h_pipe(S4_ALIGN - 1),
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open,
        s_axis_c_tdata  => x_in_pipe(S4_ALIGN - 1),
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => x4_raw);

    s4_m1 : fpu_mul port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A41,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K11_mux,
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => s4_mul1_r);

    -- s4_acc1 = A42*k2 + s4_mul1_aligned  (both at D_K2=92)
    s4_a1 : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A42,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K22,
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open,
        s_axis_c_tdata  => s4_m1_pipe(MUL1_ALIGN - 1),
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => s4_acc1);

    -- s4_acc2 = A43*k3 + s4_acc1_delayed  (k3 at D_K3=159, s4_acc1_pipe(49) at 159)
    s4_a2 : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A43,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K33,
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open,
        s_axis_c_tdata  => s4_acc1_pipe(ACC_INTER - 1),
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => s4_acc2);

    -- y4 = h_d176 * s4_acc2 + y_d176
    s4_y : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open,
        s_axis_a_tdata  => h_pipe(S4_ALIGN - 1),
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => s4_acc2,
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open,
        s_axis_c_tdata  => y_pipe(S4_ALIGN - 1),
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => y4_raw);

    f4 : func port map (
        clk  => clk,
        x_in => x4_raw,
        y_in => y4_raw,
        f    => K44);

    ---------------------------------------------------------------------------
    -- STAGE 5:  k5 = f(x + C5*h,  y + h*(A51*k1+…+A54*k4))  valid @ 293
    --
    --  s5_acc1  = A52*k2 + s5_mul1_aligned                        @ 109
    --  s5_acc2  = A53*k3 + s5_acc1_delayed                        @ 176
    --  s5_acc3  = A54*k4 + s5_acc2_delayed                        @ 243
    --  y5_raw   = h_d243 * s5_acc3 + y_d243                       @ 260
    --  func5 inputs at                                             @ 260
    ---------------------------------------------------------------------------
    -- x5_raw = C5*h_d243 + x_in_d243  → valid at S5_ALIGN+FFMA = 260
    s5_x : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => C5,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open,
        s_axis_b_tdata  => h_pipe(S5_ALIGN - 1),
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open,
        s_axis_c_tdata  => x_in_pipe(S5_ALIGN - 1),
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => x5_raw);

    s5_m1 : fpu_mul port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A51,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K11_mux,
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => s5_mul1_r);

    s5_a1 : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A52,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K22,
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open,
        s_axis_c_tdata  => s5_m1_pipe(MUL1_ALIGN - 1),
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => s5_acc1);

    -- s5_acc2 = A53*k3 + s5_acc1_delayed  (k3 at 159, s5_acc1_pipe(49) at 159)
    s5_a2 : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A53,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K33,
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open,
        s_axis_c_tdata  => s5_acc1_pipe(ACC_INTER - 1),
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => s5_acc2);

    -- s5_acc3 = A54*k4 + s5_acc2_delayed  (k4 at 226, s5_acc2_pipe(49) at 226)
    s5_a3 : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A54,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K44,
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open,
        s_axis_c_tdata  => s5_acc2_pipe(ACC_INTER - 1),
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => s5_acc3);

    s5_y : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open,
        s_axis_a_tdata  => h_pipe(S5_ALIGN - 1),
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => s5_acc3,
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open,
        s_axis_c_tdata  => y_pipe(S5_ALIGN - 1),
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => y5_raw);

    f5 : func port map (
        clk  => clk,
        x_in => x5_raw,
        y_in => y5_raw,
        f    => K55);

    ---------------------------------------------------------------------------
    -- STAGE 6:  k6 = f(x + h,  y + h*(A61*k1+…+A65*k5))   valid @ 360
    --  c6 = 1.0 so x6 = 1.0*h + x_in (still uses fpu_fused)
    --
    --  s6_acc1  = A62*k2 + s6_mul1_aligned                        @ 109
    --  s6_acc2  = A63*k3 + s6_acc1_delayed                        @ 176
    --  s6_acc3  = A64*k4 + s6_acc2_delayed                        @ 243
    --  s6_acc4  = A65*k5 + s6_acc3_delayed                        @ 310
    --  y6_raw   = h_d310 * s6_acc4 + y_d310                       @ 327
    --  func6 inputs at                                             @ 327
    ---------------------------------------------------------------------------
    -- x6_raw = 1.0*h_d310 + x_in_d310  → valid at S6_ALIGN+FFMA = 327  (c6=1)
    s6_x : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open,
        s_axis_a_tdata  => x"3F800000",  -- 1.0 (c6 = 1)
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open,
        s_axis_b_tdata  => h_pipe(S6_ALIGN - 1),
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open,
        s_axis_c_tdata  => x_in_pipe(S6_ALIGN - 1),
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => x6_raw);

    s6_m1 : fpu_mul port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A61,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K11_mux,
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => s6_mul1_r);

    s6_a1 : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A62,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K22,
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open,
        s_axis_c_tdata  => s6_m1_pipe(MUL1_ALIGN - 1),
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => s6_acc1);

    -- s6_acc2 = A63*k3 + s6_acc1_delayed  (k3 at 159, s6_acc1_pipe(49) at 159)
    s6_a2 : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A63,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K33,
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open,
        s_axis_c_tdata  => s6_acc1_pipe(ACC_INTER - 1),
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => s6_acc2);

    -- s6_acc3 = A64*k4 + s6_acc2_delayed  (k4 at 226, s6_acc2_pipe(49) at 226)
    s6_a3 : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A64,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K44,
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open,
        s_axis_c_tdata  => s6_acc2_pipe(ACC_INTER - 1),
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => s6_acc3);

    -- s6_acc4 = A65*k5 + s6_acc3_delayed  (k5 at 293, s6_acc3_pipe(49) at 293)
    s6_a4 : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open, s_axis_a_tdata => A65,
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => K55,
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open,
        s_axis_c_tdata  => s6_acc3_pipe(ACC_INTER - 1),
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => s6_acc4);

    -- y6 = h_d310 * s6_acc4 + y_d310
    s6_y : fpu_fused port map (
        aclk => clk,
        s_axis_a_tvalid => tvalid, s_axis_a_tready => open,
        s_axis_a_tdata  => h_pipe(S6_ALIGN - 1),
        s_axis_b_tvalid => tvalid, s_axis_b_tready => open, s_axis_b_tdata => s6_acc4,
        s_axis_c_tvalid => tvalid, s_axis_c_tready => open,
        s_axis_c_tdata  => y_pipe(S6_ALIGN - 1),
        m_axis_result_tvalid => open, m_axis_result_tready => '1',
        m_axis_result_tdata  => y6_raw);

    f6 : func port map (
        clk  => clk,
        x_in => x6_raw,
        y_in => y6_raw,
        f    => K66);

    ---------------------------------------------------------------------------
    -- OUTPUT ASSIGNMENTS
    -- k1-k5 are delayed by their respective alignment pipes to match k6 @ 360.
    -- k6 (K66) is already at PIPELINE_DEPTH — output directly.
    ---------------------------------------------------------------------------
    k1 <= k1_pipe(K1_ALIGN - 1);  -- K11 @33  + 327 delay = 360
    k2 <= k2_pipe(K2_ALIGN - 1);  -- K22 @92  + 268 delay = 360
    k3 <= k3_pipe(K3_ALIGN - 1);  -- K33 @159 + 201 delay = 360
    k4 <= k4_pipe(K4_ALIGN - 1);  -- K44 @226 + 134 delay = 360
    k5 <= k5_pipe(K5_ALIGN - 1);  -- K55 @293 +  67 delay = 360
    k6 <= K66;                     -- K66 @360, no extra delay needed

end Behavioral;
