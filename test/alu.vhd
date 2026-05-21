library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity alu is
  port (
    a, b   : in  std_logic_vector(3 downto 0);
    opcode : in  std_logic_vector(1 downto 0);
    result : out std_logic_vector(3 downto 0)
  );
end entity;

architecture rtl of alu is
begin
  process(a, b, opcode)
  begin
    case opcode is
      when "00" =>
        result <= std_logic_vector(unsigned(a) + unsigned(b));
      when "01" =>
        result <= std_logic_vector(unsigned(a) - unsigned(b));
      when "10" =>
        result <= a and b;
      when "11" =>
        result <= a or b;
      when others =>
        result <= (others => '0');
    end case;
  end process;
end architecture;
