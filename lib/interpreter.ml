open Base
open Lang_types
open Errors

type error =
  [ `UnresolvedIdentifier of string
  | `UninterpretableStatement of stmt
  | `UnexpectedType of expr
  | `FieldNotFound of struct_ * string
  | `ArgumentNumberMismatch ]
[@@deriving equal, sexp_of]

(*TODO: type checks for arguments*)
class interpreter
  ((program, bindings, errors, _functions) :
    program * (string * expr) list list * _ errors * int ) =
  object (self)
    val global_bindings = bindings

    val mutable vars_scope = []

    val mutable return = Void

    method interpret_stmt_list : stmt list -> value =
      fun stmts ->
        match stmts with
        | [] ->
            return
        | stmt :: rest ->
            self#interpret_stmt stmt rest

    method interpret_stmt stmt rest =
      match stmt with
      | Let binds -> (
          let values =
            List.map binds ~f:(fun (_, arg) -> self#interpret_expr arg)
          in
          match List.zip (List.map binds ~f:(fun (name, _) -> name)) values with
          | Ok args_scope ->
              let prev_scope = vars_scope in
              vars_scope <- args_scope :: vars_scope ;
              let output = self#interpret_stmt_list rest in
              vars_scope <- prev_scope ;
              output
          | _ ->
              errors#report `Error `ArgumentNumberMismatch () ;
              Void )
      | Break stmt ->
          self#interpret_stmt stmt []
      | Return expr ->
          self#interpret_expr expr
      | Expr expr ->
          let expr' = self#interpret_expr expr in
          return <- expr' ;
          self#interpret_stmt_list rest
      | Invalid ->
          Void

    method interpret_expr : expr -> value =
      fun expr ->
        match expr with
        | FunctionCall fc ->
            self#interpret_fc fc
        | Reference (name, _) -> (
          match self#find_ref name with
          | Some expr' ->
              self#interpret_expr expr'
          | None ->
              errors#report `Error (`UnresolvedIdentifier name) () ;
              Void )
        | StructField (struct_, field) -> (
          match self#interpret_expr struct_ with
          | StructInstance (struct_, struct') -> (
            match List.Assoc.find struct' ~equal:String.equal field with
            | Some field ->
                field
            | None ->
                errors#report `Error (`FieldNotFound (struct_, field)) () ;
                Void )
          | other ->
              errors#report `Error (`UnexpectedType (Value other)) () ;
              Void )
        | Value value ->
            self#interpret_value value
        | Primitive _ | Asm _ | InvalidExpr | Hole ->
            errors#report `Error (`UninterpretableStatement (Expr expr)) () ;
            Void

    method interpret_value : value -> value =
      fun value ->
        match value with
        | Struct {struct_fields; struct_id} ->
            let struct_fields =
              List.map struct_fields ~f:(fun (name, {field_type}) ->
                  (name, {field_type = Value (self#interpret_expr field_type)}) )
            in
            Struct {struct_fields; struct_id}
        | value ->
            value

    method interpret_function : function_ -> function_ = fun f -> f

    method interpret_fc : function_call -> value =
      fun (func, args) ->
        let args' = List.map args ~f:(fun arg -> self#interpret_expr arg) in
        let mk_err = Expr (FunctionCall (func, args)) in
        let args_to_list params values =
          match
            List.zip (List.map params ~f:(fun (name, _) -> name)) values
          with
          | Ok scope ->
              Ok scope
          | _ ->
              Error mk_err
        in
        match self#interpret_expr func with
        | Function f -> (
          match f with
          | { function_signature = {function_params; _};
              function_impl = Fn function_impl;
              _ } -> (
              let args_scope = args_to_list function_params args' in
              match args_scope with
              | Ok args_scope -> (
                match function_impl with
                | Some body ->
                    let prev_scope = vars_scope in
                    vars_scope <- args_scope :: vars_scope ;
                    let output = self#interpret_stmt_list body in
                    vars_scope <- prev_scope ;
                    output
                | None ->
                    Void )
              | Error _ ->
                  Void )
          | {function_impl = BuiltinFn (function_impl, _); _} ->
              let program' =
                { program with
                  bindings = Option.value (List.hd global_bindings) ~default:[]
                }
              in
              let value = function_impl program' args' in
              program.methods <- program'.methods ;
              value
          | _ ->
              Void )
        | _ ->
            Void

    method private find_ref : string -> expr option =
      fun ref ->
        match find_in_scope ref vars_scope with
        | Some e ->
            Some (Value e)
        | None ->
            self#find_in_global_scope ref

    method private find_in_global_scope : string -> expr option =
      fun ref ->
        match find_in_scope ref global_bindings with
        | Some (Reference (ref', _)) ->
            self#find_in_global_scope ref'
        | not_ref ->
            not_ref
  end
