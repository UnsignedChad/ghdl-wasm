library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity alu_tb is
end entity;

architecture sim of alu_tb is
  signal a, b, result : std_logic_vector(3 downto 0) := (others => '0');
  signal opcode       : std_logic_vector(1 downto 0) := "00";
begin
  uut: entity work.alu port map (a=>a, b=>b, opcode=>opcode, result=>result);
  process
  begin
    -- ADD: 5 + 3 = 8
    a <= std_logic_vector(to_unsigned(5, 4));
    b <= std_logic_vector(to_unsigned(3, 4));
    opcode <= "00"; wait for 10 ns;
    -- SUB: 9 - 4 = 5
    a <= std_logic_vector(to_unsigned(9, 4));
    b <= std_logic_vector(to_unsigned(4, 4));
    opcode <= "01"; wait for 10 ns;
    -- AND: 0xA & 0x6 = 0x2
    a <= "1010";
    b <= "0110";
    opcode <= "10"; wait for 10 ns;
    -- OR: 0xA | 0x6 = 0xE
    a <= "1010";
    b <= "0110";
    opcode <= "11"; wait for 10 ns;
    -- ADD overflow: 15 + 1 = 0
    a <= std_logic_vector(to_unsigned(15, 4));
    b <= std_logic_vector(to_unsigned(1, 4));
    opcode <= "00"; wait for 10 ns;
    wait;
  end process;
end architecture;
