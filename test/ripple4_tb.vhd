library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ripple4_tb is
end entity;

architecture sim of ripple4_tb is
  signal a, b, sum : std_logic_vector(3 downto 0) := (others => '0');
  signal cin, cout : std_logic := '0';
begin
  uut: entity work.ripple4 port map (a=>a, b=>b, cin=>cin, sum=>sum, cout=>cout);
  process
  begin
    -- 5 + 3 = 8
    a <= std_logic_vector(to_unsigned(5, 4));
    b <= std_logic_vector(to_unsigned(3, 4));
    cin <= '0'; wait for 10 ns;
    -- 15 + 1 = 0 (overflow, cout=1)
    a <= std_logic_vector(to_unsigned(15, 4));
    b <= std_logic_vector(to_unsigned(1, 4));
    cin <= '0'; wait for 10 ns;
    -- 7 + 7 = 14
    a <= std_logic_vector(to_unsigned(7, 4));
    b <= std_logic_vector(to_unsigned(7, 4));
    cin <= '0'; wait for 10 ns;
    -- 0 + 0 = 0
    a <= (others => '0');
    b <= (others => '0');
    cin <= '0'; wait for 10 ns;
    wait;
  end process;
end architecture;
