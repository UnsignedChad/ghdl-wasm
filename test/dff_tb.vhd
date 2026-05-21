library ieee;
use ieee.std_logic_1164.all;

entity dff_tb is
end entity;

architecture sim of dff_tb is
  signal clk, rst, d, q : std_logic := '0';
begin
  uut: entity work.dff port map (clk=>clk, rst=>rst, d=>d, q=>q);

  -- Clock process
  clk_proc: process
  begin
    clk <= '0'; wait for 5 ns;
    clk <= '1'; wait for 5 ns;
  end process;

  stim: process
  begin
    -- Hold reset for first cycle
    rst <= '1'; d <= '0'; wait for 10 ns;
    rst <= '0';
    -- Toggle d over several cycles
    d <= '1'; wait for 10 ns;
    d <= '0'; wait for 10 ns;
    d <= '1'; wait for 10 ns;
    d <= '1'; wait for 10 ns;
    d <= '0'; wait for 10 ns;
    -- Assert reset mid-sequence
    rst <= '1'; wait for 10 ns;
    rst <= '0';
    d <= '1'; wait for 10 ns;
    d <= '0'; wait for 10 ns;
    d <= '1'; wait for 10 ns;
    d <= '0'; wait for 10 ns;
    wait;
  end process;
end architecture;
