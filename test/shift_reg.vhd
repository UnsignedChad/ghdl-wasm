library ieee;
use ieee.std_logic_1164.all;

entity shift_reg is
  port (
    clk   : in  std_logic;
    rst   : in  std_logic;
    sin   : in  std_logic;
    pout  : out std_logic_vector(7 downto 0)
  );
end entity;

architecture rtl of shift_reg is
  signal reg : std_logic_vector(7 downto 0) := (others => '0');
begin
  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        reg <= (others => '0');
      else
        reg <= reg(6 downto 0) & sin;
      end if;
    end if;
  end process;
  pout <= reg;
end architecture;
