%token TYPE INTERFACE STRUCT FN
%token EQUALS
%token <string> IDENT
%token EOF
%token LBRACKET LPAREN
%token RBRACKET RPAREN
%token COMMA
%token COLON

%start <Syntax.program> program

%{ open Syntax %}

%%

(* At the very top, there's a program *) 
let program :=
  (* it consists of a list of top-level expressions *)
  top_level = list(top_level_expr);
  EOF; { 
    make_program 
       (* collect defined types *)
       ~types: (List.filter_map (fun x -> match x with Type(t) -> Some(t) | _ -> None) top_level) 
       (* collect defined functions *)
       ~functions: (List.filter_map (fun x -> match x with Function(t) -> Some(t) | _ -> None) top_level) 
  ()
  }

(* Top level expression *)
let top_level_expr ==
  (* can be a type definition *)
  | ~= type_definition ; <Type>
  (* can be a function definition *)
  | ~= function_definition ; <Function> 

(* Type definition

type Name = <expression> 

See Expression

*)
let type_definition ==
| located (
  TYPE;
  name = located(ident);
  EQUALS;
  expr = located(expr);
  { make_type_definition ~name: name ~expr: expr () }
)
| located (
  TYPE;
  name = located(ident);
  params = delimited_separated_trailing_list(LPAREN, function_param, COMMA, RPAREN);
  EQUALS;
  expr = located(expr);
  { make_type_definition ~name: name 
      ~expr: 
        { loc = $loc; 
          value = Function (make_function_definition ~params: params  
                                           ~returns: {loc = $loc; value = Reference (Ident "Type")}
                                           ~exprs: [expr] 
                                           ())
        } 
        () 
  }
)

(* Function definition

fn name(arg: Type, ...) Type {
  expr
  expr
  ...
}

*)
let function_definition ==
| located (
  FN;
  name = located(ident);
  params = delimited_separated_trailing_list(LPAREN, function_param, COMMA, RPAREN);
  returns = located(expr);
  exprs = delimited(LBRACKET, list(located(expr)), RBRACKET);
  { make_function_definition ~name: name ~params: params ~returns: returns ~exprs: exprs () }
)

(* Inline function definition

fn (arg: Type, ...) Type {
  expr
  expr
  ...
}

*)
let inline_function_definition ==
| 
  FN;
  params = delimited_separated_trailing_list(LPAREN, function_param, COMMA, RPAREN);
  returns = located(expr);
  exprs = delimited(LBRACKET, list(located(expr)), RBRACKET);
  { Function (make_function_definition ~params: params ~returns: returns ~exprs: exprs ()) }

let function_param ==
  located (
  ~ = located(ident);
  COLON;
  ~ = located(expr);
  <FunctionParam>
  )

(* Function call

   name([argument,])
   <expr>([argument,])

  * Trailing commas are allowed
*)
let function_call ==
  fn = located(expr);
  arguments = delimited_separated_trailing_list(LPAREN, located(expr), COMMA, RPAREN);
  { FunctionCall (make_function_call ~fn: fn ~arguments: arguments ()) }


(* Expression *)
let expr :=
 (* can be a `struct` definition *)
 | struct_definition
 (* can be an `interface` definition *)
 | interface_definition
 (* can be an identifier, as a reference to some identifier *)
 | ~= ident; <Reference>
 (* can be a function call *)
 | function_call
 (* can be an inline function definition *)
 | inline_function_definition

(* Structure 

  struct {
    field_name: <expression>,
    ...
  }

  * Empty structures are allowed
  * Trailing commas are allowed

*)
let struct_definition ==
| STRUCT; 
  fields = delimited_separated_trailing_list(LBRACKET, struct_fields, COMMA, RBRACKET);
  { Struct (make_struct_definition ~fields: fields ()) }

(* Structure field

   field_name: <expression>
*)
let struct_fields ==
| located ( name = located(ident); COLON; typ = located(expr); { make_struct_field ~field_name: name ~field_type: typ () } )

(* Interface

   interface {
     <interface member>
   }

   NB: member definitions TBD
*)  

let interface_definition ==
|
  INTERFACE;
  LBRACKET ; RBRACKET ;
  { Interface (make_interface_definition ~members: [] ()) }

(* Identifier *)
let ident ==
  ~= IDENT ; <Ident>

(* Delimited list, separated by a separator that may have a trailing separator *)
let delimited_separated_trailing_list(opening, x, sep, closing) ==
 | l = delimited(opening, nonempty_list(terminated(x, sep)), closing); { l } 
 | l = delimited(opening, separated_list(sep, x), closing); { l }

(* Wraps into an `'a located` record *)
let located(x) ==
  ~ = x; { { loc = $loc; value = x } }
 
