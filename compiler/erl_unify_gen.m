%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 2007 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
% 
% File: erl_unify_gen.m
% Main author: wangp.
% 
% This module is part of the Erlang code generator.
% It handles Erlang code generation for unifications.
% 
%-----------------------------------------------------------------------------%

:- module erl_backend.erl_unify_gen.
:- interface.

:- import_module erl_backend.elds.
:- import_module erl_backend.erl_code_util.
:- import_module hlds.code_model.
:- import_module hlds.hlds_goal.
:- import_module parse_tree.prog_data.

:- import_module maybe.

%-----------------------------------------------------------------------------%

    % Generate ELDS code for a unification.
    %
:- pred erl_gen_unification(unification::in, code_model::in, prog_context::in,
    maybe(elds_expr)::in, elds_expr::out, erl_gen_info::in, erl_gen_info::out)
    is det.

    % Convert a cons id to the ELDS equivalent term, if any.  That is, any term
    % returned by this predicate must be useable as part of a pattern matching
    % operation.
    %
:- pred cons_id_to_term(cons_id, prog_vars, elds_term,
    erl_gen_info, erl_gen_info).
:- mode cons_id_to_term(in, in, out, in, out) is semidet.
:- mode cons_id_to_term(in(termable_cons_id), in, out, in, out) is det.

:- inst termable_cons_id
    --->    cons(ground, ground)
    ;       int_const(ground)
    ;       string_const(ground)
    ;       float_const(ground).

    % Convert a cons id to the ELDS equivalent expression.
    %
:- pred cons_id_to_expr(cons_id::in, prog_vars::in, elds_expr::out,
    erl_gen_info::in, erl_gen_info::out) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module backend_libs.rtti.
:- import_module check_hlds.mode_util.
:- import_module check_hlds.type_util.
:- import_module erl_backend.erl_call_gen.
:- import_module hlds.hlds_module.
:- import_module hlds.hlds_pred.
:- import_module libs.compiler_util.
:- import_module mdbcomp.prim_data.
:- import_module parse_tree.prog_data.
:- import_module parse_tree.prog_util.

:- import_module int.
:- import_module list.
:- import_module pair.
:- import_module set.
:- import_module string.

%-----------------------------------------------------------------------------%

erl_gen_unification(Unification, _CodeModel, _Context, MaybeSuccessExpr,
        Statement, !Info) :-
    Unification = assign(TargetVar, SourceVar),
    erl_gen_info_get_module_info(!.Info, ModuleInfo),
    erl_variable_type(!.Info, TargetVar, VarType),
    ( is_dummy_argument_type(ModuleInfo, VarType) ->
        Statement = expr_or_void(MaybeSuccessExpr)
    ;
        Assign = elds_eq(expr_from_var(TargetVar), expr_from_var(SourceVar)),
        Statement = maybe_join_exprs(Assign, MaybeSuccessExpr)
    ).

erl_gen_unification(Unification, CodeModel, _Context, MaybeSuccessExpr,
        Statement, !Info) :-
    Unification = simple_test(Var1, Var2),
    expect(unify(CodeModel, model_semi), this_file,
        "erl_code_gen: simple_test not semidet"),
    %
    % case Var1 =:= Var2 of
    %   true  -> MaybeSuccessExpr ;
    %   false -> fail
    % end
    %
    Statement = elds_case_expr(Test, [TrueCase, FalseCase]),
    Test      = elds_binop((=:=), expr_from_var(Var1), expr_from_var(Var2)),
    TrueCase  = elds_case(elds_true, expr_or_void(MaybeSuccessExpr)),
    FalseCase = elds_case(elds_false, elds_term(elds_fail)).

erl_gen_unification(Unification, CodeModel, Context, MaybeSuccessExpr,
        Statement, !Info) :-
    Unification = construct(Var, ConsId, Args, ArgModes, _HowToConstruct,
        _CellIsUnique, SubInfo),
    expect(unify(CodeModel, model_det), this_file,
        "erl_code_gen: construct not det"),
    (
        SubInfo = no_construct_sub_info
    ;
        SubInfo = construct_sub_info(_MaybeTakeAddr, MaybeSizeProfInfo),
        expect(unify(MaybeSizeProfInfo, no), this_file,
            "erl_code_gen: term size profiling not yet supported")
    ),
    erl_gen_info_get_module_info(!.Info, ModuleInfo),
    erl_variable_type(!.Info, Var, VarType),
    ( is_dummy_argument_type(ModuleInfo, VarType) ->
        Statement = expr_or_void(MaybeSuccessExpr)
    ;
        erl_variable_types(!.Info, Args, ArgTypes),
        erl_gen_construct(Var, ConsId, Args, ArgTypes, ArgModes, Context,
            Construct, !Info),
        Statement = maybe_join_exprs(Construct, MaybeSuccessExpr)
    ).

erl_gen_unification(Unification, _CodeModel, Context, MaybeSuccessExpr,
        Statement, !Info) :-
    Unification = deconstruct(Var, ConsId, Args, ArgModes, CanFail, _CanCGC),
    (
        CanFail = can_fail,
        SuccessExpr = det_expr(MaybeSuccessExpr),
        erl_gen_semidet_deconstruct(Var, ConsId, Args, ArgModes, Context,
            SuccessExpr, Statement, !Info)
    ;
        CanFail = cannot_fail,
        erl_gen_det_deconstruct(Var, ConsId, Args, ArgModes, Context,
            Statement0, !Info),
        Statement = maybe_join_exprs(Statement0, MaybeSuccessExpr)
    ).

erl_gen_unification(complicated_unify(_, _, _), _, _, _, _, !Info) :-
    % Simplify.m should have converted these into procedure calls.
    unexpected(this_file, "erl_code_gen: complicated unify").

%-----------------------------------------------------------------------------%

:- pred erl_gen_construct(prog_var::in, cons_id::in, prog_vars::in,
    list(mer_type)::in, list(uni_mode)::in, prog_context::in, elds_expr::out,
    erl_gen_info::in, erl_gen_info::out) is det.

erl_gen_construct(Var, ConsId, Args, ArgTypes, UniModes, _Context, Statement,
        !Info) :-
    cons_id_to_expr(ConsId, Args, RHS, !Info),
    Construct = elds_eq(expr_from_var(Var), RHS),
    %
    % If there are any free variables in Args, assign them to false first.
    % i.e. we are constructing a partially instantiated data structure.
    %
    erl_gen_info_get_module_info(!.Info, ModuleInfo),
    AssignFreeVars = list.filter_map_corresponding3(
        assign_free_var(ModuleInfo), Args, ArgTypes, UniModes),
    (
        AssignFreeVars = [],
        Statement = Construct
    ;
        AssignFreeVars = [_ | _],
        Statement = join_exprs(elds_block(AssignFreeVars), Construct)
    ).

:- func assign_free_var(module_info, prog_var, mer_type, uni_mode) = elds_expr
    is semidet.

assign_free_var(ModuleInfo, Var, ArgType, UniMode) = var_eq_false(Var) :-
    UniMode = ((_LI - RI) -> (_LF - RF)),
    not (
        mode_to_arg_mode(ModuleInfo, (RI -> RF), ArgType, top_in),
        not is_dummy_argument_type(ModuleInfo, ArgType)
        % XXX ml_unify_gen also checks if ConsArgType is dummy type,
        % do we need to do the same?
    ).

%-----------------------------------------------------------------------------%

:- pred erl_gen_det_deconstruct(prog_var::in, cons_id::in, prog_vars::in,
    list(uni_mode)::in, prog_context::in, elds_expr::out,
    erl_gen_info::in, erl_gen_info::out) is det.

erl_gen_det_deconstruct(Var, ConsId, Args, _Modes, _Context, Statement,
        !Info) :-
    cons_id_to_expr(ConsId, Args, LHS, !Info),
    Statement = elds_eq(LHS, expr_from_var(Var)).

:- pred erl_gen_semidet_deconstruct(prog_var::in, cons_id::in, prog_vars::in,
    list(uni_mode)::in, prog_context::in, elds_expr::in, elds_expr::out,
    erl_gen_info::in, erl_gen_info::out) is det.

erl_gen_semidet_deconstruct(Var, ConsId, Args, _Modes, _Context,
        SuccessExpr, Statement, !Info) :-
    ( cons_id_to_term(ConsId, Args, Pattern0, !Info) ->
        Pattern = Pattern0
    ;
        unexpected(this_file,
            "erl_gen_semidet_deconstruct: undeconstructable object")
    ),
    %
    % case Var of
    %   Pattern -> SuccessExpr ;
    %   _       -> fail
    % end
    %
    Statement   = elds_case_expr(expr_from_var(Var), [SucceedCase, FailCase]),
    SucceedCase = elds_case(Pattern, SuccessExpr),
    FailCase    = elds_case(elds_anon_var, elds_term(elds_fail)).

%-----------------------------------------------------------------------------%

cons_id_to_term(ConsId, Args, Term, !Info) :-
    (
        ConsId = cons(Name, _Arity),
        (
            Name = unqualified(String),
            string.char_to_string(Char, String)
        ->
            Term = elds_char(Char)
        ;
            % XXX optimise the cases where we don't actually need a
            % distinguishing atom.
            Functor = elds_term(elds_atom(Name)),
            Term = elds_tuple([Functor | exprs_from_vars(Args)])
        )
    ;
        ConsId = int_const(Int),
        Term = elds_int(Int)
    ;
        ConsId = string_const(String),
        Term = elds_string(String)
    ;
        ConsId = float_const(Float),
        Term = elds_float(Float)
    ).

cons_id_to_expr(ConsId, Args, Expr, !Info) :-
    (
        ( ConsId = cons(_, _)
        ; ConsId = int_const(_)
        ; ConsId = string_const(_)
        ; ConsId = float_const(_)
        ),
        cons_id_to_term(ConsId, Args, Term, !Info),
        Expr = elds_term(Term)
    ;
        ConsId = pred_const(ShroudedPredProcId, lambda_normal),
        pred_const_to_closure(ShroudedPredProcId, Args, Expr, !Info)
    ;
        ConsId = type_ctor_info_const(ModuleName, TypeCtor, Arity),
        RttiTypeCtor = rtti_type_ctor(ModuleName, TypeCtor, Arity),
        RttiId = elds_rtti_type_ctor_id(RttiTypeCtor),
        Expr = elds_rtti_ref(RttiId)
    ;
        ConsId = base_typeclass_info_const(InstanceModule,
            class_id(ClassName, Arity), _Instance, InstanceStr),
        ( sym_name_get_module_name(ClassName, ClassModuleName0) ->
            ClassModuleName = ClassModuleName0
        ;
            unexpected(this_file, "cons_id_to_expr: class has no module name")
        ),
        ClassNameStr = unqualify_name(ClassName),
        TCName = tc_name(ClassModuleName, ClassNameStr, Arity),
        RttiId = elds_rtti_base_typeclass_id(TCName, InstanceModule,
            InstanceStr),
        Expr = elds_rtti_ref(RttiId)
    ;
        ( ConsId = type_info_cell_constructor(_TypeCtor)
        ; ConsId = typeclass_info_cell_constructor
        ),
        % This represents type_infos and typeclass_infos as undistinguished
        % tuples, so the layout will be the same as corresponding arrays in C.
        Expr = elds_term(elds_tuple(exprs_from_vars(Args)))
    ;
        ( ConsId = tabling_info_const(_)
        ; ConsId = deep_profiling_proc_layout(_)
        ; ConsId = table_io_decl(_)
        ),
        sorry(this_file,
            "tabling and deep profiling not supported on Erlang backend")
    ).

:- pred pred_const_to_closure(shrouded_pred_proc_id::in, prog_vars::in,
    elds_expr::out, erl_gen_info::in, erl_gen_info::out) is det.

pred_const_to_closure(ShroudedPredProcId, CurriedArgs, FunExpr, !Info) :-
    erl_gen_info_get_module_info(!.Info, ModuleInfo),
    PredProcId = unshroud_pred_proc_id(ShroudedPredProcId),
    module_info_pred_proc_info(ModuleInfo, PredProcId, PredInfo, ProcInfo),
    pred_info_get_arg_types(PredInfo, CalleeTypes),
    proc_info_get_argmodes(ProcInfo, ArgModes),
    proc_info_interface_code_model(ProcInfo, CodeModel),

    % Create extra variables needed to complete the call to the procedure.
    NumExtraVars = list.length(CalleeTypes) - list.length(CurriedArgs),
    erl_gen_info_new_vars(NumExtraVars, AllExtraVars, !Info),

    % Separate the argument lists into inputs and outputs twice: once ignore
    % dummy and unused arguments, and once keeping them.  Dummy arguments must
    % not be dropped in the closure's function signature, and dummy outputs
    % must be present in the return value.  However, the underlying procedure
    % won't accept dummy arguments and won't return dummy values.

    CurriedAndExtraArgs = CurriedArgs ++ AllExtraVars,

    erl_gen_arg_list(ModuleInfo, opt_dummy_args, CurriedAndExtraArgs,
        CalleeTypes, ArgModes, CallInputVars, CallOutputVars),

    erl_gen_arg_list(ModuleInfo, no_opt_dummy_args, CurriedAndExtraArgs,
        CalleeTypes, ArgModes, _InputVarsInclDummy, OutputVarsInclDummy),
    InputExtraVars = list.delete_elems(AllExtraVars, OutputVarsInclDummy),

    OutputVarsInclDummyExprs = exprs_from_vars(OutputVarsInclDummy),
    (
        ( CodeModel = model_det
        ; CodeModel = model_semi
        ),
        ClosureInputArgs = InputExtraVars,
        SuccessExpr0 = elds_term(elds_tuple(OutputVarsInclDummyExprs))
    ;
        CodeModel = model_non,
        % One more extra variable is needed for the success continuation for
        % model_non procedures.
        erl_gen_info_new_named_var("Succeed", SucceedVar, !Info),
        ClosureInputArgs = InputExtraVars ++ [SucceedVar],
        SuccessExpr0 = elds_call(elds_call_ho(expr_from_var(SucceedVar)),
            OutputVarsInclDummyExprs)
    ),

    DummyOutputVars = list.delete_elems(OutputVarsInclDummy, CallOutputVars),
    MaterialiseDummyOutputs = list.map(var_eq_false, DummyOutputVars),
    SuccessExpr = join_exprs(elds_block(MaterialiseDummyOutputs),
        SuccessExpr0),

    % Make the call to the underlying procedure.
    CallTarget = elds_call_plain(PredProcId),
    erl_make_call(CodeModel, CallTarget, CallInputVars, CallOutputVars,
        yes(SuccessExpr), DoCall),

    FunExpr = elds_fun(elds_clause(terms_from_vars(ClosureInputArgs), DoCall)).

%-----------------------------------------------------------------------------%

:- func this_file = string.

this_file = "erl_unify_gen.m".

%-----------------------------------------------------------------------------%
:- end_module erl_unify_gen.
%-----------------------------------------------------------------------------%
