----------------------------------------------------------------------------------
-- Adaptive Step Size Controller for Dormand-Prince RK45
-- Compares |err| against tolerance and adjusts h by halving/doubling.
-- Uses IEEE 754 exponent manipulation (no FPU needed).
--   |err| > tol       → reject, h_new = h/2
--   |err| < tol/32    → accept, h_new = h*2  (aggressive growth)
--   otherwise         → accept, h_new = h
----------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity step_ctrl is
Port (
    err_in   : in  STD_LOGIC_VECTOR(31 downto 0);
    h_in     : in  STD_LOGIC_VECTOR(31 downto 0);
    tol      : in  STD_LOGIC_VECTOR(31 downto 0);
    h_out    : out STD_LOGIC_VECTOR(31 downto 0);
    accepted : out std_logic
);
end step_ctrl;

architecture Behavioral of step_ctrl is
begin
    process(err_in, h_in, tol)
        variable abs_err  : unsigned(30 downto 0);
        variable abs_tol  : unsigned(30 downto 0);
        variable tol_low  : unsigned(30 downto 0);
        variable h_exp    : unsigned(7 downto 0);
        variable tol_exp  : unsigned(7 downto 0);
    begin
        -- |err| and |tol|: clear sign bit; IEEE 754 positive floats are
        -- ordered the same as unsigned integers, so we can compare directly.
        abs_err := unsigned(err_in(30 downto 0));
        abs_tol := unsigned(tol(30 downto 0));
        h_exp   := unsigned(h_in(30 downto 23));
        tol_exp := unsigned(tol(30 downto 23));

        -- Growth threshold: tol/32 (exponent - 5)
        if tol_exp > 5 then
            tol_low := (tol_exp - 5) & unsigned(tol(22 downto 0));
        else
            tol_low := (others => '0');
        end if;

        if abs_err > abs_tol then
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
