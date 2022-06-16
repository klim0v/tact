%parameter<Config : Config.T>

%start <program> program

%{              
  (* This is a workaround for Dune and Menhir as discovered in https://github.com/ocaml/dune/issues/2450#issuecomment-515895672 and
   * https://github.com/ocaml/dune/issues/1504#issuecomment-434702650 that seems to fix the issue of Menhir wrongly inferring
   * the reference to Syntax.Make as Tact.Syntax.Make which makes Parser depend on Tact, which doesn't work
   *)
   module Tact = struct end
   open struct module Syntax = Syntax.Make(Config) end
   open Syntax
%}

%{
  let expand_fn_sugar params loc typ expr =
    Function (make_function_definition ~params: params
                                           ~returns: (make_located ~loc ~value: typ ())
                                           ~function_body:(make_function_body ~function_stmt:(Expr (value expr))  ())
                                           ())

  let remove_trailing_break stmts = 
    match List.rev stmts with
    | [] -> []
    | stmt :: rest ->
      (make_located ~loc:(Syntax.loc stmt) ~value:(match Syntax.value stmt with | Break s -> s | s -> s) ())::rest
    |> List.rev
  %}

%%

(* At the very top, there's a program *)
let program :=
  | stmts = block_stmt; EOF; { make_program ~stmts: (remove_trailing_break stmts) () }
  | EOF; { make_program ~stmts: [] () }


(* Binding definition

let Name = <expression>

See Expression

There is another "sugared" form of bindings for structs and functions:

```
struct S{ ... }
struct S(T: Type){v: T}
```

They are equivalent to these:

```
let S = struct { ... }
let S(T: Type) = struct {val v: T}
```

Same applies to enums, interfaces, unions and fns

*)
let let_binding ==
| located (
  LET;
  name = located(ident);
  EQUALS;
  expr = located(expr);
  { make_binding ~binding_name: name ~binding_expr: expr () }
)
| located (
  LET;
  name = located(ident);
  params = delimited_separated_trailing_list(LPAREN, function_param, COMMA, RPAREN);
  EQUALS;
  expr = located(expr);
  { make_binding ~binding_name: name
      ~binding_expr:
      (make_located ~loc: $loc ~value: (expand_fn_sugar params $loc (Reference (Ident "Type")) expr) ()) 
      ()
  }
)
let shorthand_binding(funbody) ==
| sugared_function_definition(funbody)
| located( (name, expr) = struct_definition(located(ident)); { make_binding ~binding_name: name ~binding_expr: (make_located ~loc: $loc ~value: expr ())  () })
| located( ((name, params), expr) = struct_definition(located_ident_with_params); {
  make_binding ~binding_name: name ~binding_expr: (
    make_located ~loc: $loc ~value: (expand_fn_sugar params $loc (Reference (Ident "Type")) (make_located ~loc: $loc ~value: expr ())) ()
  ) () })
| located( (name, expr) = interface_definition(located(ident)); { make_binding ~binding_name: name ~binding_expr: (make_located ~loc: $loc ~value: expr ()) () })
| located( ((name, params), expr) = interface_definition(located_ident_with_params); {
  make_binding ~binding_name: name ~binding_expr: (
    make_located ~loc: $loc ~value: (expand_fn_sugar params $loc (Reference (Ident "Interface")) (make_located ~loc: $loc ~value: expr ())) ()
  ) () })
| located( (name, expr) = enum_definition(located(ident)); { make_binding ~binding_name: name ~binding_expr: (make_located ~loc: $loc ~value: expr ()) () })
| located( ((name, params), expr) = enum_definition(located_ident_with_params); {
  make_binding ~binding_name: name ~binding_expr: ( 
    make_located ~loc: $loc ~value: (expand_fn_sugar params $loc (Reference (Ident "Type")) (make_located ~loc: $loc ~value: expr ())) ()
  ) () })
| located( (name, expr) = union_definition(located(ident)); { make_binding ~binding_name: name ~binding_expr: (make_located ~loc: $loc ~value: expr ()) () })
| located( ((name, params), expr) = union_definition(located_ident_with_params); {
  make_binding ~binding_name: name ~binding_expr: (
    make_located ~loc: $loc ~value: (expand_fn_sugar params $loc (Reference (Ident "Type")) (make_located ~loc: $loc ~value: expr ())) ()
  ) () })

let located_ident_with_params ==
   ~ = located(ident);
   ~ = params;
   <>

let sugared_function_definition(funbody) ==
   | located( (name, expr) = function_definition(located(ident), funbody); { make_binding ~binding_name: name ~binding_expr: (make_located ~loc: $loc ~value: expr ()) () })
   | located( ((name, params), expr) = function_definition(located_ident_with_params, funbody); {
     make_binding ~binding_name: name ~binding_expr: 
       (make_located ~loc: $loc
                     ~value: (expand_fn_sugar params $loc (Reference (Ident "Function")) (make_located ~loc: $loc ~value: expr ()))
                     () (* FIXME: Function type is a temp punt *)
       ) () })


(* Function definition

 fn (arg: Type, ...) [-> Type] [{
  expr
  expr
  ...
}]

*)
let function_definition(name, funbody) :=
  FN;
  n = name;
  params = delimited_separated_trailing_list(LPAREN, function_param, COMMA, RPAREN);
  returns = option(preceded(RARROW, located(fexpr)));
  body = funbody;
  { (n, Function (make_function_definition ~params:params ?returns:returns 
                    ?function_body:(Option.map (fun x -> make_function_body ~function_stmt: x ()) body)
                    ())) } 

let function_signature_binding ==
    (n, f) = function_definition(located(ident), nothing); {
    make_binding ~binding_name: n ~binding_expr: (make_located ~loc: $loc ~value: f ()) ()
  }

let function_param ==
  located (
  ~ = located(ident);
  COLON;
  ~ = located(expr);
  <>
  )

(* Function call

   name([argument,])
   <expr>([argument,])

  * Trailing commas are allowed
*)
let function_call :=
  fn = located(fexpr);
  arguments = delimited_separated_trailing_list(LPAREN, located(expr), COMMA, RPAREN);
  { FunctionCall (make_function_call ~fn: fn ~arguments: arguments ()) }

let else_ :=
  | ELSE; ~= if_; <>
  | ELSE; c = code_block; { c }

let if_ :=
  IF;
  condition = delimited(LPAREN, located(expr), RPAREN);
  body = located(code_block);
  else_ = option(located(else_));
  { If (make_if_ ~condition ~body ?else_ ()) }

let code_block :=
  | c = delimited(LBRACE, block_stmt, RBRACE); { CodeBlock c }
  | LBRACE; RBRACE; { CodeBlock [] }

let switch_branch := 
  | CASE; 
    ty = located(type_expr);
    var = located(ident);
    REARROW;
    (* TODO: what kind of stmts should be allowed here? *)
    stmt = code_block;
    { make_switch_branch ~ty ~var ~stmt () }

(*
  Switch stmt

  switch (<expr>) {
    case Type1 var => { <stmts> }
    case Type2 var => { <stmts> }
    ...
  }
*)

let switch :=
  | SWITCH; LPAREN; switch_condition = located(expr); RPAREN; LBRACE;
    branches = list(switch_branch);
    RBRACE;
    { Switch (make_switch ~switch_condition ~branches ()) }

let block_stmt :=
  | left = located(non_semicolon_stmt); right = block_stmt;
    { left :: right }
  | left = located(semicolon_stmt); SEMICOLON; right = block_stmt; 
    { left :: right }
  | left = located(semicolon_stmt); SEMICOLON; 
    { [left] }
  | left = located(stmt);
    { [make_located ~value:(Break (value left)) ~loc:(loc left) ()] }


let stmt := 
  | semicolon_stmt 
  | non_semicolon_stmt

let semicolon_stmt :=
  | ~= stmt_expr; <Expr>
  | ~= let_binding; <Let>
  | RETURN; ~= expr; <Return>

let non_semicolon_stmt :=
  | ~= shorthand_binding(some(code_block)); <Let>
  | if_
  | code_block
  | switch

(* Type expression
  
   Difference between type expression and simple expression is that in type expression
   it is not allowed to use exprs with brackets such as `if {}`, `type {}` and `fn() {}`.
 
*)
let type_expr :=
  (* can be any expr delimited by () *)
  | expr = delimited(LPAREN, expr_, RPAREN); {expr}
  (* can be an ident *)
  | ~= ident; <Reference>
  (* can be a function call *)
  | function_call

(* Expression that is valid in the statement *)
let stmt_expr :=
 | expr_
 (* can be access to the field via dot *)
 | from_expr = located(expr); DOT; to_field = located(ident); 
    {FieldAccess (make_field_access ~from_expr ~to_field ())}
| receiver = located(expr); DOT; 
  receiver_fn = located(ident);
  receiver_arguments = delimited_separated_trailing_list(LPAREN, located(expr), COMMA, RPAREN);
    {MethodCall (make_method_call ~receiver ~receiver_fn ~receiver_arguments ())}
 (* can be a type constructor *)
 | struct_constructor
 (* can be a function definition *)
 | (_, f) = function_definition(nothing, some(code_block)); { f }


(* Expression *)
let expr :=
 | expr_
 (* can be access to the field via dot *)
 | from_expr = located(expr); DOT; to_field = located(ident); 
    {FieldAccess (make_field_access ~from_expr ~to_field ())}
| receiver = located(expr); DOT; 
  receiver_fn = located(ident);
  receiver_arguments = delimited_separated_trailing_list(LPAREN, located(expr), COMMA, RPAREN);
    {MethodCall (make_method_call ~receiver ~receiver_fn ~receiver_arguments ())}
 (* can be a type constructor *)
 | struct_constructor
 (* can be a function definition *)
 | (_, f) = function_definition(nothing, option(code_block)); { f }

let fexpr :=
 | expr_
  (* can be a type constructor, in parens *)
 | delimited(LPAREN, struct_constructor, RPAREN)
 (* can be a function definition, in parens *)
 | (_, f) = delimited(LPAREN, function_definition(nothing, nothing), RPAREN); { f }

 let expr_ ==
 (* can be a `struct` definition *)
 | (n, s) = struct_definition(option(params)); { match n with None -> s | Some(params) -> expand_fn_sugar params $loc (Reference (Ident "Struct")) (make_located ~value: s ~loc: $loc ()) }
  (* can be an `interface` definition *)
 | (_, i) = interface_definition(nothing); { i }
 (* can be an `enum` definition *)
 | (_, e) = enum_definition(nothing); { e }
 (* can be an `union` definition *)
 | (_, u) = union_definition(nothing); { u }
 (* can be an identifier, as a reference to some identifier *)
 | ~= ident; <Reference>
 (* can be a function call *)
 | function_call
 (* can be an integer *)
 | ~= INT; <Int>
 (* can be a boolean *)
 | ~= BOOL; <Bool>
 (* can be a string *)
 | ~= STRING; <String>
 (* can be mutation ref *)
 | TILDE; ~= located(ident); <MutRef>

let params ==
    delimited_separated_trailing_list(LPAREN, function_param, COMMA, RPAREN)

(* Struct

   struct {
    val field_name: <type expression>
    ...
    
    fn name(...) -> ... { ... }
    ...
  }

  * Empty structs are allowed
  * Trailing commas are allowed

*)
let struct_definition(name) ==
  STRUCT;
  n = name;
  LBRACE;
  fields = list(struct_field);
  bindings = list(sugared_function_definition(option(code_block)));
  impls = list(impl);
  RBRACE;
  { (n, Struct (make_struct_definition ~fields ~struct_bindings: bindings ~impls  ())) }

let impl == 
  IMPL; 
  interface = located(fexpr); 
  LBRACE;
  methods = list(sugared_function_definition(option(code_block)));
  RBRACE;
  { make_impl ~interface ~methods () }

(* Struct field

   val field_name: <type expression>
*)
let struct_field ==
| located ( VAL ; name = located(ident); COLON; typ = located(expr); option(SEMICOLON); { make_struct_field ~field_name: name ~field_type: typ () } )

(* Struct constructor 
 *
 * MyStruct {
 *   field_name: 1
 * }
 *
 * *)
let struct_constructor :=
  constructor_id = located(type_expr);
  fields_construction = delimited_separated_trailing_list(
    LBRACE, 
    separated_pair(
      located(ident), 
      COLON, 
      located(expr)
    ), 
    COMMA, 
    RBRACE);
  {StructConstructor (make_struct_constructor ~constructor_id ~fields_construction ())}

(* Interface

   interface {
     fn name(...) -> Type
   }

*) 

let interface_definition(name) ==
  INTERFACE;
  n = name;
  bindings = delimited(LBRACE, list(located(function_signature_binding)), RBRACE);
  { (n, Interface (make_interface_definition ~interface_members: bindings ())) }

(* Identifier *)
let ident ==
  ~= IDENT ; <Ident>

(* Enum

  enum {
    member,
    member = expr,
    ...
    fn name(...) -> ... { ... }
    ...

  }

  * Empty enums are allowed
  * Trailing commas are allowed
  * exprs must evaluate to integers

*)
let enum_definition(name) ==
  ENUM;
  n = name;
  (members, bindings) = delimited_separated_trailing_list_followed_by(LBRACE, enum_member, COMMA, list(sugared_function_definition(option(code_block))), RBRACE);
  { (n, Enum (make_enum_definition ~enum_members: members ~enum_bindings: bindings ())) }

 (* Enum member

    Can be an identifier alone or `identifier = expr` where expr
    must evaluate to integers
*)
let enum_member ==
| located ( name = located(ident); { make_enum_member ~enum_name: name () } )
| located ( name = located(ident); EQUALS; value = located(expr); { make_enum_member ~enum_name: name ~enum_value: value () } )

(* Union

  union {
    case member_type
    case member_type
    ...

    fn name(...) -> ... { ... }
    ...

  }

  * Empty unions are allowed

*)
let union_definition(name) ==
  UNION;
  n = name;
  (members, bindings) = delimited(LBRACE, pair(list(preceded(CASE, located(union_member))), list(sugared_function_definition(option(code_block)))), RBRACE);  
  { (n, Union (make_union_definition ~union_members: members ~union_bindings: bindings ())) }

let union_member :=
 (* can be a struct definition *)
 | (_, s) = struct_definition(nothing); { s }
 (* can be an `interface` definition *)
 | (_, i) = interface_definition(nothing); { i }
 (* can be an `enum` definition *)
 | (_, e) = enum_definition(nothing); { e }
 (* can be an `union` definition *)
 | (_, u) = union_definition(nothing); { u }
 (* can be an identifier, as a reference to some identifier *)
 | ident = ident; {Reference ident }
 (* can be a function call [by identifier only] *)
 | fn = located(ident);
  arguments = delimited_separated_trailing_list(LPAREN, located(expr), COMMA, RPAREN);
  { FunctionCall (make_function_call ~fn: (make_located ~loc: (loc fn) ~value: (Reference (value fn)) ()) ~arguments: arguments ()) }

(* Delimited list, separated by a separator that may have a trailing separator *)
let delimited_separated_trailing_list(opening, x, sep, closing) ==
 | l = delimited(opening, nonempty_list(terminated(x, sep)), closing); { l }
 | l = delimited(opening, separated_list(sep, x), closing); { l }

(* Delimited list, separated by a separator that may have a trailing separator and followed by something else *)
let delimited_separated_trailing_list_followed_by(opening, x, sep, next, closing) ==
 | opening; ~ = nonempty_list(terminated(x, sep)); ~ = next; closing; <>
 | opening; ~ = separated_list(sep, x); ~ = next; closing; <>

(* Wraps into an `'a located` record *)
let located(x) ==
  ~ = x; { make_located ~loc: $loc ~value: x () }

let nothing == { None }

let some(x) == ~ = x; <Some>
