--  Ortho JIT stub for WASM backend.
--  Instead of JIT-compiling, we emit WAT text when Link is called.

with System; use System;
with System.Storage_Elements; use System.Storage_Elements;
with GNAT.OS_Lib;
with Ortho_Wasm;
with Ortho_Nodes; use Ortho_Nodes;

package body Ortho_Jit is

   procedure Init is
   begin
      Ortho_Wasm.Init;
   end Init;

   procedure Set_Address (Decl : O_Dnode; Addr : Address) is
      pragma Unreferenced (Decl, Addr);
   begin null; end Set_Address;

   function Get_Address (Decl : O_Dnode) return Address is
      pragma Unreferenced (Decl);
   begin
      return Null_Address;
   end Get_Address;

   function Get_Byte_Size (Atype : O_Tnode) return Storage_Count is
      pragma Unreferenced (Atype);
   begin
      return 4;
   end Get_Byte_Size;

   function Get_Field_Offset (Field : O_Fnode) return Storage_Count is
      pragma Unreferenced (Field);
   begin
      return 0;
   end Get_Field_Offset;

   procedure Link (Status : out Boolean) is
   begin
      --  Emit the completed WAT module to stdout, then exit cleanly.
      --  Returning to caller would attempt GRT simulation with null addrs.
      Ortho_Wasm.Finish;
      Status := False;
      GNAT.OS_Lib.OS_Exit (0);
   end Link;

   procedure Finish is
   begin null; end Finish;

   function Decode_Option (Option : String) return Boolean is
      pragma Unreferenced (Option);
   begin
      return False;
   end Decode_Option;

   procedure Disp_Help is
   begin null; end Disp_Help;

   function Get_Jit_Name return String is
   begin
      return "wasm";
   end Get_Jit_Name;

   procedure Symbolize (Pc       :     Address;
                        Filename : out Address;
                        Lineno   : out Natural;
                        Subprg   : out Address) is
      pragma Unreferenced (Pc);
   begin
      Filename := Null_Address;
      Lineno   := 0;
      Subprg   := Null_Address;
   end Symbolize;

end Ortho_Jit;
