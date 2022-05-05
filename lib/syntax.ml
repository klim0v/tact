open Sexplib.Std

(* Z wrapper to enable show derivation *)
module Z' = struct
  type t = [%import: Z.t]

  let pp = Z.pp_print
end

let sexp_of_zt z = Sexplib.Sexp.of_string (Z.to_string z)

type zt = Z'.t [@@deriving show {with_path = false}]

module type T = sig
  include Located.T

  type ident = Ident of string

  and struct_definition =
    {fields : struct_field located list; struct_bindings : binding located list}

  and interface_definition = {interface_members : binding located list}

  and function_call = {fn : expr located; arguments : expr located list}

  and enum_definition =
    { enum_members : enum_member located list;
      enum_bindings : binding located list }

  and enum_member = {enum_name : ident located; enum_value : expr located option}

  and union_definition =
    {union_members : expr located list; union_bindings : binding located list}

  and expr =
    | Let of binding located
    | Struct of struct_definition
    | StructConstructor of struct_constructor
    | Interface of interface_definition
    | Enum of enum_definition
    | Union of union_definition
    | Reference of ident
    | FieldAccess of path
    | FunctionCall of function_call
    | Function of function_definition
    | Int of zt
    | CodeBlock of code_block
    | If of if_
    | Return of expr
    | MutRef of ident located

  and struct_constructor =
    { constructor_id : expr located option;
      fields_construction : (ident located * expr located) list }

  and struct_field = {field_name : ident located; field_type : expr located}

  and function_param = ident located * expr located

  and function_definition =
    { name : ident located option;
      params : function_param located list;
      returns : expr located option;
      exprs : expr located list option }

  and binding = {binding_name : ident located; binding_expr : expr located}

  and code_block = {block_exprs : expr located list}

  and if_ =
    { condition : expr located;
      body : expr located list;
      else_ : expr located option }

  and path = {first_elem : ident located; last_elems : ident located list}

  and program = {bindings : binding located list}
  [@@deriving show, make, sexp_of]

  val ident_to_string : ident -> string
end

module Make =
functor
  (L : Located.T)
  ->
  struct
    include L

    type ident = Ident of string

    and struct_definition =
      { fields : struct_field located list; [@sexp.list]
        struct_bindings : binding located list [@sexp.list] }

    and interface_definition =
      {interface_members : binding located list [@sexp.list]}

    and function_call =
      {fn : expr located; arguments : expr located list [@sexp.list]}

    and enum_definition =
      { enum_members : enum_member located list; [@sexp.list]
        enum_bindings : binding located list [@sexp.list] }

    and enum_member =
      { enum_name : ident located;
        enum_value : expr located option [@sexp.option] }

    and union_definition =
      { union_members : expr located list; [@sexp.list]
        union_bindings : binding located list [@sexp.list] }

    and expr =
      | Let of binding located
      | Struct of struct_definition
      | StructConstructor of struct_constructor
      | Interface of interface_definition
      | Enum of enum_definition
      | Union of union_definition
      | Reference of ident
      | FieldAccess of path
      | FunctionCall of function_call
      | Function of function_definition
      | Int of zt
      | CodeBlock of code_block
      | If of if_
      | Return of expr
      | MutRef of ident located

    and struct_constructor =
      { constructor_id : expr located option; [@sexp.option]
        fields_construction : (ident located * expr located) list [@sexp.list]
      }

    and struct_field = {field_name : ident located; field_type : expr located}

    and function_param = ident located * expr located

    and function_definition =
      { name : ident located option; [@sexp.option]
        params : function_param located list; [@sexp.list]
        returns : expr located option; [@sexp.option]
        exprs : expr located list option [@sexp.option] }

    and binding = {binding_name : ident located; binding_expr : expr located}

    and code_block = {block_exprs : expr located list [@sexp.list]}

    and if_ =
      { condition : expr located;
        body : expr located list; [@sexp.list]
        else_ : expr located option [@sexp.option] }

    and path = {first_elem : ident located; last_elems : ident located list}

    and program = {bindings : binding located list [@sexp.list]}
    [@@deriving show {with_path = false}, make, sexp_of]

    let ident_to_string = function Ident s -> s
  end
