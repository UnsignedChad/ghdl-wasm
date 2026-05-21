library ieee;
use ieee.std_logic_1164.all;

entity shift_reg_tb is
end entity;

architecture sim of shift_reg_tb is
  signal clk, rst, sin : std_logic := '0';
  signal pout          : std_logic_vector(7 downto 0);
begin
  uut: entity work.shift_reg port map (clk=>clk, rst=>rst, sin=>sin, pout=>pout);

  clk_proc: process
  begin
    clk <= '0'; wait for 5 ns;
    clk <= '1'; wait for 5 ns;
  end process;

  stim: process
  begin
    rst <= '1'; sin <= '0'; wait for 10 ns;
    rst <= '0';
    -- Shift in pattern 10110101 (MSB first, so shift: 1,0,1,1,0,1,0,1)
    sin <= '1'; wait for 10 ns;
    sin <= '0'; wait for 10 ns;
    sin <= '1'; wait for 10 ns;
    sin <= '1'; wait for 10 ns;
    sin <= '0'; wait for 10 ns;
    sin <= '1'; wait for 10 ns;
    sin <= '0'; wait for 10 ns;
    sin <= '1'; wait for 10 ns;
    -- All zeros
    sin <= '0'; wait for 80 ns;
    wait;
  end process;
end architecture;
