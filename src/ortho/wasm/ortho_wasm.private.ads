--  WASM back-end for ortho – used by the Makefile to generate ortho_wasm.ads.
--  Copyright (C) 2024 VHDL.AI Academy contributors
--  Licensed under GPL-2.0-or-later.
--
--  Structure mirrors ortho_mcode.private.ads:
--   - Everything before "private" becomes the package header in the generated .ads
--   - The "private" section supplies concrete type bindings.

with Interfaces; use Interfaces;
with Ortho_Ident; use Ortho_Ident;
with Ada.Strings.Unbounded;

package Ortho_Wasm is
   --  Initialise the WAT module builder (called once before any translation).
   procedure Init;
   --  Finalise: write the completed WAT module to the output file.
   procedure Finish;

private
   --  WASM does not support nested subprograms.
   Has_Nested_Subprograms : constant Boolean := True;

   --  Every node kind is an unsigned-32 index into its own table.
   --  0 is always the null/invalid sentinel.
   type O_Tnode is new Interfaces.Unsigned_32;   -- type index
   type O_Cnode is new Interfaces.Unsigned_32;   -- constant index
   type O_Dnode is new Interfaces.Unsigned_32;   -- declaration index
   type O_Enode is new Interfaces.Unsigned_32;   -- expression index
   type O_Fnode is new Interfaces.Unsigned_32;   -- struct-field index
   type O_Lnode is new Interfaces.Unsigned_32;   -- lvalue index
   type O_Gnode is new Interfaces.Unsigned_32;   -- global lvalue index
   type O_Snode is new Interfaces.Unsigned_32;   -- loop/block label index

   O_Tnode_Null : constant O_Tnode := 0;
   O_Cnode_Null : constant O_Cnode := 0;
   O_Dnode_Null : constant O_Dnode := 0;
   O_Enode_Null : constant O_Enode := 0;
   O_Fnode_Null : constant O_Fnode := 0;
   O_Lnode_Null : constant O_Lnode := 0;
   O_Gnode_Null : constant O_Gnode := 0;
   O_Snode_Null : constant O_Snode := 0;

   --  Builder-state records (public view is "limited private").
   type O_Element_List is record
      Tnode : O_Tnode := 0;
   end record;
   type O_Element_Sublist is record
      Tnode : O_Tnode := 0;
   end record;
   type O_Enum_List is record
      Tnode : O_Tnode := 0;
      Count : Natural := 0;
   end record;
   type O_Inter_List is record
      Func : O_Dnode := 0;
   end record;
   type O_Record_Aggr_List is record
      Cnode : O_Cnode := 0;
   end record;
   type O_Array_Aggr_List is record
      Cnode : O_Cnode := 0;
   end record;
   type O_Assoc_List is record
      Func  : O_Dnode := 0;
      Count : Natural := 0;
   end record;
   type O_If_Block is record
      Depth : Natural := 0;
   end record;

   -- Phase 4b additions: capture case-value text + per-statement label
   type O_Case_Block is record
      Depth        : Natural := 0;
      Value_Expr   : Ada.Strings.Unbounded.Unbounded_String;
      Label_Idx    : Natural := 0;
      Has_Open_Arm : Boolean := False;
   end record;

end Ortho_Wasm;
