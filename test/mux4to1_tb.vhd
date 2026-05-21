library ieee;
use ieee.std_logic_1164.all;

entity mux4to1_tb is
end entity;

architecture sim of mux4to1_tb is
  signal sel      : std_logic_vector(1 downto 0) := "00";
  signal i0,i1,i2,i3,y : std_logic := '0';
begin
  uut: entity work.mux4to1 port map (sel=>sel, i0=>i0, i1=>i1, i2=>i2, i3=>i3, y=>y);
  process
  begin
    -- Set all inputs distinct
    i0 <= '0'; i1 <= '1'; i2 <= '0'; i3 <= '1';
    sel <= "00"; wait for 10 ns; -- expect y=0
    sel <= "01"; wait for 10 ns; -- expect y=1
    sel <= "10"; wait for 10 ns; -- expect y=0
    sel <= "11"; wait for 10 ns; -- expect y=1
    -- Change inputs and re-test
    i0 <= '1'; i1 <= '0'; i2 <= '1'; i3 <= '0';
    sel <= "00"; wait for 10 ns; -- expect y=1
    sel <= "01"; wait for 10 ns; -- expect y=0
    sel <= "10"; wait for 10 ns; -- expect y=1
    sel <= "11"; wait for 10 ns; -- expect y=0
    wait;
  end process;
end architecture;
