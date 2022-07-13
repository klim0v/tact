open Base

module Make =
functor
  (Config : Config.T)
  ->
  struct
    open Errors
    include Lang_types
    open Interpreter
    open Type_check
    module Syntax = Syntax.Make (Config)
    open Partial_evaluator

    type error =
      [ `DuplicateField of string * mk_struct
      | `UnresolvedIdentifier of string
      | `MethodNotFound of expr * string
      | `UnexpectedType of type_
      | `TypeError of type_ * type_
      | `ExpectedFunction of type_
      | `UnallowedStmt of stmt
      | `OnlyFunctionIsAllowed
      | `FieldNotFoundF of string ]
    [@@deriving equal, sexp_of]

    include Builtin

    (* If we have signature fn(X: Type) -> X, so
       we need to change it to fn(X: Type) -> Dependent(X) *)
    class ['s] make_dependent_types (_errors : _) =
      object (self : 's)
        inherit ['s] Lang_types.map

        val mutable previous_arguments = []

        method! visit_Reference _ (ref, ty) =
          let concrete_ty =
            List.find_map previous_arguments ~f:(fun (name, x) ->
                if equal_string name ref then Some x else None )
          in
          match concrete_ty with
          | Some ty' ->
              Value (Type (Dependent (ref, ty')))
          | None ->
              Value (Type (ExprType (Reference (ref, ty))))

        method! visit_function_signature env sign =
          let prev = previous_arguments in
          let function_params =
            List.map
              ~f:(fun (name, ty) ->
                let ty' = self#visit_type_ env ty in
                let arg = (name, ty') in
                previous_arguments <- arg :: previous_arguments ;
                arg )
              sign.function_params
          in
          let function_returns = self#visit_type_ env sign.function_returns in
          previous_arguments <- prev ;
          {function_params; function_returns}
      end

    (* class ['s] comptime_checker =
       object (_self : 's)
         inherit ['s] boolean_reduce true as super

         method! visit_function_ = super#visit_function_

         method! visit_Primitive = false
       end *)

    (* Unit is important, because this function should return
       new program for each call, not one global mutable variable. *)
    let default_program () =
      let struct_signs = Arena.default () in
      let union_signs = Arena.default () in
      { bindings = Builtin.default_bindings struct_signs;
        structs = Builtin.default_structs;
        unions = [];
        type_counter = 0;
        memoized_fcalls = [];
        interfaces = Builtin.default_intfs;
        struct_signs;
        union_signs }

    class ['s] constructor ?(program = default_program ()) (errors : _ errors) =
      object (s : 's)
        inherit ['s] Syntax.visitor as super

        (* Bindings in scope *)
        val mutable current_bindings =
          [List.map program.bindings ~f:make_comptime]

        val type_checker = new type_checker errors 0

        (* Are we inside of a function body? How deep? *)
        val mutable functions = 0

        (* TODO: can we remove duplicating bindings here and the above? *)
        (* Program handle we pass to builtin functions. *)
        val mutable program = program

        method build_CodeBlock _env code_block =
          Block (s#of_located_list code_block)

        method! visit_CodeBlock env block =
          s#with_bindings [] (fun _ -> super#visit_CodeBlock env block)

        method build_Enum _env _enum = InvalidExpr

        method build_FieldAccess _env fieldaccess = StructField fieldaccess

        method build_Function _env fn = MkFunction fn

        method build_FunctionCall _env (f, args) =
          match type_of program f with
          | FunctionType sign -> (
              let no_errors = ref true in
              let types_satisfying =
                List.map2 sign.function_params args
                  ~f:(fun (_, expected) expr ->
                    match s#check_type ~expected expr with
                    | Ok _ ->
                        expr
                    | Error (NeedFromCall func) ->
                        let s = FunctionCall (func, [expr]) in
                        s
                    | _ ->
                        errors#report `Error
                          (`TypeError (expected, type_of program expr))
                          () ;
                        no_errors := false ;
                        Value Void )
              in
              match types_satisfying with
              | Ok args' when !no_errors ->
                  let fc = (f, args') in
                  if
                    is_immediate_expr current_bindings program
                      (FunctionCall (f, args'))
                  then
                    let fc =
                      let inter =
                        new interpreter
                          (program, current_bindings, errors, functions)
                          s#partial_evaluate_fn
                      in
                      let fc = inter#interpret_fc fc in
                      fc
                    in
                    Value fc
                  else FunctionCall fc
              | _ ->
                  Value Void )
          | ty ->
              errors#report `Error (`ExpectedFunction ty) () ;
              Value Void

        method build_MethodCall _env mc = mc

        method build_Ident _env string_ = string_

        method build_If _env if_ = If if_

        method build_Int _env i = Value (Integer i)

        method build_Bool _env b = Value (Bool b)

        method build_String _env s = Value (String s)

        method build_Interface _env intf = MkInterfaceDef intf

        method build_Let _env let_ =
          let amend_bindings binding = function
            | [] ->
                [[binding]]
            | bindings :: rest ->
                (binding :: bindings) :: rest
          in
          let name, expr = Syntax.value let_ in
          match is_immediate_expr current_bindings program expr with
          | true ->
              current_bindings <-
                amend_bindings (make_comptime (name, expr)) current_bindings ;
              Let [(name, expr)]
          | false ->
              let ty = type_of program expr in
              current_bindings <-
                amend_bindings (make_runtime (name, ty)) current_bindings ;
              Let [(name, expr)]

        method build_DestructuringLet _env let_ =
          let amend_bindings binding = function
            | [] ->
                [[binding]]
            | bindings :: rest ->
                (binding :: bindings) :: rest
          in
          let let_ = Syntax.value let_ in
          match
            is_immediate_expr current_bindings program
              let_.destructuring_let_expr
          with
          | true ->
              List.iter let_.destructuring_let ~f:(fun (name, new_name) ->
                  let expr =
                    StructField (let_.destructuring_let_expr, name, HoleType)
                  in
                  current_bindings <-
                    amend_bindings
                      (make_comptime (new_name, expr))
                      current_bindings ) ;
              DestructuringLet let_
          | false ->
              List.iter let_.destructuring_let ~f:(fun (name, new_name) ->
                  let expr =
                    StructField (let_.destructuring_let_expr, name, HoleType)
                  in
                  let ty = type_of program expr in
                  current_bindings <-
                    amend_bindings
                      (make_runtime (new_name, ty))
                      current_bindings ) ;
              DestructuringLet let_

        method build_MutRef _env _mutref = InvalidExpr

        method build_Reference env ref =
          match find_in_scope ref current_bindings with
          | Some (Runtime ty) ->
              Reference (ref, ty)
          | Some (Comptime (Reference (ref', _))) ->
              s#build_Reference env ref'
          | Some (Comptime (Value value)) ->
              ResolvedReference (ref, Value value)
          | Some (Comptime ex) ->
              Reference (ref, type_of program ex)
          | None ->
              errors#report `Error (`UnresolvedIdentifier ref) () ;
              Value Void

        method build_Return _env return =
          match functions with
          | 0 ->
              errors#report `Error (`UnallowedStmt (Return return)) () ;
              Return return
          | _ -> (
            match
              type_checker#check_return_type return ~program ~current_bindings
            with
            | Ok _ ->
                Return return
            | Error (NeedFromCall func) ->
                Break (Expr (FunctionCall (func, [return])))
            | Error (TypeError fn_returns) ->
                errors#report `Error
                  (`TypeError (fn_returns, type_of program return))
                  () ;
                Return return )

        method build_Break _env stmt =
          match stmt with
          | Expr ex -> (
            match functions with
            | 0 ->
                raise InternalCompilerError
            | _ -> (
              match
                type_checker#check_return_type ex ~program ~current_bindings
              with
              | Ok _ ->
                  Break stmt
              | Error (NeedFromCall func) ->
                  Break (Expr (FunctionCall (func, [ex])))
              | Error (TypeError fn_returns) ->
                  errors#report `Error
                    (`TypeError (fn_returns, type_of program ex))
                    () ;
                  Break stmt ) )
          | stmt ->
              Break stmt

        method build_Switch _ s = Switch s

        method build_switch_branch _env _ _ _ = raise InternalCompilerError

        method! visit_switch_branch env b =
          let ty =
            expr_to_type program @@ Syntax.value
            @@ s#visit_located s#visit_expr env b.ty
          in
          let ref = Syntax.ident_to_string (Syntax.value b.var) in
          let stmt =
            s#with_bindings
              [make_runtime (ref, ty)]
              (fun _ ->
                let stmt = s#visit_stmt env b.stmt in
                stmt )
          in
          {branch_ty = ty; branch_var = ref; branch_stmt = stmt}

        method build_switch _env cond branches =
          {switch_condition = Syntax.value cond; branches}

        method build_Struct _env s = MkStructDef s

        method build_StructConstructor _env sc = Value (Struct sc)

        method build_Union _env union = MkUnionDef union

        method build_Expr _env expr = Expr expr

        method build_impl _env intf bindings =
          { mk_impl_interface = Syntax.value intf;
            mk_impl_methods = s#of_located_list bindings }

        method! visit_expr env syntax_expr =
          let expr' = super#visit_expr env syntax_expr in
          match
            is_immediate_expr current_bindings program expr'
            && equal functions 0
          with
          | true ->
              let inter =
                new interpreter
                  (program, current_bindings, errors, functions)
                  s#partial_evaluate_fn
              in
              let value' = inter#interpret_expr expr' in
              Value value'
          | false ->
              expr'

        method build_binding _env name expr =
          (Syntax.value name, Syntax.value expr)

        method build_destructuring_binding _env destructuring_binding
            destructuring_binding_expr destructuring_binding_rest =
          { destructuring_let =
              List.map (Syntax.value destructuring_binding)
                ~f:(fun (name, new_name) ->
                  (Syntax.value name, Syntax.value new_name) );
            destructuring_let_expr = Syntax.value destructuring_binding_expr;
            destructuring_let_rest = destructuring_binding_rest }

        method build_enum_definition _env _members _bindings = ()

        method build_enum_member _env _name _value = ()

        method build_field_access _env expr field =
          let expr = Syntax.value expr in
          let field = Syntax.value field in
          let mk_err () =
            print_sexp (sexp_of_expr expr) ;
            errors#report `Error (`FieldNotFoundF field) () ;
            print_sexp (sexp_of_string field) ;
            raise InternalCompilerError
          in
          match type_of program expr with
          | StructType s -> (
              let struct_ = Program.get_struct program s in
              match
                List.Assoc.find struct_.struct_fields field ~equal:equal_string
              with
              | Some {field_type} ->
                  (expr, field, field_type)
              | None ->
                  mk_err () )
          | ExprType ex -> (
            match type_of program ex with
            | StructSig s -> (
                let s = Arena.get program.struct_signs s in
                match
                  List.Assoc.find s.st_sig_fields field ~equal:equal_string
                with
                | Some ty ->
                    (expr, field, expr_to_type program ty)
                | None ->
                    mk_err () )
            | _ ->
                mk_err () )
          | StructSig sign_id -> (
              let s = Arena.get program.struct_signs sign_id in
              match
                List.Assoc.find s.st_sig_fields field ~equal:equal_string
              with
              | Some ty ->
                  (expr, field, expr_to_type program ty)
              | None ->
                  mk_err () )
          | _ ->
              mk_err ()

        method build_function_call _env fn args =
          (Syntax.value fn, s#of_located_list args)

        method build_method_call _env receiver fn args =
          let receiver = Syntax.value receiver in
          let fn = Syntax.value fn
          and dummy : expr =
            FunctionCall
              ( Value
                  (Function
                     { function_signature =
                         {function_params = []; function_returns = VoidType};
                       function_impl = BuiltinFn (builtin_fun (fun _ _ -> Void))
                     } ),
                [] )
          in
          let args = s#of_located_list args in
          let make_call receiver ~mk_args =
            let receiver' = Value (Type receiver) in
            match
              Program.methods_of program receiver
              |> fun ms -> List.Assoc.find ms fn ~equal:String.equal
            with
            | Some fn' ->
                FunctionCall
                  (ResolvedReference (fn, Value (Function fn')), mk_args args)
            | None ->
                errors#report `Error (`MethodNotFound (receiver', fn)) () ;
                dummy
          in
          (* TODO: check method signatures *)
          match type_of program receiver with
          | TypeN 0 ->
              make_call (expr_to_type program receiver) ~mk_args:(fun x -> x)
          | StructSig sign_id -> (
              let sign = Arena.get program.struct_signs sign_id in
              match
                List.Assoc.find sign.st_sig_methods fn ~equal:String.equal
              with
              | Some m ->
                  StructSigMethodCall
                    { st_sig_call_instance = receiver;
                      st_sig_call_def = sign_id;
                      st_sig_call_method = (fn, m);
                      st_sig_call_args = args;
                      st_sig_call_kind = StructSigKind }
              | None ->
                  errors#report `Error (`MethodNotFound (receiver, fn)) () ;
                  dummy )
          | UnionSig sign_id -> (
              let sign = Arena.get program.union_signs sign_id in
              match
                List.Assoc.find sign.un_sig_methods fn ~equal:String.equal
              with
              | Some m ->
                  StructSigMethodCall
                    { st_sig_call_instance = receiver;
                      st_sig_call_def = sign_id;
                      st_sig_call_method = (fn, m);
                      st_sig_call_args = args;
                      st_sig_call_kind = UnionSigKind }
              | None ->
                  errors#report `Error (`MethodNotFound (receiver, fn)) () ;
                  dummy )
          | InterfaceType intf_id -> (
              let intf = Program.get_intf program intf_id in
              match
                List.Assoc.find intf.interface_methods fn ~equal:String.equal
              with
              | Some m ->
                  IntfMethodCall
                    { intf_instance = receiver;
                      intf_def = intf_id;
                      intf_method = (fn, m);
                      intf_args = args }
              | None ->
                  errors#report `Error (`MethodNotFound (receiver, fn)) () ;
                  dummy )
          | StructType st ->
              make_call (StructType st) ~mk_args:(fun args -> receiver :: args)
          | UnionType ut ->
              make_call (UnionType ut) ~mk_args:(fun args -> receiver :: args)
          | ExprType ex -> (
            (* If receiver has expr type that have type Interface, that means that
               value should implement interface, so we accept this case to allow
               such constructions:
               ```
                 fn foo(X: Intf) {
                  fn(arg: X) -> { arg.intf_method() }
                 }
               ```
               where
               type_of(arg) = ExprType(Reference("X"))
               type_of(Reference("X")) = Intf
            *)
            match type_of program ex with
            | InterfaceType intf_id -> (
                let intf = Program.get_intf program intf_id in
                match
                  List.Assoc.find intf.interface_methods fn ~equal:String.equal
                with
                | Some m ->
                    IntfMethodCall
                      { intf_instance = ex;
                        intf_def = intf_id;
                        intf_method = (fn, m);
                        intf_args = receiver :: args }
                | None ->
                    errors#report `Error (`MethodNotFound (receiver, fn)) () ;
                    dummy )
            | StructSig sign_id -> (
                let sign = Arena.get program.struct_signs sign_id in
                match
                  List.Assoc.find sign.st_sig_methods fn ~equal:String.equal
                with
                | Some m ->
                    StructSigMethodCall
                      { st_sig_call_instance = ex;
                        st_sig_call_def = sign_id;
                        st_sig_call_method = (fn, m);
                        st_sig_call_args = receiver :: args;
                        st_sig_call_kind = StructSigKind }
                | None ->
                    errors#report `Error (`MethodNotFound (receiver, fn)) () ;
                    dummy )
            | UnionSig sign_id -> (
                let sign = Arena.get program.union_signs sign_id in
                match
                  List.Assoc.find sign.un_sig_methods fn ~equal:String.equal
                with
                | Some m ->
                    StructSigMethodCall
                      { st_sig_call_instance = ex;
                        st_sig_call_def = sign_id;
                        st_sig_call_method = (fn, m);
                        st_sig_call_args = receiver :: args;
                        st_sig_call_kind = UnionSigKind }
                | None ->
                    errors#report `Error (`MethodNotFound (receiver, fn)) () ;
                    dummy )
            | _ ->
                errors#report `Error (`UnexpectedType (ExprType ex)) () ;
                dummy )
          | receiver_ty ->
              errors#report `Error (`UnexpectedType receiver_ty) () ;
              dummy

        method! visit_function_definition env f =
          (* prepare parameter bindings *)
          let param_bindings =
            s#of_located_list f.params
            |> List.map ~f:(fun (ident, expr) ->
                   ( s#visit_ident env @@ Syntax.value ident,
                     s#visit_expr env @@ Syntax.value expr ) )
            |> List.map ~f:(fun (id, expr) -> (id, expr_to_type program expr))
          in
          let function_returns =
            s#with_bindings
              (List.map param_bindings ~f:(fun (name, ty) ->
                   (name, Comptime (Value (Type (Dependent (name, ty))))) ) )
              (fun _ ->
                f.returns
                |> Option.map ~f:(fun x ->
                       expr_to_type program (s#visit_expr env (Syntax.value x)) )
                |> Option.value ~default:HoleType )
          in
          let body, fn_returns =
            s#with_bindings (List.map param_bindings ~f:make_runtime) (fun _ ->
                type_checker#with_fn_returns env function_returns (fun env' ->
                    s#visit_option s#visit_function_body env' f.function_body ) )
          in
          let function_signature =
            let sign =
              {function_params = param_bindings; function_returns = fn_returns}
            in
            let sig_maker = new make_dependent_types errors in
            sig_maker#visit_function_signature () sign
          in
          {function_signature; function_impl = Fn body}

        method! visit_function_body env body =
          (* save the function enclosure count *)
          let functions' = functions in
          (* increment function counter *)
          functions <- functions + 1 ;
          let body =
            match body.function_stmt with
            | Expr ex ->
                Syntax.Return ex
            | expr ->
                expr
          in
          (* process the body *)
          let result = super#visit_function_body env {function_stmt = body} in
          (* Convert implicit returns accomplished with an implicit last break *)
          let rec handle_returning_break = function
            | Block block -> (
              match List.rev block with
              | [] ->
                  Block []
              | hd :: tl -> (
                match List.rev @@ (handle_returning_break hd :: tl) with
                | [stmt] ->
                    stmt
                | stmts ->
                    Block stmts ) )
            | Break (Expr expr) ->
                Return expr
            | Expr ex ->
                Return ex
            | other ->
                other
          in
          let result = handle_returning_break result in
          (* restore function enclosure count *)
          functions <- functions' ;
          result

        method build_function_body _env stmt = stmt

        method build_function_definition _ _ _ _ _ = raise InternalCompilerError

        method build_if_ _env if_condition if_then if_else =
          { if_condition = Syntax.value if_condition;
            if_then = Syntax.value if_then;
            if_else = Option.map if_else ~f:Syntax.value }

        method build_interface_definition _env members =
          let signatures =
            List.filter_map (s#of_located_list members) ~f:(fun (name, x) ->
                match x with
                | Value (Function f) ->
                    Some (name, f.function_signature)
                | _ ->
                    errors#report `Error `OnlyFunctionIsAllowed () ;
                    None )
          in
          {mk_interface_methods = signatures}

        method! visit_interface_definition env def =
          let value =
            s#with_bindings
              [make_comptime ("Self", Value (Type SelfType))]
              (fun _ -> super#visit_interface_definition env def)
          in
          value

        method build_program _env _ =
          { program with
            bindings = extract_comptime_bindings (List.concat current_bindings)
          }

        method build_struct_constructor _env id fields =
          match Syntax.value id with
          | ResolvedReference (_, (Value (Type (StructType _)) as ty))
          | (Value (Type (StructType _)) as ty) ->
              ( ty,
                List.map fields ~f:(fun (name, expr) ->
                    (Syntax.value name, Syntax.value expr) ) )
          | ResolvedReference (_, (Value (Type (StructSig _)) as ty))
          | (Value (Type (StructSig _)) as ty) ->
              ( ty,
                List.map fields ~f:(fun (name, expr) ->
                    (Syntax.value name, Syntax.value expr) ) )
          (* | Reference (_, StructSig sid) ->
              ( Value (Type (StructSig sid)),
                List.map fields ~f:(fun (name, expr) ->
                    (Syntax.value name, Syntax.value expr) ) ) *)
          | ty -> (
            match type_of program ty with
            | StructSig _ ->
                ( ty,
                  List.map fields ~f:(fun (name, expr) ->
                      (Syntax.value name, Syntax.value expr) ) )
            | _ ->
                raise InternalCompilerError )
        (* print_sexp (sexp_of_expr e) ; *)

        (* errors#report `Error (`UnexpectedType (type_of program ty)) () ;
           (Value (Type VoidType), []) *)

        method build_struct_definition _ _ _ _ = raise InternalCompilerError

        method make_struct_definition struct_fields bindings impls mk_struct_id
            sign_id =
          let mk_struct_fields = struct_fields in
          let mk_methods =
            List.filter_map bindings ~f:(fun binding ->
                let name, expr = Syntax.value binding in
                match expr with
                | Value (Function _) | MkFunction _ ->
                    Some (name, expr)
                | _ ->
                    None )
          in
          let impl_methods =
            List.concat
              (List.map impls ~f:(fun impl ->
                   List.filter_map impl.mk_impl_methods ~f:(fun (name, ex) ->
                       match ex with
                       | Value (Function _) | MkFunction _ ->
                           Some (name, ex)
                       | _ ->
                           None ) ) )
          in
          let _ =
            Arena.update program.struct_signs sign_id ~f:(fun sign ->
                { st_sig_fields = mk_struct_fields;
                  st_sig_methods =
                    List.Assoc.map (mk_methods @ impl_methods) ~f:(fun f ->
                        match f with
                        | Value (Function f) | MkFunction f ->
                            f.function_signature
                        | _ ->
                            raise InternalCompilerError );
                  st_sig_base_id = mk_struct_id;
                  st_sig_id = sign.st_sig_id } )
          in
          let s' =
            { mk_struct_fields;
              mk_methods = mk_methods @ impl_methods;
              mk_impls = impls;
              mk_struct_id;
              mk_struct_sig = sign_id }
          in
          (* Check for duplicate fields *)
          ( match
              List.find_a_dup mk_struct_fields
                ~compare:(fun (name1, _) (name2, _) ->
                  String.compare name1 name2 )
            with
          | Some (name, _) ->
              errors#report `Error (`DuplicateField (name, s')) ()
          | None ->
              () ) ;
          s'

        method! visit_struct_definition env syn_struct_def =
          let prev_functions = functions in
          functions <- functions + 1 ;
          let fields =
            s#visit_list
              (s#visit_located s#visit_struct_field)
              env syn_struct_def.fields
            |> s#of_located_list
          in
          let sign_id, _ =
            Arena.with_id program.struct_signs ~f:(fun id ->
                { st_sig_fields = fields;
                  st_sig_methods = [];
                  st_sig_base_id = program.type_counter;
                  st_sig_id = id } )
          in
          let mk_struct_ =
            { mk_struct_fields = fields;
              mk_methods = [];
              mk_impls = [];
              mk_struct_id = program.type_counter;
              mk_struct_sig = sign_id }
          in
          program.type_counter <- program.type_counter + 1 ;
          let mk_struct =
            let methods =
              s#with_bindings
                [make_runtime ("Self", StructSig sign_id)]
                (fun _ ->
                  s#visit_list
                    (s#visit_located s#visit_binding)
                    env syn_struct_def.struct_bindings )
            in
            let impls =
              s#with_bindings
                [make_runtime ("Self", StructSig sign_id)]
                (fun _ -> s#visit_list s#visit_impl env syn_struct_def.impls)
            in
            let mk_struct =
              s#make_struct_definition fields methods impls
                mk_struct_.mk_struct_id mk_struct_.mk_struct_sig
            in
            {mk_struct with mk_struct_id = mk_struct_.mk_struct_id}
          in
          functions <- prev_functions ;
          mk_struct

        method build_struct_field : _ -> _ -> _ -> string * expr =
          fun _env field_name field_type ->
            (Syntax.value field_name, Syntax.value field_type)

        method build_union_definition _ _ _ = raise InternalCompilerError

        method! visit_union_definition env def =
          let prev_functions = functions in
          functions <- functions + 1 ;
          let members =
            s#visit_list (s#visit_located s#visit_expr) env def.union_members
          in
          let cases = s#of_located_list members in
          let union_base_id = program.type_counter in
          program.type_counter <- program.type_counter + 1 ;
          let sign_id, _ =
            Arena.with_id program.union_signs ~f:(fun _ ->
                { un_sig_cases = List.map cases ~f:(expr_to_type program);
                  un_sig_methods = [];
                  un_sig_base_id = union_base_id } )
          in
          let methods =
            s#with_bindings
              [make_runtime ("Self", UnionSig sign_id)]
              (fun _ ->
                s#visit_list
                  (s#visit_located s#visit_binding)
                  env def.union_bindings )
            |> s#of_located_list
            |> List.map ~f:(fun (name, e) ->
                   match e with
                   | Value (Function _) | MkFunction _ ->
                       (name, e)
                   | _ ->
                       raise InternalCompilerError )
          in
          let impls =
            s#with_bindings
              [make_runtime ("Self", UnionSig sign_id)]
              (fun _ -> s#visit_list s#visit_impl env def.union_impls)
          in
          let impl_methods =
            List.concat
              (List.map impls ~f:(fun impl ->
                   List.filter_map impl.mk_impl_methods ~f:(fun (name, ex) ->
                       match ex with
                       | Value (Function _) | MkFunction _ ->
                           Some (name, ex)
                       | _ ->
                           None ) ) )
          in
          let convert_impls = s#make_from_impls cases union_base_id in
          let mk_union =
            { mk_cases = cases;
              mk_union_id = union_base_id;
              mk_union_impls = impls @ convert_impls;
              mk_union_methods = methods @ impl_methods;
              mk_union_sig = sign_id }
          in
          functions <- prev_functions ;
          mk_union

        method private of_located_list : 'a. 'a Syntax.located list -> 'a list =
          List.map ~f:Syntax.value

        method private check_type ~expected actual =
          type_checker#check_type ~program ~current_bindings ~expected actual

        method private with_bindings : 'a. tbinding list -> (unit -> 'a) -> 'a =
          fun added_bindings f ->
            let current_bindings' = current_bindings in
            current_bindings <- added_bindings :: current_bindings ;
            let result = f () in
            current_bindings <- current_bindings' ;
            result

        method private make_from_impls : expr list -> int -> mk_impl list =
          fun cases union ->
            List.map cases ~f:(fun case ->
                let from_intf_ =
                  FunctionCall (from_intf, [Value (Type (ExprType case))])
                in
                { mk_impl_interface = from_intf_;
                  mk_impl_methods = [("from", s#make_from_impl_fn case union)]
                } )

        method private make_from_impl_fn case union =
          Value
            (Function
               { function_signature =
                   { function_params = [("v", expr_to_type program case)];
                     function_returns = UnionType union };
                 function_impl =
                   Fn
                     (Some
                        (Return
                           (MakeUnionVariant
                              (Reference ("v", expr_to_type program case), union)
                           ) ) ) } )

        method private partial_evaluate_fn p b u upu funcs f =
          let partial_evaluator =
            new partial_evaluator p b u upu funcs errors
          in
          partial_evaluator#visit_function_ () f
      end
  end
