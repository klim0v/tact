open Base
open Lang_types

let int_type =
  (* memoize struct ids for equality *)
  let struct_ids = Hashtbl.create (module Int)
  (* memoize constructor funs for equality *)
  and int_constructor_funs = Hashtbl.create (module Int) in
  (* int's newtype *)
  let rec int_type_s bits =
    let struct_id =
      Hashtbl.find_or_add struct_ids bits ~default:(fun () ->
          let c = !struct_counter in
          struct_counter := c + 1 ;
          c )
    in
    { struct_fields = [("integer", {field_type = Value (Type IntegerType)})];
      struct_methods = [("new", int_type_s_new bits)];
      struct_id }
  and int_type_s_new bits =
    let function_impl =
      Hashtbl.find_or_add int_constructor_funs bits ~default:(fun () ->
          builtin_fun @@ constructor_impl bits )
    in
    { function_params = [("integer", Value (Type IntegerType))];
      (* TODO: figure out how to represent Self *)
      function_returns = Hole;
      function_impl = BuiltinFn function_impl }
  and constructor_impl bits p = function
    | [Integer i] ->
        let numbits = Zint.numbits i in
        let i =
          (* FIXME: or should we raise an error here? *)
          if numbits > bits then
            let extract =
              if Zint.(lt i Zint.zero) then Zint.signed_extract
              else Zint.extract
            in
            extract i 0 (numbits - bits)
          else i
        in
        Value (StructInstance (int_type_s bits, [("integer", Integer i)]))
    | _ ->
        (* TODO: raise an error instead *)
        constructor_impl bits p [Integer (Zint.of_int 0)]
  and function_impl _p = function
    | [Integer bits] ->
        Value (Struct (int_type_s @@ Z.to_int bits))
    | _ ->
        (* TODO: raise an error instead *)
        Value Void
  in
  Value
    (Function
       { function_params = [("bits", Value (Type IntegerType))];
         function_returns = Value (Struct (int_type_s 257));
         function_impl = BuiltinFn (builtin_fun function_impl) } )

let asm =
  let function_impl _p = function
    | [String code] ->
        let lexbuf = Lexing.from_string code in
        let code = Asm_parser.code Asm_lexer.token lexbuf in
        Asm code
    | _ ->
        Value Void
  in
  Value
    (Function
       { function_params = [("instructions", Value (Type StringType))];
         function_returns = Value (Type VoidType);
         function_impl = BuiltinFn (builtin_fun function_impl) } )

let default_bindings =
  [ ("asm", asm);
    ("Integer", Value (Type IntegerType));
    ("Int", int_type);
    ("Bool", Value (Builtin "Bool"));
    ("Type", Value (Builtin "Type"));
    ("Void", Value Void) ]
