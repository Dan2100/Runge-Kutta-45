----------------------------------------------------------------------------------
-- Adaptive Step Size Controller for Dormand-Prince RK45
-- Mixed absolute/relative tolerance: eff_tol = max(atol, rtol * |y|)
--
-- The relative term rtol * |y| is approximated by exponent addition only
-- (mantissa treated as 1.0). This is within a factor of 2 of the true IEEE
-- 754 product, which is sufficient for adaptive step-size decisions.
--
-- Compares |err| against eff_tol and adjusts h by halving/doubling:
--   |err| > eff_tol        → reject, h_new = h/2
--   |err| < eff_tol/32     → accept, h_new = h*2  (aggressive growth)
--   otherwise              → accept, h_new = h
--
-- Uses IEEE 754 exponent manipulation (no FPU needed, fully combinatorial).
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity step_ctrl is
Port (
    err_in   : in  STD_LOGIC_VECTOR(31 downto 0);
    h_in     : in  STD_LOGIC_VECTOR(31 downto 0);
    atol     : in  STD_LOGIC_VECTOR(31 downto 0);  -- absolute tolerance
    rtol     : in  STD_LOGIC_VECTOR(31 downto 0);  -- relative tolerance
    y_in     : in  STD_LOGIC_VECTOR(31 downto 0);  -- current y (for rtol*|y|)
    h_out    : out STD_LOGIC_VECTOR(31 downto 0);
    accepted : out std_logic
);
end step_ctrl;

architecture Behavioral of step_ctrl is
begin
    process(err_in, h_in, atol, rtol, y_in)
        variable abs_err    : unsigned(30 downto 0);
        variable abs_atol   : unsigned(30 downto 0);
        variable eff_tol    : unsigned(30 downto 0);  -- max(atol, rtol*|y|)
        variable tol_low    : unsigned(30 downto 0);  -- eff_tol / 32
        variable h_exp      : unsigned(7 downto 0);
        variable eff_exp    : unsigned(7 downto 0);
        -- 9-bit accumulators to detect overflow when adding exponents
        variable rtol_y_exp : unsigned(8 downto 0);
        variable rtol_y     : unsigned(30 downto 0);
    begin
        -- |err| and |atol|: clear sign bit.
        -- IEEE 754 positive floats compare correctly as unsigned integers.
        abs_err  := unsigned(err_in(30 downto 0));
        abs_atol := unsigned(atol(30 downto 0));
        h_exp    := unsigned(h_in(30 downto 23));

        -- Approximate rtol * |y| via exponent addition only.
        -- true_exp = exp_rtol + exp_y - 127  (remove one bias)
        -- mantissa approximated as 1.0 (i.e. mantissa bits = 0).
        rtol_y_exp := ('0' & unsigned(rtol(30 downto 23))) +
                      ('0' & unsigned(y_in(30 downto 23)));
        -- Subtract bias (127). Guard against underflow.
        if rtol_y_exp > 127 then
            rtol_y_exp := rtol_y_exp - 127;
        else
            rtol_y_exp := (others => '0');
        end if;

        -- Build the approximated rtol*|y| float: sign=0, exp=rtol_y_exp, mantissa=0
        if rtol_y_exp(8) = '1' or rtol_y_exp(7 downto 0) = x"FF" then
            -- Exponent overflow: saturate (set all bits)
            rtol_y := (others => '1');
        elsif rtol_y_exp = 0 then
            -- Exponent underflow / denorm range: treat as zero
            rtol_y := (others => '0');
        else
            rtol_y := rtol_y_exp(7 downto 0) & to_unsigned(0, 23);
        end if;

        -- Effective tolerance = max(atol, rtol_y)
        if rtol_y > abs_atol then
            eff_tol := rtol_y;
        else
            eff_tol := abs_atol;
        end if;

        -- Growth threshold: eff_tol / 32 (exponent - 5)
        eff_exp := eff_tol(30 downto 23);
        if eff_exp > 5 then
            tol_low := (eff_exp - 5) & unsigned(eff_tol(22 downto 0));
        else
            tol_low := (others => '0');
        end if;

        -- Step-size decision
        if abs_err > eff_tol then
            -- Reject step: shrink h by factor 2
            accepted <= '0';
            if h_exp > 1 then
                h_out <= h_in(31) & std_logic_vector(h_exp - 1) & h_in(22 downto 0);
            else
                h_out <= h_in; -- prevent exponent underflow
            end if;
        elsif abs_err < tol_low then
            -- Accept step, grow h by factor 2
            accepted <= '1';
            if h_exp < 254 then
                h_out <= h_in(31) & std_logic_vector(h_exp + 1) & h_in(22 downto 0);
            else
                h_out <= h_in; -- prevent exponent overflow
            end if;
        else
            -- Accept step, keep h
            accepted <= '1';
            h_out <= h_in;
        end if;
    end process;
end Behavioral;
