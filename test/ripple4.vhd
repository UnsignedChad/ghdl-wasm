library ieee;
use ieee.std_logic_1164.all;

entity ripple4 is
  port (
    a, b  : in  std_logic_vector(3 downto 0);
    cin   : in  std_logic;
    sum   : out std_logic_vector(3 downto 0);
    cout  : out std_logic
  );
end entity;

architecture structural of ripple4 is
  signal c : std_logic_vector(4 downto 0);
begin
  c(0) <= cin;
  cout <= c(4);

  gen: for i in 0 to 3 generate
    fa: entity work.full_adder
      port map (a => a(i), b => b(i), cin => c(i), sum => sum(i), cout => c(i+1));
  end generate;
end architecture;
