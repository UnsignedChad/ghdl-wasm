library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity counter4_tb is
end entity;

architecture sim of counter4_tb is
  signal clk, rst, en : std_logic := '0';
  signal count        : std_logic_vector(3 downto 0);
begin
  uut: entity work.counter4 port map (clk=>clk, rst=>rst, en=>en, count=>count);

  clk_proc: process
  begin
    clk <= '0'; wait for 5 ns;
    clk <= '1'; wait for 5 ns;
  end process;

  stim: process
  begin
    rst <= '1'; en <= '0'; wait for 10 ns;
    rst <= '0'; en <= '1';
    -- Count from 0 to 15 (16 clock cycles)
    wait for 160 ns;
    -- Test enable off (should hold)
    en <= '0'; wait for 20 ns;
    en <= '1'; wait for 20 ns;
    -- Reset in middle
    rst <= '1'; wait for 10 ns;
    rst <= '0'; wait for 30 ns;
    wait;
  end process;
end architecture;
