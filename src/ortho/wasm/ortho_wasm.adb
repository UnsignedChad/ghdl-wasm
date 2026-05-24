--  WASM back-end for ortho – package body.
--  Translates ortho IR calls into WAT (WebAssembly Text format) output.
--  Copyright (C) 2024 VHDL.AI Academy contributors
--  Licensed under GPL-2.0-or-later.
--
--  Memory-safe design:
--   * Expressions are stored as small fixed structs (struct-based IR), not
--     as string copies.  This avoids the exponential string-growth that
--     occurs when composing deeply nested expression trees.
--   * WAT text is only produced when a *statement* is emitted; expression
--     nodes are traversed on demand via Emit_Expr.
--   * All tables are package-level (global data/BSS), not on the Ada stack.

with Ada.Text_IO;              use Ada.Text_IO;
with Ada.Long_Long_Integer_Text_IO;
with Ada.Strings.Unbounded;    use Ada.Strings.Unbounded;
with Interfaces;               use Interfaces;
with Ortho_Ident;              use Ortho_Ident;

pragma Style_Checks (Off);
package body Ortho_Wasm is

   function Img (N : Natural) return String is
      S : constant String := Natural'Image (N);
   begin return S (S'First + 1 .. S'Last); end Img;


   ---------------------------------------------------------------------------
   --  Type table
   ---------------------------------------------------------------------------

   type Wat_Kind is (Wk_I32, Wk_I64, Wk_F64, Wk_Memory);

   type Type_Entry is record
      Kind : Wat_Kind := Wk_I32;
      Sz   : Natural  := 4;
   end record;

   Max_Types : constant := 16_384;
   type Type_Table_T is array (1 .. Max_Types) of Type_Entry;
   Types     : Type_Table_T;
   Types_Top : Natural := 0;

   New_Type_Total : Natural := 0;

   function New_Type (K : Wat_Kind; Sz : Natural) return O_Tnode is
   begin
      New_Type_Total := New_Type_Total + 1;
      if New_Type_Total mod 1000 = 1 then
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
            "WASM: New_Type#" & Natural'Image (New_Type_Total) &
            " Types_Top=" & Natural'Image (Types_Top));
         Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
      end if;
      if Types_Top >= Max_Types then
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
            "WASM: ABORT Types overflow at " & Natural'Image (Types_Top));
         Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
         raise Program_Error with "Types table overflow";
      end if;
      Types_Top := Types_Top + 1;
      Types (Types_Top) := (Kind => K, Sz => Sz);
      return O_Tnode (Types_Top);
   end New_Type;

   function Wat_Kind_Of (T : O_Tnode) return Wat_Kind is
   begin
      if T = 0 then return Wk_I32; end if;
      return Types (Natural (T)).Kind;
   end Wat_Kind_Of;

   function Wat_Type_Of (T : O_Tnode) return String is
   begin
      case Wat_Kind_Of (T) is
         when Wk_I32 | Wk_Memory => return "i32";
         when Wk_I64             => return "i64";
         when Wk_F64             => return "f64";
      end case;
   end Wat_Type_Of;

   ---------------------------------------------------------------------------
   --  Constant table  (small: just a value + type pair)
   ---------------------------------------------------------------------------

   type Cnode_Entry is record
      Val  : Integer_64 := 0;
      Fval : Long_Float  := 0.0;
      Kind : Wat_Kind    := Wk_I32;
   end record;

   Max_Cnodes : constant := 16_384;
   type Cnode_Table_T is array (1 .. Max_Cnodes) of Cnode_Entry;
   Cnodes     : Cnode_Table_T;
   Cnodes_Top : Natural := 0;

   function New_Cnode (V : Integer_64; K : Wat_Kind) return O_Cnode is
   begin
      Cnodes_Top := Cnodes_Top + 1;
      Cnodes (Cnodes_Top) := (Val => V, Fval => 0.0, Kind => K);
      return O_Cnode (Cnodes_Top);
   end New_Cnode;

   function New_Cnode_F (V : Long_Float; K : Wat_Kind) return O_Cnode is
   begin
      Cnodes_Top := Cnodes_Top + 1;
      Cnodes (Cnodes_Top) := (Val => 0, Fval => V, Kind => K);
      return O_Cnode (Cnodes_Top);
   end New_Cnode_F;

   ---------------------------------------------------------------------------
   --  Declaration table
   ---------------------------------------------------------------------------

   type Decl_Kind is (Dk_Func, Dk_Global, Dk_Local, Dk_Const);

   type Decl_Entry is record
      Kind  : Decl_Kind  := Dk_Global;
      Tnode : O_Tnode    := 0;
      Idx   : Natural    := 0;
      --  Name stored in Ident_Buf, length in Name_Len
      Name_Off : Natural := 0;
      Name_Len : Natural := 0;
      --  True when the function was declared with O_Storage_Public; we
      --  emit a (export "<name>" (func $<name>)) line for each such
      --  function at module-finish time.
      Is_Public : Boolean := False;
      --  WAT parameter list for Dk_Func entries, built by New_Interface_Decl
      Params    : Ada.Strings.Unbounded.Unbounded_String;
      --  Phase 6: snapshot of Params taken when Start_Subprogram_Body moves
      --  the live params out, so we still have a signature for stubbing
      --  bodyless declarations at Finish time.
      Saved_Params : Ada.Strings.Unbounded.Unbounded_String;
      Has_Body     : Boolean := False;
   end record;

   --  One big string buffer for all declaration names (avoids per-entry alloc)
   Ident_Buf     : String (1 .. 4_000_000);
   Ident_Buf_Top : Natural := 0;

   function Store_Name (S : String) return Natural is
      Off : constant Natural := Ident_Buf_Top + 1;
   begin
      if Off + S'Length - 1 > Ident_Buf'Last then
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
            "WASM: ABORT Ident_Buf overflow at " & Natural'Image (Ident_Buf_Top) &
            " adding " & Natural'Image (S'Length) & " bytes");
         Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
         raise Program_Error with "Ident_Buf overflow";
      end if;
      Ident_Buf (Off .. Off + S'Length - 1) := S;
      Ident_Buf_Top := Off + S'Length - 1;
      return Off;
   end Store_Name;

   --  Forward spec: body is after Decls table declaration.
   function Get_Name (D : O_Dnode) return String;

   Max_Decls : constant := 32_768;
   type Decl_Table_T is array (1 .. Max_Decls) of Decl_Entry;
   Decls     : Decl_Table_T;
   Decls_Top : Natural := 0;

   function Get_Name (D : O_Dnode) return String is
   begin
      if D = 0 then return "nil"; end if;
      declare
         E : Decl_Entry renames Decls (Natural (D));
      begin
         return Ident_Buf (E.Name_Off .. E.Name_Off + E.Name_Len - 1);
      end;
   end Get_Name;

   Global_Count : Natural := 0;
   Func_Count   : Natural := 0;

   function New_Decl (K : Decl_Kind; Nam : String; T : O_Tnode) return O_Dnode
   is
      Idx  : Natural;
      Off  : constant Natural := Store_Name (Nam);
   begin
      if Decls_Top >= Max_Decls then
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
            "WASM: ABORT Decls overflow at " & Natural'Image (Decls_Top));
         Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
         raise Program_Error with "Decls table overflow";
      end if;
      Decls_Top := Decls_Top + 1;
      case K is
         when Dk_Global | Dk_Const =>
            Global_Count := Global_Count + 1; Idx := Global_Count;
         when Dk_Func =>
            Func_Count := Func_Count + 1;     Idx := Func_Count;
         when Dk_Local =>
            Idx := 0;
      end case;
      Decls (Decls_Top) := (Kind     => K,
                            Tnode    => T,
                            Idx      => Idx,
                            Name_Off => Off,
                            Name_Len => Nam'Length,
                            Is_Public => False,
                            Params    => Ada.Strings.Unbounded.Null_Unbounded_String,
                            Saved_Params => Ada.Strings.Unbounded.Null_Unbounded_String,
                            Has_Body => False);
      return O_Dnode (Decls_Top);
   end New_Decl;

   ---------------------------------------------------------------------------
   --  Field table
   ---------------------------------------------------------------------------

   type Field_Entry is record
      Offset : Natural := 0;
      Ftype  : O_Tnode := 0;
   end record;

   Max_Fields : constant := 65_536;
   type Field_Table_T is array (1 .. Max_Fields) of Field_Entry;
   Fields     : Field_Table_T;
   Fields_Top : Natural := 0;

   ---------------------------------------------------------------------------
   --  Expression IR (struct-based, NOT string-based)
   --  Each node stores its kind + references to operand nodes by index.
   --  Strings are produced on demand by Emit_Expr, not stored.
   ---------------------------------------------------------------------------

   type Expr_Kind is (
      Ek_Lit_I32,      -- i32.const Val
      Ek_Lit_I64,      -- i64.const Val
      Ek_Lit_F64,      -- f64.const Fval
      Ek_Local_Get,    -- local.get $decl
      Ek_Global_Get,   -- global.get $decl
      Ek_Func_Idx,     -- i32.const func_idx (address-of-function)
      Ek_Binop,        -- op(arg1, arg2)
      Ek_Monop,        -- op(arg1)
      Ek_Compare,      -- op(arg1, arg2) → i32 bool
      Ek_Load,         -- i32.load(addr_expr)
      Ek_Call,         -- call $decl  (result on stack)
      Ek_Select,       -- select a b cond  (for abs)
      Ek_Zero,         -- i32.const 0
      Ek_Addr_Stub,    -- placeholder for address-of (emits i32.const 0)
      Ek_Addr_Lvalue,  -- proper address-of: encodes O_Lnode in Arg1
      Ek_Wrap_I32      -- i32.wrap_i64 (truncate i64 -> i32)
   );

   type Expr_Entry is record
      Kind  : Expr_Kind  := Ek_Zero;
      Arg1  : O_Enode    := 0;
      Arg2  : O_Enode    := 0;
      Arg3  : O_Enode    := 0;   -- for Ek_Select condition
      Decl  : O_Dnode    := 0;
      Ival  : Integer_64 := 0;
      Fval  : Long_Float  := 0.0;
      Op    : ON_Op_Kind := ON_Nil;
      Etype : O_Tnode    := 0;
      --  For Ek_Call: evaluated argument strings, snapshotted at call-site.
      Args  : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   Max_Exprs : constant := 131_072;
   type Expr_Table_T is array (1 .. Max_Exprs) of Expr_Entry;
   Exprs     : Expr_Table_T;
   Exprs_Top : Natural := 0;

   function New_Expr (E : Expr_Entry) return O_Enode is
   begin
      Exprs_Top := Exprs_Top + 1;
      Exprs (Exprs_Top) := E;
      return O_Enode (Exprs_Top);
   end New_Expr;

   ---------------------------------------------------------------------------
   --  Lvalue IR
   ---------------------------------------------------------------------------

   type Lval_Kind is (Lv_Local, Lv_Global, Lv_Index, Lv_Field, Lv_Deref);

   type Lval_Entry is record
      Kind  : Lval_Kind := Lv_Local;
      Decl  : O_Dnode   := 0;
      Base  : O_Lnode   := 0;
      Idx_E : O_Enode   := 0;
      Field : O_Fnode   := 0;
      Tnode : O_Tnode   := 0;
   end record;

   Max_Lvals : constant := 131_072;
   type Lval_Table_T is array (1 .. Max_Lvals) of Lval_Entry;
   Lvals     : Lval_Table_T;
   Lvals_Top : Natural := 0;

   function New_Lval (E : Lval_Entry) return O_Lnode is
   begin
      Lvals_Top := Lvals_Top + 1;
      Lvals (Lvals_Top) := E;
      return O_Lnode (Lvals_Top);
   end New_Lval;

   ---------------------------------------------------------------------------
   --  Output buffers
   ---------------------------------------------------------------------------

   Globals_Buf         : Unbounded_String;
   --  Buffer for function bodies; emitted after Globals_Buf in Finish so
   --  that every (global.get $X) follows the global's declaration (wat2wasm
   --  is single-pass and rejects forward refs otherwise).
   Funcs_Buf           : Unbounded_String;
   --  Phase 4: accumulator for (export ...) lines, flushed in Finish.
   Exports_Buf : Ada.Strings.Unbounded.Unbounded_String;
   --  Phase 5: function-pointer table. New_Subprogram_Address returns the
   --  ortho function index, which the host JS must turn back into a real
   --  callable. We emit a (table) + (elem) section keyed on the same index.
   Elem_Buf      : Ada.Strings.Unbounded.Unbounded_String;
   Max_Body_Idx  : Natural := 0;
   Pending_Func_Params : Unbounded_String;
   Pending_Call_Args   : Unbounded_String;
   Debug_Func_Count    : Natural := 0;
   Debug_Emit_Count    : Natural := 0;

   type Func_State is record
      Name_Off  : Natural := 0;
      Name_Len  : Natural := 0;
      Ret_Type  : O_Tnode := 0;
      Params    : Unbounded_String;
      Locals    : Unbounded_String;
      Body_Buf  : Unbounded_String;
   end record;

   Cur_Func : Func_State;
   In_Func  : Boolean := False;
   --  Phase 4: index of the function whose body is currently being
   --  emitted, so Finish_Subprogram_Body can look up its Is_Public flag.
   Pending_Decl_Idx : O_Dnode := 0;
   --  Phase 4b: monotonic counter for unique case-block labels
   Case_Counter : Natural := 0;
   Indent   : Natural := 2;

   function Cur_Func_Name return String is
   begin
      return Ident_Buf (Cur_Func.Name_Off
                        .. Cur_Func.Name_Off + Cur_Func.Name_Len - 1);
   end Cur_Func_Name;

   procedure Emit_Ln (S : String) is
      Pad : String (1 .. Indent);
   begin
      Debug_Emit_Count := Debug_Emit_Count + 1;
      if Debug_Emit_Count > 5_000_000 then
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
            "WASM: ABORT emit overflow in func " & Cur_Func_Name);
         Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
         Ada.Text_IO.Flush;
         raise Program_Error with "Emit_Ln overflow";
      end if;
      Pad := (others => ' ');
      Append (Cur_Func.Body_Buf, Pad & S & ASCII.LF);
   end Emit_Ln;

   ---------------------------------------------------------------------------
   --  Label stack
   ---------------------------------------------------------------------------

   Max_Labels : constant := 512;
   type Label_Table_T is array (1 .. Max_Labels) of Natural;
   Labels    : Label_Table_T;
   Label_Top : Natural := 0;
   Label_Cnt : Natural := 0;

   function New_Label return Natural is
   begin
      Label_Cnt := Label_Cnt + 1;
      return Label_Cnt;
   end New_Label;

   ---------------------------------------------------------------------------
   --  Integer image helpers
   ---------------------------------------------------------------------------

   function I64_Img (N : Integer_64) return String is
      S : String (1 .. 25);
      L : Natural;
   begin
      Ada.Long_Long_Integer_Text_IO.Put (To => S,
                                         Item => Long_Long_Integer (N));
      L := S'First;
      while L <= S'Last and then S (L) = ' ' loop
         L := L + 1;
      end loop;
      return S (L .. S'Last);
   end I64_Img;

   function U64_Img (N : Unsigned_64) return String is
   begin
      if N <= Unsigned_64 (Integer_64'Last) then
         return I64_Img (Integer_64 (N));
      end if;
      return "0";  --  rare: very large unsigned constant
   end U64_Img;

   function F64_Img (N : Long_Float) return String is
   begin
      return Long_Float'Image (N);
   end F64_Img;

   ---------------------------------------------------------------------------
   --  Emit_Expr: recursively emit a WAT s-expression fragment.
   --  Appends to Cur_Func.Body_Buf (or a supplied Unbounded_String).
   ---------------------------------------------------------------------------

   function Lval_Addr_S  (L : O_Lnode) return String;
   function Lval_Read_S  (L : O_Lnode) return String;
   function Lval_Write_S (L : O_Lnode; Val : String) return String;

   procedure Emit_Expr_To (E : O_Enode; Buf : in out Unbounded_String);

   procedure Emit_Expr_To (E : O_Enode; Buf : in out Unbounded_String) is
   begin
      if E = 0 then
         Append (Buf, "(i32.const 0)");
         return;
      end if;
      declare
         Ent : Expr_Entry renames Exprs (Natural (E));
         Wt  : constant String := Wat_Type_Of (Ent.Etype);
      begin
         case Ent.Kind is
            when Ek_Lit_I32 =>
               Append (Buf, "(i32.const " & I64_Img (Ent.Ival) & ")");
            when Ek_Lit_I64 =>
               Append (Buf, "(i64.const " & I64_Img (Ent.Ival) & ")");
            when Ek_Lit_F64 =>
               Append (Buf, "(f64.const " & F64_Img (Ent.Fval) & ")");
            when Ek_Zero | Ek_Addr_Stub =>
               Append (Buf, "(i32.const 0)");
            when Ek_Addr_Lvalue =>
               Append (Buf, Lval_Addr_S (O_Lnode (Ent.Arg1)));
            when Ek_Local_Get =>
               Append (Buf, "(local.get $" & Get_Name (Ent.Decl) & ")");
            when Ek_Global_Get =>
               if Ent.Decl = 0 then
                  Append (Buf, "(i32.const 0)");
               else
                  Append (Buf, "(global.get $" & Get_Name (Ent.Decl) & ")");
               end if;
            when Ek_Func_Idx =>
               Append (Buf, "(i32.const " &
                       I64_Img (Integer_64 (Decls (Natural (Ent.Decl)).Idx))
                       & ")");
            when Ek_Binop =>
               declare
                  Op_S : constant String :=
                    (case Ent.Op is
                        when ON_Add_Ov => Wt & ".add",
                        when ON_Sub_Ov => Wt & ".sub",
                        when ON_Mul_Ov => Wt & ".mul",
                        when ON_Div_Ov => Wt & ".div_s",
                        when ON_Rem_Ov => Wt & ".rem_s",
                        when ON_Mod_Ov => Wt & ".rem_s",
                        when ON_And    => Wt & ".and",
                        when ON_Or     => Wt & ".or",
                        when ON_Xor    => Wt & ".xor",
                        when others    => Wt & ".add");
               begin
                  Append (Buf, "(" & Op_S & " ");
                  Emit_Expr_To (Ent.Arg1, Buf);
                  Append (Buf, " ");
                  Emit_Expr_To (Ent.Arg2, Buf);
                  Append (Buf, ")");
               end;
            when Ek_Monop =>
               case Ent.Op is
                  when ON_Not    =>
                     Append (Buf, "(" & Wt & ".xor ");
                     Emit_Expr_To (Ent.Arg1, Buf);
                     Append (Buf, " (" & Wt & ".const -1))");
                  when ON_Neg_Ov =>
                     Append (Buf, "(" & Wt & ".sub (" & Wt & ".const 0) ");
                     Emit_Expr_To (Ent.Arg1, Buf);
                     Append (Buf, ")");
                  when ON_Abs_Ov =>
                     --  abs(x): select x (-x) (x>=0)
                     Append (Buf, "(select ");
                     Emit_Expr_To (Ent.Arg1, Buf);
                     Append (Buf, " (" & Wt & ".sub (" & Wt & ".const 0) ");
                     Emit_Expr_To (Ent.Arg1, Buf);
                     Append (Buf, ") (" & Wt & ".ge_s ");
                     Emit_Expr_To (Ent.Arg1, Buf);
                     Append (Buf, " (" & Wt & ".const 0)))");
                  when others => null;
               end case;
            when Ek_Compare =>
               declare
                  T1   : constant O_Tnode := Exprs (Natural (Ent.Arg1)).Etype;
                  T2   : constant O_Tnode := Exprs (Natural (Ent.Arg2)).Etype;
                  K1   : constant Wat_Kind :=
                    (if T1 /= 0 then Types (Natural (T1)).Kind else Wk_I32);
                  K2   : constant Wat_Kind :=
                    (if T2 /= 0 then Types (Natural (T2)).Kind else Wk_I32);
                  --  Use the narrower type for the comparison; coerce the
                  --  wider operand down with i32.wrap_i64.
                  Wt2  : constant String :=
                    (if K1 = Wk_I32 or K2 = Wk_I32 then "i32" else Wat_Type_Of (T1));
                  Op_S : constant String :=
                    (case Ent.Op is
                        when ON_Eq  => Wt2 & ".eq",
                        when ON_Neq => Wt2 & ".ne",
                        when ON_Le  => Wt2 & ".le_s",
                        when ON_Lt  => Wt2 & ".lt_s",
                        when ON_Ge  => Wt2 & ".ge_s",
                        when ON_Gt  => Wt2 & ".gt_s",
                        when others => Wt2 & ".eq");
                  procedure Emit_Arg (E : O_Enode; K : Wat_Kind) is
                  begin
                     if Wt2 = "i32" and K = Wk_I64 then
                        Append (Buf, "(i32.wrap_i64 ");
                        Emit_Expr_To (E, Buf);
                        Append (Buf, ")");
                     else
                        Emit_Expr_To (E, Buf);
                     end if;
                  end Emit_Arg;
               begin
                  Append (Buf, "(" & Op_S & " ");
                  Emit_Arg (Ent.Arg1, K1);
                  Append (Buf, " ");
                  Emit_Arg (Ent.Arg2, K2);
                  Append (Buf, ")");
               end;
            when Ek_Load =>
               --  Arg1 is an O_Lnode stored as O_Enode; use Lval_Read_S.
               Append (Buf, Lval_Read_S (O_Lnode (Ent.Arg1)));
            when Ek_Call =>
               Append (Buf, "(call $" & Get_Name (Ent.Decl) &
                       To_String (Ent.Args) & ")");
            when Ek_Wrap_I32 =>
               Append (Buf, "(i32.wrap_i64 ");
               Emit_Expr_To (Ent.Arg1, Buf);
               Append (Buf, ")");
            when Ek_Select =>
               Append (Buf, "(select ");
               Emit_Expr_To (Ent.Arg1, Buf);
               Append (Buf, " ");
               Emit_Expr_To (Ent.Arg2, Buf);
               Append (Buf, " ");
               Emit_Expr_To (Ent.Arg3, Buf);
               Append (Buf, ")");
         end case;
      end;
   end Emit_Expr_To;

   --  Convenience: emit expression inline into current body
   function Expr_S (E : O_Enode) return String is
      Buf : Unbounded_String;
   begin
      Emit_Expr_To (E, Buf);
      return To_String (Buf);
   end Expr_S;

   ---------------------------------------------------------------------------
   --  Lvalue read / write helpers
   ---------------------------------------------------------------------------

   --  Return the i32 linear-memory address at which lvalue L resides.
   --  For locals/globals this is a direct register value (not truly an addr).
   function Lval_Addr_S (L : O_Lnode) return String is
   begin
      if L = 0 then return "(i32.const 0)"; end if;
      declare
         Lv : Lval_Entry renames Lvals (Natural (L));
      begin
         case Lv.Kind is
            when Lv_Local  =>
               return "(local.get $" & Get_Name (Lv.Decl) & ")";
            when Lv_Global =>
               return "(global.get $" & Get_Name (Lv.Decl) & ")";
            when Lv_Deref  =>
               --  Base was stored as O_Lnode but is actually an O_Enode
               --  (the pointer expression).  Evaluate it as an expression.
               return Expr_S (O_Enode (Lv.Base));
            when Lv_Field  =>
               return "(i32.add " & Lval_Addr_S (Lv.Base) &
                      " (i32.const" &
                      Natural'Image (Fields (Natural (Lv.Field)).Offset) &
                      "))";
            when Lv_Index  =>
               return "(i32.add " & Lval_Addr_S (Lv.Base) &
                      " (i32.mul (i32.const 4) " & Expr_S (Lv.Idx_E) & "))";
         end case;
      end;
   end Lval_Addr_S;

   --  Read the value stored at lvalue L.
   function Lval_Read_S (L : O_Lnode) return String is
   begin
      if L = 0 then return "(i32.const 0)"; end if;
      declare
         Lv : Lval_Entry renames Lvals (Natural (L));
      begin
         case Lv.Kind is
            when Lv_Local  =>
               return "(local.get $" & Get_Name (Lv.Decl) & ")";
            when Lv_Global =>
               return "(global.get $" & Get_Name (Lv.Decl) & ")";
            when Lv_Deref | Lv_Field | Lv_Index =>
               return "(i32.load " & Lval_Addr_S (L) & ")";
         end case;
      end;
   end Lval_Read_S;

   --  Write Val into lvalue L.
   function Lval_Write_S (L : O_Lnode; Val : String) return String is
   begin
      if L = 0 then return "(nop)"; end if;
      declare
         Lv : Lval_Entry renames Lvals (Natural (L));
      begin
         case Lv.Kind is
            when Lv_Local  =>
               return "(local.set $" & Get_Name (Lv.Decl) & " " & Val & ")";
            when Lv_Global =>
               return "(global.set $" & Get_Name (Lv.Decl) & " " & Val & ")";
            when Lv_Deref | Lv_Field | Lv_Index =>
               return "(i32.store " & Lval_Addr_S (L) & " " & Val & ")";
         end case;
      end;
   end Lval_Write_S;

   ---------------------------------------------------------------------------
   --  Init / Finish
   ---------------------------------------------------------------------------

   procedure Init is
   begin
      Types_Top    := 0;
      Cnodes_Top   := 0;
      Decls_Top    := 0;
      Ident_Buf_Top := 0;
      Fields_Top   := 0;
      Exprs_Top    := 0;
      Lvals_Top    := 0;
      Label_Top    := 0;
      Label_Cnt    := 0;
      Global_Count := 0;
      Func_Count   := 0;
      In_Func      := False;
      Globals_Buf         := Null_Unbounded_String;
      Funcs_Buf           := Null_Unbounded_String;
      Pending_Func_Params := Null_Unbounded_String;
      Put_Line ("(module");
      Put_Line ("  (import ""env"" ""__ghdl_stack2_allocate"" (func $__ghdl_stack2_allocate (param i32) (result i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_memcpy"" (func $__ghdl_memcpy (param i32 i32 i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_bound_check_failed"" (func $__ghdl_bound_check_failed (param i32 i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_integer_32_index_check_failed"" (func $__ghdl_integer_32_index_check_failed (param i32 i32 i32 i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_program_error"" (func $__ghdl_program_error (param i32 i32 i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_process_wait_exit"" (func $__ghdl_process_wait_exit))");
      Put_Line ("  (import ""env"" ""__ghdl_process_wait_timeout"" (func $__ghdl_process_wait_timeout (param i64 i32 i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_signal_direct_assign"" (func $__ghdl_signal_direct_assign (param i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_signal_read_driver"" (func $__ghdl_signal_read_driver (param i32 i32) (result i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_signal_read_port"" (func $__ghdl_signal_read_port (param i32 i32) (result i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_stack2_mark"" (func $__ghdl_stack2_mark (result i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_stack2_release"" (func $__ghdl_stack2_release (param i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_check_stack_allocation"" (func $__ghdl_check_stack_allocation (param i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_ieee_assert_failed"" (func $__ghdl_ieee_assert_failed (param i32 i32 i32 i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_i32_mod"" (func $__ghdl_i32_mod (param i32 i32) (result i32)))");
      --  Additional GRT helpers referenced by emitted code but historically
      --  patched in by post-processing (e.g. VHDLive/server/src/compile.js
      --  patchWat).  Declaring them here makes wat2wasm accept the output
      --  directly.
      Put_Line ("  (import ""env"" ""__ghdl_malloc0"" (func $__ghdl_malloc0 (param i32) (result i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_integer_index_check_failed"" (func $__ghdl_integer_index_check_failed (param i32 i32 i32 i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_rti_add_package"" (func $__ghdl_rti_add_package (param i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_rti_add_top"" (func $__ghdl_rti_add_top (param i32 i32 i32 i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_init_top_generics"" (func $__ghdl_init_top_generics))");
      Put_Line ("  (import ""env"" ""__ghdl_process_register"" (func $__ghdl_process_register (param i32 i32 i32 i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_sensitized_process_register"" (func $__ghdl_sensitized_process_register (param i32 i32 i32 i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_process_add_sensitivity"" (func $__ghdl_process_add_sensitivity (param i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_create_signal_e8"" (func $__ghdl_create_signal_e8 (param i32 i32 i32) (result i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_signal_init_e8"" (func $__ghdl_signal_init_e8 (param i32 i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_signal_add_direct_driver"" (func $__ghdl_signal_add_direct_driver (param i32 i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_signal_name_rti"" (func $__ghdl_signal_name_rti (param i32 i32 i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_signal_merge_rti"" (func $__ghdl_signal_merge_rti (param i32 i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_assert_failed"" (func $__ghdl_assert_failed (param i32 i32 i32 i32)))");
      Put_Line ("  (import ""env"" ""__ghdl_report"" (func $__ghdl_report (param i32 i32 i32 i32)))");
      Put_Line ("  (memory 1)");
      Put_Line ("  (export ""memory"" (memory 0))");
      Put_Line ("  (global $__sp (mut i32) (i32.const 65536))");
      Ada.Text_IO.Flush;
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "WASM: Init done");
      Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
   end Init;

   procedure Finish is
      MaxImg : constant String := Natural'Image (Max_Body_Idx + 1);
      MaxTrim : constant String := MaxImg (MaxImg'First + 1 .. MaxImg'Last);
   begin
      --  Emit globals before functions so wat2wasm can resolve forward refs.
      Put (To_String (Globals_Buf));
      Put (To_String (Funcs_Buf));
      --  Phase 5: emit the function-pointer table. Size = Max_Body_Idx + 1.
      Put_Line ("  (table $__T " & MaxTrim & " funcref)");
      Put_Line ("  (export ""__indirect_function_table"" (table $__T))");
      Put (To_String (Elem_Buf));
      --  Phase 6: emit empty stub bodies for any function that was declared
      --  but whose body was never translated. The synth-based simulator skips
      --  configuration bodies (default DEFAULT_CONFIG), and there may be other
      --  declared-only functions referenced from elab code.
      for I in 1 .. Decls_Top loop
         if Decls (I).Kind = Dk_Func
           and then not Decls (I).Has_Body
           and then Decls (I).Name_Len > 0
         then
            declare
               Nm : constant String :=
                 Ident_Buf (Decls (I).Name_Off
                          .. Decls (I).Name_Off + Decls (I).Name_Len - 1);
               --  If the name matches one of the imports we ALREADY declared
               --  in Init (anything starting with "__ghdl_"), skip — emitting a
               --  func with the same name as an import is a wat2wasm error.
            begin
               if Nm'Length < 7 or else Nm (Nm'First .. Nm'First + 6) /= "__ghdl_" then
                  Put ("  (func $" & Nm
                       & To_String (Decls (I).Params)
                       & To_String (Decls (I).Saved_Params));
                  if Decls (I).Tnode /= 0 then
                     Put (" (result " & Wat_Type_Of (Decls (I).Tnode) & ")");
                  end if;
                  Put_Line ("");
                  if Decls (I).Tnode /= 0 then
                     Put_Line ("    (unreachable)");
                  end if;
                  Put_Line ("  )");
               end if;
            end;
         end if;
      end loop;
      --  Phase 4: flush export declarations gathered during translation.
      Put (To_String (Exports_Buf));
      Put_Line (")");
   end Finish;

   ---------------------------------------------------------------------------
   --  Helper: cnode literal kind
   ---------------------------------------------------------------------------

   function Cnode_Expr_Kind (C : O_Cnode) return Expr_Kind is
   begin
      case Cnodes (Natural (C)).Kind is
         when Wk_I32 | Wk_Memory => return Ek_Lit_I32;
         when Wk_I64             => return Ek_Lit_I64;
         when Wk_F64             => return Ek_Lit_F64;
      end case;
   end Cnode_Expr_Kind;

   ---------------------------------------------------------------------------
   --  Type builders
   ---------------------------------------------------------------------------

   procedure Start_Record_Type (Elements : out O_Element_List) is
   begin
      Elements := (Tnode => New_Type (Wk_Memory, 0));
   end Start_Record_Type;

   procedure New_Record_Field
     (Elements : in out O_Element_List; El : out O_Fnode;
      Ident : O_Ident; Etype : O_Tnode)
   is
      pragma Unreferenced (Ident);
      T   : constant O_Tnode := Elements.Tnode;
      Sz  : constant Natural :=
              (if Etype = 0 then 4 else Types (Natural (Etype)).Sz);
      Off : constant Natural := Types (Natural (T)).Sz;
   begin
      Fields_Top := Fields_Top + 1;
      Fields (Fields_Top) := (Offset => Off, Ftype => Etype);
      Types (Natural (T)).Sz := Off + Sz;
      El := O_Fnode (Fields_Top);
   end New_Record_Field;

   procedure Finish_Record_Type
     (Elements : in out O_Element_List; Res : out O_Tnode) is
   begin Res := Elements.Tnode; end Finish_Record_Type;

   procedure Start_Record_Subtype
     (Rtype : O_Tnode; Elements : out O_Element_Sublist) is
   begin
      Elements := (Tnode => New_Type (Wk_Memory, Types (Natural (Rtype)).Sz));
   end Start_Record_Subtype;

   procedure New_Subrecord_Field
     (Elements : in out O_Element_Sublist; El : out O_Fnode; Etype : O_Tnode)
   is
   begin
      Fields_Top := Fields_Top + 1;
      Fields (Fields_Top) := (Offset => 0, Ftype => Etype);
      El := O_Fnode (Fields_Top);
   end New_Subrecord_Field;

   procedure Finish_Record_Subtype
     (Elements : in out O_Element_Sublist; Res : out O_Tnode) is
   begin Res := Elements.Tnode; end Finish_Record_Subtype;

   procedure New_Uncomplete_Record_Type (Res : out O_Tnode) is
   begin Res := New_Type (Wk_Memory, 0); end New_Uncomplete_Record_Type;

   procedure Start_Uncomplete_Record_Type
     (Res : O_Tnode; Elements : out O_Element_List) is
   begin Elements := (Tnode => Res); end Start_Uncomplete_Record_Type;

   procedure Start_Union_Type (Elements : out O_Element_List) is
   begin Elements := (Tnode => New_Type (Wk_Memory, 0)); end Start_Union_Type;

   procedure New_Union_Field
     (Elements : in out O_Element_List; El : out O_Fnode;
      Ident : O_Ident; Etype : O_Tnode)
   is
      pragma Unreferenced (Ident);
      T  : constant O_Tnode := Elements.Tnode;
      Sz : constant Natural :=
             (if Etype = 0 then 4 else Types (Natural (Etype)).Sz);
   begin
      Fields_Top := Fields_Top + 1;
      Fields (Fields_Top) := (Offset => 0, Ftype => Etype);
      if Sz > Types (Natural (T)).Sz then Types (Natural (T)).Sz := Sz; end if;
      El := O_Fnode (Fields_Top);
   end New_Union_Field;

   procedure Finish_Union_Type
     (Elements : in out O_Element_List; Res : out O_Tnode) is
   begin Res := Elements.Tnode; end Finish_Union_Type;

   function New_Access_Type (Dtype : O_Tnode) return O_Tnode is
      pragma Unreferenced (Dtype);
   begin return New_Type (Wk_I32, 4); end New_Access_Type;

   procedure Finish_Access_Type (Atype : O_Tnode; Dtype : O_Tnode) is
      pragma Unreferenced (Atype, Dtype); begin null; end Finish_Access_Type;

   function New_Array_Type (El_Type : O_Tnode; Index_Type : O_Tnode)
     return O_Tnode is
      pragma Unreferenced (El_Type, Index_Type);
   begin return New_Type (Wk_Memory, 0); end New_Array_Type;

   function New_Array_Subtype
     (Atype : O_Tnode; El_Type : O_Tnode; Length : O_Cnode) return O_Tnode
   is
      pragma Unreferenced (Atype);
      El_Sz : constant Natural :=
                (if El_Type = 0 then 4 else Types (Natural (El_Type)).Sz);
      --  Pull the element count out of the Cnode constant. Without it the
      --  subtype's byte-size was set to the size of a SINGLE element, which
      --  made every memcpy / aggregate copy stop after one cell and the
      --  rest of any vector value stay at its default 0/U.
      Len : constant Natural :=
                (if Length = 0 then 1
                 else Natural (Cnodes (Natural (Length)).Val));
      --  Guard against pathological inputs (zero-length or runaway).
      Safe_Len : constant Natural :=
                (if Len = 0 then 1
                 elsif Len > 4096 then 4096
                 else Len);
   begin return New_Type (Wk_Memory, El_Sz * Safe_Len); end New_Array_Subtype;

   function New_Unsigned_Type (Size : Natural) return O_Tnode is
   begin
      if Size <= 32 then return New_Type (Wk_I32, Size / 8);
      else return New_Type (Wk_I64, 8); end if;
   end New_Unsigned_Type;

   function New_Signed_Type (Size : Natural) return O_Tnode is
   begin
      if Size <= 32 then return New_Type (Wk_I32, Size / 8);
      else return New_Type (Wk_I64, 8); end if;
   end New_Signed_Type;

   function New_Float_Type return O_Tnode is
   begin return New_Type (Wk_F64, 8); end New_Float_Type;

   procedure New_Boolean_Type
     (Res : out O_Tnode; False_Id : O_Ident; False_E : out O_Cnode;
      True_Id : O_Ident; True_E : out O_Cnode)
   is
      pragma Unreferenced (False_Id, True_Id);
      T : constant O_Tnode := New_Type (Wk_I32, 4);
   begin
      Res := T; False_E := New_Cnode (0, Wk_I32); True_E := New_Cnode (1, Wk_I32);
   end New_Boolean_Type;

   procedure Start_Enum_Type (List : out O_Enum_List; Size : Natural) is
      pragma Unreferenced (Size);
   begin List := (Tnode => New_Type (Wk_I32, 4), Count => 0); end Start_Enum_Type;

   procedure New_Enum_Literal
     (List : in out O_Enum_List; Ident : O_Ident; Res : out O_Cnode)
   is
      pragma Unreferenced (Ident);
   begin
      Res := New_Cnode (Integer_64 (List.Count), Wk_I32);
      List.Count := List.Count + 1;
   end New_Enum_Literal;

   procedure Finish_Enum_Type (List : in out O_Enum_List; Res : out O_Tnode) is
   begin Res := List.Tnode; end Finish_Enum_Type;

   ---------------------------------------------------------------------------
   --  Literals
   ---------------------------------------------------------------------------

   function New_Signed_Literal (Ltype : O_Tnode; Value : Integer_64)
     return O_Cnode is
   begin
      return New_Cnode (Value, Wat_Kind_Of (Ltype));
   end New_Signed_Literal;

   function New_Unsigned_Literal (Ltype : O_Tnode; Value : Unsigned_64)
     return O_Cnode is
      V : Integer_64;
   begin
      if Value <= Unsigned_64 (Integer_64'Last) then
         V := Integer_64 (Value);
      else
         V := Integer_64'Last;
      end if;
      return New_Cnode (V, Wat_Kind_Of (Ltype));
   end New_Unsigned_Literal;

   function New_Float_Literal (Ltype : O_Tnode; Value : IEEE_Float_64)
     return O_Cnode is
   begin
      return New_Cnode_F (Long_Float (Value), Wat_Kind_Of (Ltype));
   end New_Float_Literal;

   function New_Null_Access (Ltype : O_Tnode) return O_Cnode is
   begin return New_Cnode (0, Wat_Kind_Of (Ltype)); end New_Null_Access;

   function New_Default_Value (Ltype : O_Tnode) return O_Cnode is
   begin return New_Cnode (0, Wat_Kind_Of (Ltype)); end New_Default_Value;

   --  Aggregate builders – stubs; composites live in linear memory
   procedure Start_Record_Aggr (List : out O_Record_Aggr_List; Atype : O_Tnode)
   is pragma Unreferenced (Atype); begin List := (Cnode => 0); end Start_Record_Aggr;
   procedure New_Record_Aggr_El (List : in out O_Record_Aggr_List; Value : O_Cnode)
   is pragma Unreferenced (Value); begin null; end New_Record_Aggr_El;
   procedure Finish_Record_Aggr (List : in out O_Record_Aggr_List; Res : out O_Cnode)
   is begin Res := List.Cnode; end Finish_Record_Aggr;

   procedure Start_Array_Aggr
     (List : out O_Array_Aggr_List; Atype : O_Tnode; Len : Unsigned_32)
   is pragma Unreferenced (Atype, Len); begin List := (Cnode => 0); end Start_Array_Aggr;
   procedure New_Array_Aggr_El (List : in out O_Array_Aggr_List; Value : O_Cnode)
   is pragma Unreferenced (Value); begin null; end New_Array_Aggr_El;
   procedure Finish_Array_Aggr (List : in out O_Array_Aggr_List; Res : out O_Cnode)
   is begin Res := List.Cnode; end Finish_Array_Aggr;

   function New_Union_Aggr (Atype : O_Tnode; Field : O_Fnode; Value : O_Cnode)
     return O_Cnode is
      pragma Unreferenced (Atype, Field, Value);
   begin return New_Cnode (0, Wk_I32); end New_Union_Aggr;

   function New_Sizeof (Atype : O_Tnode; Rtype : O_Tnode) return O_Cnode is
      Sz : constant Natural := (if Atype = 0 then 4 else Types (Natural (Atype)).Sz);
   begin return New_Cnode (Integer_64 (Sz), Wat_Kind_Of (Rtype)); end New_Sizeof;

   function New_Record_Sizeof (Atype : O_Tnode; Rtype : O_Tnode) return O_Cnode is
   begin return New_Sizeof (Atype, Rtype); end New_Record_Sizeof;

   function New_Alignof (Atype : O_Tnode; Rtype : O_Tnode) return O_Cnode is
      pragma Unreferenced (Atype);
   begin return New_Cnode (4, Wat_Kind_Of (Rtype)); end New_Alignof;

   function New_Offsetof (Atype : O_Tnode; Field : O_Fnode; Rtype : O_Tnode)
     return O_Cnode is
      pragma Unreferenced (Atype);
   begin
      return New_Cnode (Integer_64 (Fields (Natural (Field)).Offset),
                        Wat_Kind_Of (Rtype));
   end New_Offsetof;

   function New_Subprogram_Address (Subprg : O_Dnode; Atype : O_Tnode)
     return O_Cnode is
      pragma Unreferenced (Atype);
   begin
      return New_Cnode (Integer_64 (Decls (Natural (Subprg)).Idx), Wk_I32);
   end New_Subprogram_Address;

   function New_Global_Address (Lvalue : O_Gnode; Atype : O_Tnode) return O_Cnode is
      pragma Unreferenced (Lvalue, Atype);
   begin return New_Cnode (0, Wk_I32); end New_Global_Address;

   function New_Global_Unchecked_Address (Lvalue : O_Gnode; Atype : O_Tnode)
     return O_Cnode is
      pragma Unreferenced (Lvalue, Atype);
   begin return New_Cnode (0, Wk_I32); end New_Global_Unchecked_Address;

   ---------------------------------------------------------------------------
   --  Expressions
   ---------------------------------------------------------------------------

   function New_Lit (Lit : O_Cnode) return O_Enode is
   begin
      if Lit = 0 then
         return New_Expr ((Kind => Ek_Zero, others => <>));
      end if;
      declare
         C : Cnode_Entry renames Cnodes (Natural (Lit));
         K : constant Expr_Kind := Cnode_Expr_Kind (Lit);
         T : O_Tnode := 0;
      begin
         case C.Kind is
            when Wk_I32 | Wk_Memory =>
               T := New_Type (Wk_I32, 4);
               return New_Expr ((Kind => K, Ival => C.Val, Etype => T,
                                  others => <>));
            when Wk_I64 =>
               T := New_Type (Wk_I64, 8);
               return New_Expr ((Kind => K, Ival => C.Val, Etype => T,
                                  others => <>));
            when Wk_F64 =>
               T := New_Type (Wk_F64, 8);
               return New_Expr ((Kind => K, Fval => C.Fval, Etype => T,
                                  others => <>));
         end case;
      end;
   end New_Lit;

   function New_Dyadic_Op (Kind : ON_Dyadic_Op_Kind; Left, Right : O_Enode)
     return O_Enode is
   begin
      return New_Expr ((Kind  => Ek_Binop,
                        Arg1  => Left,
                        Arg2  => Right,
                        Op    => ON_Op_Kind (Kind),
                        Etype => (if Left = 0 then O_Tnode (0)
                                  else Exprs (Natural (Left)).Etype),
                        others => <>));
   end New_Dyadic_Op;

   function New_Monadic_Op (Kind : ON_Monadic_Op_Kind; Operand : O_Enode)
     return O_Enode is
   begin
      return New_Expr ((Kind  => Ek_Monop,
                        Arg1  => Operand,
                        Op    => ON_Op_Kind (Kind),
                        Etype => (if Operand = 0 then O_Tnode (0)
                                  else Exprs (Natural (Operand)).Etype),
                        others => <>));
   end New_Monadic_Op;

   function New_Compare_Op
     (Kind : ON_Compare_Op_Kind; Left, Right : O_Enode; Ntype : O_Tnode)
     return O_Enode is
   begin
      return New_Expr ((Kind  => Ek_Compare,
                        Arg1  => Left,
                        Arg2  => Right,
                        Op    => ON_Op_Kind (Kind),
                        Etype => Ntype,
                        others => <>));
   end New_Compare_Op;

   function New_Indexed_Element (Arr : O_Lnode; Index : O_Enode) return O_Lnode is
   begin
      return New_Lval ((Kind => Lv_Index, Base => Arr, Idx_E => Index,
                        others => <>));
   end New_Indexed_Element;

   function New_Slice (Arr : O_Lnode; Res_Type : O_Tnode; Index : O_Enode)
     return O_Lnode is
      pragma Unreferenced (Res_Type);
   begin
      return New_Lval ((Kind => Lv_Index, Base => Arr, Idx_E => Index,
                        others => <>));
   end New_Slice;

   function New_Selected_Element (Rec : O_Lnode; El : O_Fnode) return O_Lnode is
   begin
      return New_Lval ((Kind => Lv_Field, Base => Rec, Field => El, others => <>));
   end New_Selected_Element;

   function New_Global_Selected_Element (Rec : O_Gnode; El : O_Fnode)
     return O_Gnode is
      pragma Unreferenced (Rec, El); begin return 0; end New_Global_Selected_Element;

   function New_Access_Element (Acc : O_Enode) return O_Lnode is
   begin
      return New_Lval ((Kind => Lv_Deref, Base => O_Lnode (Acc), others => <>));
   end New_Access_Element;

   function New_Convert_Ov (Val : O_Enode; Rtype : O_Tnode) return O_Enode is
      Src_Kind : constant Wat_Kind :=
        (if Val = 0 then Wk_I32
         elsif Exprs (Natural (Val)).Etype = 0 then Wk_I32
         else Types (Natural (Exprs (Natural (Val)).Etype)).Kind);
      Dst_Kind : constant Wat_Kind :=
        (if Rtype = 0 then Wk_I32
         else Types (Natural (Rtype)).Kind);
   begin
      if Src_Kind = Wk_I64 and Dst_Kind = Wk_I32 then
         --  Truncate i64 -> i32 using i32.wrap_i64
         return New_Expr ((Kind  => Ek_Wrap_I32,
                           Arg1  => Val,
                           Etype => Rtype,
                           others => <>));
      end if;
      --  No-op for same-kind or other conversions
      return Val;
   end New_Convert_Ov;

   function New_Convert (Val : O_Enode; Rtype : O_Tnode) return O_Enode is
   begin return New_Convert_Ov (Val, Rtype); end New_Convert;

   function New_Address (Lvalue : O_Lnode; Atype : O_Tnode) return O_Enode is
      pragma Unreferenced (Atype);
   begin
      --  Encode the lvalue in Arg1 so emission can pull its real address
      --  (via Lval_Addr_S) instead of always returning (i32.const 0).
      return New_Expr ((Kind => Ek_Addr_Lvalue,
                        Arg1 => O_Enode (Lvalue),
                        others => <>));
   end New_Address;

   function New_Unchecked_Address (Lvalue : O_Lnode; Atype : O_Tnode)
     return O_Enode is
   begin return New_Address (Lvalue, Atype); end New_Unchecked_Address;

   function New_Value (Lvalue : O_Lnode) return O_Enode is
   begin
      return New_Expr ((Kind => Ek_Load,
                        Arg1 => O_Enode (Lvalue),   -- encode lval as enode
                        others => <>));
   end New_Value;

   function New_Obj_Value (Obj : O_Dnode) return O_Enode is
   begin
      case Decls (Natural (Obj)).Kind is
         when Dk_Local =>
            return New_Expr ((Kind => Ek_Local_Get, Decl => Obj,
                              Etype => Decls (Natural (Obj)).Tnode,
                              others => <>));
         when Dk_Global | Dk_Const =>
            return New_Expr ((Kind => Ek_Global_Get, Decl => Obj,
                              Etype => Decls (Natural (Obj)).Tnode,
                              others => <>));
         when Dk_Func =>
            return New_Expr ((Kind => Ek_Func_Idx, Decl => Obj, others => <>));
      end case;
   end New_Obj_Value;

   function New_Obj (Obj : O_Dnode) return O_Lnode is
   begin
      return New_Lval
        ((Kind  => (if Decls (Natural (Obj)).Kind = Dk_Local
                    then Lv_Local else Lv_Global),
          Decl  => Obj,
          Tnode => Decls (Natural (Obj)).Tnode,
          others => <>));
   end New_Obj;

   function New_Global (Decl : O_Dnode) return O_Gnode is
   begin return O_Gnode (Decl); end New_Global;

   function New_Alloca (Rtype : O_Tnode; Size : O_Enode) return O_Enode is
      pragma Unreferenced (Rtype, Size);
   begin
      return New_Expr ((Kind => Ek_Global_Get, Decl => 0, others => <>));
   end New_Alloca;

   ---------------------------------------------------------------------------
   --  Declarations
   ---------------------------------------------------------------------------

   procedure New_Type_Decl (Ident : O_Ident; Atype : O_Tnode) is
      pragma Unreferenced (Ident, Atype); begin null; end New_Type_Decl;
   procedure New_Debug_Filename_Decl (Filename : String) is
      pragma Unreferenced (Filename); begin null; end New_Debug_Filename_Decl;
   procedure New_Debug_Line_Decl (Line : Natural) is
      pragma Unreferenced (Line); begin null; end New_Debug_Line_Decl;
   procedure New_Debug_Comment_Decl (Comment : String) is
   begin
      Append (Globals_Buf, "  ;; " & Comment & ASCII.LF);
      if Length (Globals_Buf) > 50_000_000 then
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
            "ABORT: Globals_Buf >50MB in comment, len=" & Natural'Image (Length (Globals_Buf)));
         Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
         raise Program_Error with "Globals_Buf overflow";
      end if;
   end New_Debug_Comment_Decl;

   procedure New_Const_Decl (Res : out O_Dnode; Ident : O_Ident;
                             Storage : O_Storage; Atype : O_Tnode) is
      pragma Unreferenced (Storage);
      Nam : constant String := Get_String (Ident);
      Wt  : constant String := Wat_Type_Of (Atype);
   begin
      Res := New_Decl (Dk_Const, Nam, Atype);
      Append (Globals_Buf, "  (global $" & Nam & " " & Wt &
              " (" & Wt & ".const 0))" & ASCII.LF);
      if Length (Globals_Buf) > 50_000_000 then
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
            "ABORT: Globals_Buf >50MB in const, len=" & Natural'Image (Length (Globals_Buf)));
         Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
         raise Program_Error with "Globals_Buf overflow";
      end if;
   end New_Const_Decl;

   procedure Start_Init_Value (Decl : in out O_Dnode) is
      pragma Unreferenced (Decl); begin null; end Start_Init_Value;
   procedure Finish_Init_Value (Decl : in out O_Dnode; Val : O_Cnode) is
      pragma Unreferenced (Decl, Val); begin null; end Finish_Init_Value;

   procedure New_Var_Decl (Res : out O_Dnode; Ident : O_Ident;
                           Storage : O_Storage; Atype : O_Tnode) is
      Nam : constant String := Get_String (Ident);
      Wt  : constant String := Wat_Type_Of (Atype);
      --  For Wk_Memory locals (records / arrays), GHDL'''s upper layers expect
      --  the local to hold a POINTER to caller-or-locally-allocated storage,
      --  and they often take its address via New_Unchecked_Address. The standard
      --  mcode / llvm back-ends allocate that storage automatically. We do the
      --  same here: emit a stack2_allocate call as the first statement of the
      --  function body so each composite local has backing memory.
      Auto_Alloc : constant Boolean :=
        Storage = O_Storage_Local
        and then Atype /= 0
        and then Wat_Kind_Of (Atype) = Wk_Memory
        and then Types (Natural (Atype)).Sz > 0;
      Alloc_Sz : constant Natural :=
        (if Auto_Alloc then Natural'Max (Types (Natural (Atype)).Sz, 32) else 0);
      AlImg : constant String := Natural'Image (Alloc_Sz);
      AlTrim : constant String :=
        (if AlImg'Length >= 2 then AlImg (AlImg'First + 1 .. AlImg'Last) else AlImg);
   begin
      if Storage = O_Storage_Local then
         Res := New_Decl (Dk_Local, Nam, Atype);
         if In_Func then
            --  Guard against redeclaration (Open/Close_Local_Temp reuses names)
            if Index (Cur_Func.Locals, "$" & Nam & " ") = 0 then
               Append (Cur_Func.Locals,
                       "    (local $" & Nam & " " & Wt & ")" & ASCII.LF);
               if Auto_Alloc then
                  Append (Cur_Func.Body_Buf,
                          "    (local.set $" & Nam &
                          " (call $__ghdl_stack2_allocate (i32.const " & AlTrim &
                          ")))" & ASCII.LF);
               end if;
            end if;
            if Length (Cur_Func.Locals) > 10_000_000 then
               Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
                  "ABORT: Locals >10MB in func " & Cur_Func_Name &
                  " len=" & Natural'Image (Length (Cur_Func.Locals)));
               Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
               raise Program_Error with "Locals overflow";
            end if;
         end if;
      else
         Res := New_Decl (Dk_Global, Nam, Atype);
         Append (Globals_Buf, "  (global $" & Nam & " (mut " & Wt & ")" &
                 " (" & Wt & ".const 0))" & ASCII.LF);
         if Length (Globals_Buf) > 50_000_000 then
            Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
               "ABORT: Globals_Buf >50MB in var, len=" &
               Natural'Image (Length (Globals_Buf)));
            Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
            raise Program_Error with "Globals_Buf global overflow";
         end if;
         if Natural (Decls_Top) mod 1000 = 1 then
            Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
               "WASM: decls=" & Natural'Image (Decls_Top) &
               " globals_len=" & Natural'Image (Length (Globals_Buf)));
            Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
         end if;
      end if;
   end New_Var_Decl;

   procedure New_Var_Body (Var : O_Dnode; Storage : O_Storage; Atype : O_Tnode) is
      pragma Unreferenced (Var, Storage, Atype); begin null; end New_Var_Body;

   procedure Start_Function_Decl (Interfaces : out O_Inter_List;
                                  Ident : O_Ident; Storage : O_Storage;
                                  Rtype : O_Tnode) is
      Nam : constant String := Get_String (Ident);
      Off : constant Natural := Store_Name (Nam);
      --  Phase 4: also export any user-design function. The translation
      --  layer marks user processes O_Storage_Private but the browser-
      --  side runtime needs to invoke them, so we override here. Names
      --  starting with 'work__' are the design's own code (testbench,
      --  RTL processes, etc.); everything else only exports if Storage
      --  is explicitly Public.
      Public : constant Boolean :=
        Storage = O_Storage_Public
        or else (Nam'Length >= 6 and then Nam (Nam'First .. Nam'First + 5) = "work__");
   begin
      Pending_Func_Params := Null_Unbounded_String;
      Decls_Top  := Decls_Top + 1;
      Func_Count := Func_Count + 1;
      Decls (Decls_Top) := (Kind => Dk_Func, Tnode => Rtype,
                            Idx => Func_Count, Name_Off => Off,
                            Name_Len => Nam'Length,
                            Is_Public => Public,
                            Params => Ada.Strings.Unbounded.Null_Unbounded_String,
                            Saved_Params => Ada.Strings.Unbounded.Null_Unbounded_String,
                            Has_Body => False);
      Interfaces := (Func => O_Dnode (Decls_Top));
   end Start_Function_Decl;

   procedure Start_Procedure_Decl (Interfaces : out O_Inter_List;
                                   Ident : O_Ident; Storage : O_Storage) is
   begin
      Start_Function_Decl (Interfaces, Ident, Storage, O_Tnode_Null);
   end Start_Procedure_Decl;

   procedure New_Interface_Decl (Interfaces : in out O_Inter_List;
                                 Res : out O_Dnode; Ident : O_Ident;
                                 Atype : O_Tnode) is
      Nam : constant String := Get_String (Ident);
      Wt  : constant String := Wat_Type_Of (Atype);
   begin
      Res := New_Decl (Dk_Local, Nam, Atype);
      if In_Func then
         Append (Cur_Func.Params, " (param $" & Nam & " " & Wt & ")");
      else
         --  Store param in the declaring function's Decl_Entry so that
         --  concurrent declarations (before any body is opened) don't
         --  overwrite each other via a single global buffer.
         Append (Decls (Natural (Interfaces.Func)).Params,
                 " (param $" & Nam & " " & Wt & ")");
      end if;
   end New_Interface_Decl;

   procedure Finish_Subprogram_Decl (Interfaces : in out O_Inter_List;
                                     Res : out O_Dnode) is
   begin Res := Interfaces.Func; end Finish_Subprogram_Decl;

   procedure Start_Subprogram_Body (Func : O_Dnode) is
   begin
      Pending_Decl_Idx := Func;
      In_Func   := True;
      Exprs_Top := 0;
      Lvals_Top := 0;
      Label_Top := 0;
      Cur_Func  := (Name_Off  => Decls (Natural (Func)).Name_Off,
                    Name_Len  => Decls (Natural (Func)).Name_Len,
                    Ret_Type  => Decls (Natural (Func)).Tnode,
                    Params    => Decls (Natural (Func)).Params,
                    Locals    => Null_Unbounded_String,
                    Body_Buf  => Null_Unbounded_String);
      Decls (Natural (Func)).Saved_Params := Decls (Natural (Func)).Params;
      Decls (Natural (Func)).Params := Null_Unbounded_String;
      Indent := 4;
   end Start_Subprogram_Body;

   --  Strip duplicate "(param $X t)" entries from a Params string.
   --  Several codegen paths call New_Interface_Decl repeatedly with the
   --  same INSTANCE param (notably COMP_ELAB) producing
   --  "(param $INSTANCE i32) (param $INSTANCE i32) ..." which wat2wasm
   --  rejects as duplicate-parameter-name.
   function Dedupe_Params (P : String) return String is
      use Ada.Strings.Unbounded;
      Result : Unbounded_String;
      I, J, K : Natural;
      Token : String (1 .. 256);
      Tlen  : Natural;
      Seen  : Unbounded_String;
   begin
      I := P'First;
      while I <= P'Last loop
         if I + 6 <= P'Last
           and then P (I .. I + 6) = " (param"
         then
            J := I;
            K := I + 7;
            while K <= P'Last and then P (K) /= ')' loop
               K := K + 1;
            end loop;
            if K <= P'Last then
               Tlen := K - J + 1;
               if Tlen <= 256 then
                  Token (1 .. Tlen) := P (J .. K);
                  if Index (Seen, Token (1 .. Tlen)) = 0 then
                     Append (Result, Token (1 .. Tlen));
                     Append (Seen, Token (1 .. Tlen) & "|");
                  end if;
               end if;
               I := K + 1;
            else
               I := P'Last + 1;
            end if;
         else
            Append (Result, P (I));
            I := I + 1;
         end if;
      end loop;
      return To_String (Result);
   end Dedupe_Params;

   procedure Finish_Subprogram_Body is
      Nam : constant String := Cur_Func_Name;
      Ret : constant O_Tnode := Cur_Func.Ret_Type;
   begin
      Append (Funcs_Buf, "  (func $" & Nam);
      Append (Funcs_Buf, Dedupe_Params (To_String (Cur_Func.Params)));
      if Ret /= 0 then
         Append (Funcs_Buf, " (result " & Wat_Type_Of (Ret) & ")");
      end if;
      Append (Funcs_Buf, ASCII.LF);
      Append (Funcs_Buf, To_String (Cur_Func.Locals));
      Append (Funcs_Buf, To_String (Cur_Func.Body_Buf));
      if Ret /= 0 then
         Append (Funcs_Buf, "    (unreachable)" & ASCII.LF);
      end if;
      Append (Funcs_Buf, "  )" & ASCII.LF);
      Cur_Func.Params   := Null_Unbounded_String;
      Cur_Func.Locals   := Null_Unbounded_String;
      Cur_Func.Body_Buf := Null_Unbounded_String;
      Ada.Text_IO.Flush;
      Debug_Func_Count := Debug_Func_Count + 1;
      if Debug_Func_Count mod 100 = 1 then
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
            "WASM: func#" & Natural'Image (Debug_Func_Count) &
            " " & Nam & " emits=" & Natural'Image (Debug_Emit_Count));
         Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
         Debug_Emit_Count := 0;
      end if;
      In_Func := False;
      Indent  := 2;
      Decls (Natural (Pending_Decl_Idx)).Has_Body := True;
      --  Phase 5: record this body in the function-pointer table so the
      --  host can resolve indices returned by New_Subprogram_Address.
      declare
         Idx : constant Natural := Decls (Natural (Pending_Decl_Idx)).Idx;
         IdxImg : constant String := Natural'Image (Idx);
         IdxTrim : constant String := IdxImg (IdxImg'First + 1 .. IdxImg'Last);
      begin
         Append (Elem_Buf,
                 "  (elem (i32.const " & IdxTrim & ") $" & Nam & ")" & ASCII.LF);
         if Idx > Max_Body_Idx then
            Max_Body_Idx := Idx;
         end if;
      end;
      --  Phase 4: emit a (export ...) line for public functions so a
      --  host can drive elaboration and access process entry points.
      if Decls (Natural (Pending_Decl_Idx)).Is_Public then
         declare
            Nm : constant String :=
              Ident_Buf (Decls (Natural (Pending_Decl_Idx)).Name_Off
                       .. Decls (Natural (Pending_Decl_Idx)).Name_Off
                            + Decls (Natural (Pending_Decl_Idx)).Name_Len - 1);
         begin
            Append (Exports_Buf,
                    "  (export """ & Nm & """ (func $" & Nm & "))" & ASCII.LF);
         end;
      end if;
   end Finish_Subprogram_Body;

   ---------------------------------------------------------------------------
   --  Statements
   ---------------------------------------------------------------------------

   procedure New_Debug_Line_Stmt (Line : Natural) is
      pragma Unreferenced (Line); begin null; end New_Debug_Line_Stmt;
   procedure New_Debug_Comment_Stmt (Comment : String) is
   begin Emit_Ln (";; " & Comment); end New_Debug_Comment_Stmt;

   procedure Start_Declare_Stmt is
   begin Emit_Ln (";; {"); Indent := Indent + 2; end Start_Declare_Stmt;
   procedure Finish_Declare_Stmt is
   begin Indent := Indent - 2; Emit_Ln (";; }"); end Finish_Declare_Stmt;

   procedure Start_Association (Assocs : out O_Assoc_List; Subprg : O_Dnode) is
   begin
      Assocs := (Func => Subprg, Count => 0);
      Pending_Call_Args := Null_Unbounded_String;
   end Start_Association;

   procedure New_Association (Assocs : in out O_Assoc_List; Val : O_Enode) is
   begin
      Assocs.Count := Assocs.Count + 1;
      Append (Pending_Call_Args, " " & Expr_S (Val));
   end New_Association;

   function New_Function_Call (Assocs : O_Assoc_List) return O_Enode is
      Result : O_Enode;
   begin
      Result := New_Expr ((Kind => Ek_Call, Decl => Assocs.Func,
                           Args => Pending_Call_Args, others => <>));
      Pending_Call_Args := Null_Unbounded_String;
      return Result;
   end New_Function_Call;

   procedure New_Procedure_Call (Assocs : in out O_Assoc_List) is
   begin
      Emit_Ln ("(call $" & Get_Name (Assocs.Func) &
               To_String (Pending_Call_Args) & ")");
      Pending_Call_Args := Null_Unbounded_String;
   end New_Procedure_Call;

   procedure New_Assign_Stmt (Target : O_Lnode; Value : O_Enode) is
   begin
      Emit_Ln (Lval_Write_S (Target, Expr_S (Value)));
   end New_Assign_Stmt;

   procedure New_Return_Stmt (Value : O_Enode) is
   begin Emit_Ln ("(return " & Expr_S (Value) & ")"); end New_Return_Stmt;

   procedure New_Return_Stmt is
   begin Emit_Ln ("(return)"); end New_Return_Stmt;

   procedure Start_If_Stmt (Block : in out O_If_Block; Cond : O_Enode) is
   begin
      Emit_Ln ("(if " & Expr_S (Cond));
      Emit_Ln ("  (then");
      Block := (Depth => Indent);
      Indent := Indent + 4;
   end Start_If_Stmt;

   procedure New_Else_Stmt (Block : in out O_If_Block) is
   begin
      Indent := Block.Depth;
      Emit_Ln ("  )");
      Emit_Ln ("  (else");
      Indent := Block.Depth + 4;
   end New_Else_Stmt;

   procedure Finish_If_Stmt (Block : in out O_If_Block) is
   begin
      Indent := Block.Depth;
      Emit_Ln ("  ))");
   end Finish_If_Stmt;

   procedure Start_Loop_Stmt (Label : out O_Snode) is
      Lbl : constant Natural := New_Label;
   begin
      Label_Top := Label_Top + 1;
      Labels (Label_Top) := Lbl;
      Label := O_Snode (Lbl);
      Emit_Ln ("(block $blk" & Img (Lbl));
      Emit_Ln (" (loop $loop" & Img (Lbl));
      Indent := Indent + 4;
   end Start_Loop_Stmt;

   procedure Finish_Loop_Stmt (Label : in out O_Snode) is
      Lbl : constant Natural := Natural (Label);
   begin
      Indent := Indent - 4;
      Emit_Ln ("(br $loop" & Img (Lbl) & ")");
      Emit_Ln ("))");
      Label_Top := Label_Top - 1;
   end Finish_Loop_Stmt;

   procedure New_Exit_Stmt (L : O_Snode) is
   begin Emit_Ln ("(br $blk" & Img (Natural (L)) & ")"); end New_Exit_Stmt;
   procedure New_Next_Stmt (L : O_Snode) is
   begin Emit_Ln ("(br $loop" & Img (Natural (L)) & ")"); end New_Next_Stmt;

   --  Phase 4b: real case-statement compilation.
   --  Wrapper structure:
   --     (block $case_end_N
   --       (if (i32.eq <value> <choice0>) (then ...body... (br $case_end_N)))
   --       (if (i32.eq <value> <choice1>) (then ...body... (br $case_end_N)))
   --       ...default body emitted unconditionally as last arm...
   --     )
   --  Each (if ...) closes itself once the next arm starts (or the case ends),
   --  via Close_Open_Arm.

   procedure Close_Open_Arm (Block : in out O_Case_Block) is
   begin
      if Block.Has_Open_Arm then
         Emit_Ln ("(br $case_end_" & Img (Block.Label_Idx) & ")");
         Indent := Indent - 4;
         Emit_Ln ("))");
         Block.Has_Open_Arm := False;
      end if;
   end Close_Open_Arm;

   procedure Start_Case_Stmt (Block : in out O_Case_Block; Value : O_Enode) is
   begin
      Case_Counter := Case_Counter + 1;
      Block := (Depth        => Indent,
                Value_Expr   => Ada.Strings.Unbounded.To_Unbounded_String
                                  (Expr_S (Value)),
                Label_Idx    => Case_Counter,
                Has_Open_Arm => False);
      Emit_Ln ("(block $case_end_" & Img (Case_Counter));
      Indent := Indent + 2;
   end Start_Case_Stmt;

   procedure Start_Choice (Block : in out O_Case_Block) is
      pragma Unreferenced (Block); begin null; end Start_Choice;

   procedure New_Expr_Choice (Block : in out O_Case_Block; Expr : O_Cnode) is
   begin
      Close_Open_Arm (Block);
      Emit_Ln ("(if (i32.eq "
               & Ada.Strings.Unbounded.To_String (Block.Value_Expr)
               & " (i32.const " & I64_Img (Cnodes (Natural (Expr)).Val) & "))");
      Emit_Ln ("  (then");
      Indent := Indent + 4;
      Block.Has_Open_Arm := True;
   end New_Expr_Choice;

   procedure New_Range_Choice (Block : in out O_Case_Block; Low, High : O_Cnode) is
   begin
      Close_Open_Arm (Block);
      Emit_Ln ("(if (i32.and (i32.ge_s "
               & Ada.Strings.Unbounded.To_String (Block.Value_Expr)
               & " (i32.const " & I64_Img (Cnodes (Natural (Low)).Val) & "))");
      Emit_Ln ("              (i32.le_s "
               & Ada.Strings.Unbounded.To_String (Block.Value_Expr)
               & " (i32.const " & I64_Img (Cnodes (Natural (High)).Val) & ")))");
      Emit_Ln ("  (then");
      Indent := Indent + 4;
      Block.Has_Open_Arm := True;
   end New_Range_Choice;

   procedure New_Default_Choice (Block : in out O_Case_Block) is
   begin
      Close_Open_Arm (Block);
      --  Default body emits unconditionally; no wrap. Should be the last arm.
      Block.Has_Open_Arm := False;
   end New_Default_Choice;

   procedure Finish_Choice (Block : in out O_Case_Block) is
      pragma Unreferenced (Block); begin null; end Finish_Choice;

   procedure Finish_Case_Stmt (Block : in out O_Case_Block) is
   begin
      Close_Open_Arm (Block);
      Indent := Block.Depth;
      Emit_Ln (")");
   end Finish_Case_Stmt;

end Ortho_Wasm;
