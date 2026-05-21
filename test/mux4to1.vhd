library ieee;
use ieee.std_logic_1164.all;

entity mux4to1 is
  port (
    sel : in  std_logic_vector(1 downto 0);
    i0  : in  std_logic;
    i1  : in  std_logic;
    i2  : in  std_logic;
    i3  : in  std_logic;
    y   : out std_logic
  );
end entity;

architecture rtl of mux4to1 is
begin
  process(sel, i0, i1, i2, i3)
  begin
    case sel is
      when "00" => y <= i0;
      when "01" => y <= i1;
      when "10" => y <= i2;
      when "11" => y <= i3;
      when others => y <= '0';
    end case;
  end process;
end architecture;
