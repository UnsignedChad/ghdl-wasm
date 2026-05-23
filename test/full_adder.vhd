library ieee;
use ieee.std_logic_1164.all;

entity full_adder is
  port (
    a, b, cin : in  std_logic;
    sum       : out std_logic;
    cout      : out std_logic
  );
end entity;

architecture rtl of full_adder is
begin
  sum  <= a xor b xor cin;
  cout <= (a and b) or (b and cin) or (a and cin);
end architecture;
