%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% Copyright (C) 1996-2012 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%---------------------------------------------------------------------------%
%
% File: bytecode_gen.m.
% Author: zs.
%
% This module generates bytecode, which is intended to be used by a
% (not yet implemented) bytecode interpreter/debugger.
%
%---------------------------------------------------------------------------%

:- module bytecode_backend.bytecode_gen.
:- interface.

:- import_module bytecode_backend.bytecode.
:- import_module hlds.
:- import_module hlds.hlds_module.

:- import_module io.
:- import_module list.

%---------------------------------------------------------------------------%

:- pred gen_module(module_info::in, module_info::out, list(byte_code)::out,
    io::di, io::uo) is det.

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

:- implementation.

% We make use of some stuff from the LLDS back-end, in particular the stuff
% relating to the argument passing convention in arg_info.m and call_gen.m.
% The intent here is to use the same argument passing convention as for
% the LLDS, to allow interoperability between code compiled to bytecode
% and code compiled to machine code.
%
% XXX It might be nice to move the argument passing related stuff
% in call_gen.m that we use here into arg_info.m, and to then rework
% arg_info.m so that it didn't depend on the LLDS.

:- import_module backend_libs.
:- import_module backend_libs.builtin_ops.
:- import_module check_hlds.
:- import_module check_hlds.mode_util.
:- import_module check_hlds.type_util.
:- import_module hlds.arg_info.
:- import_module hlds.code_model.
:- import_module hlds.goal_util.
:- import_module hlds.hlds_code_util.
:- import_module hlds.hlds_data.
:- import_module hlds.hlds_goal.
:- import_module hlds.hlds_llds.
:- import_module hlds.hlds_pred.
:- import_module hlds.passes_aux.
:- import_module ll_backend.
:- import_module ll_backend.call_gen.  % XXX for arg passing convention
:- import_module mdbcomp.
:- import_module mdbcomp.prim_data.
:- import_module parse_tree.
:- import_module parse_tree.prog_data.
:- import_module parse_tree.prog_type.
:- import_module parse_tree.set_of_var.

:- import_module assoc_list.
:- import_module cord.
:- import_module counter.
:- import_module deconstruct.
:- import_module int.
:- import_module list.
:- import_module map.
:- import_module pair.
:- import_module require.
:- import_module set.
:- import_module string.
:- import_module term.
:- import_module varset.

%---------------------------------------------------------------------------%

gen_module(!ModuleInfo, Code, !IO) :-
    module_info_get_valid_predids(PredIds, !ModuleInfo),
    gen_preds(PredIds, !.ModuleInfo, CodeTree, !IO),
    Code = cord.list(CodeTree).

:- pred gen_preds(list(pred_id)::in, module_info::in, byte_tree::out,
    io::di, io::uo) is det.

gen_preds([], _ModuleInfo, empty, !IO).
gen_preds([PredId | PredIds], ModuleInfo, Code, !IO) :-
    module_info_get_preds(ModuleInfo, PredTable),
    map.lookup(PredTable, PredId, PredInfo),
    ProcIds = pred_info_non_imported_procids(PredInfo),
    (
        ProcIds = [],
        PredCode = empty
    ;
        ProcIds = [_ | _],
        gen_pred(PredId, ProcIds, PredInfo, ModuleInfo, ProcsCode, !IO),
        PredName = predicate_name(ModuleInfo, PredId),
        list.length(ProcIds, ProcsCount),
        Arity = pred_info_orig_arity(PredInfo),
        get_is_func(PredInfo, IsFunc),
        EnterCode = singleton(byte_enter_pred(PredName, Arity, IsFunc,
            ProcsCount)),
        EndofCode = singleton(byte_endof_pred),
        PredCode = EnterCode ++ ProcsCode ++ EndofCode
    ),
    gen_preds(PredIds, ModuleInfo, OtherCode, !IO),
    Code = PredCode ++ OtherCode.

:- pred gen_pred(pred_id::in, list(proc_id)::in, pred_info::in,
    module_info::in, byte_tree::out, io::di, io::uo) is det.

gen_pred(_PredId, [], _PredInfo, _ModuleInfo, empty, !IO).
gen_pred(PredId, [ProcId | ProcIds], PredInfo, ModuleInfo, Code, !IO) :-
    write_proc_progress_message("% Generating bytecode for ",
        PredId, ProcId, ModuleInfo, !IO),
    gen_proc(ProcId, PredInfo, ModuleInfo, ProcCode),
    gen_pred(PredId, ProcIds, PredInfo, ModuleInfo, ProcsCode, !IO),
    Code = ProcCode ++ ProcsCode.

:- pred gen_proc(proc_id::in, pred_info::in,
    module_info::in, byte_tree::out) is det.

gen_proc(ProcId, PredInfo, ModuleInfo, Code) :-
    pred_info_get_procedures(PredInfo, ProcTable),
    map.lookup(ProcTable, ProcId, ProcInfo),

    proc_info_get_goal(ProcInfo, Goal),
    proc_info_get_vartypes(ProcInfo, VarTypes),
    proc_info_get_varset(ProcInfo, VarSet),
    proc_info_interface_determinism(ProcInfo, Detism),
    determinism_to_code_model(Detism, CodeModel),

    goal_util.goal_vars(Goal, GoalVars),
    proc_info_get_headvars(ProcInfo, ArgVars),
    set_of_var.insert_list(ArgVars, GoalVars, Vars),
    set_of_var.to_sorted_list(Vars, VarList),
    map.init(VarMap0),
    create_varmap(VarList, VarSet, VarTypes, 0, VarMap0, VarMap, VarInfos),

    init_byte_info(ModuleInfo, VarMap, VarTypes, ByteInfo0),
    get_next_label(ZeroLabel, ByteInfo0, ByteInfo1),

    proc_info_arg_info(ProcInfo, ArgInfo),
    assoc_list.from_corresponding_lists(ArgVars, ArgInfo, Args),

    call_gen.input_arg_locs(Args, InputArgs),
    gen_pickups(InputArgs, ByteInfo, PickupCode),

    call_gen.output_arg_locs(Args, OutputArgs),
    gen_places(OutputArgs, ByteInfo, PlaceCode),

    % If semideterministic, reserve temp slot 0 for the return value
    (
        CodeModel = model_semi,
        get_next_temp(_FrameTemp, ByteInfo1, ByteInfo2)
    ;
        ( CodeModel = model_det
        ; CodeModel = model_non
        ),
        ByteInfo2 = ByteInfo1
    ),

    gen_goal(Goal, ByteInfo2, ByteInfo3, GoalCode),
    get_next_label(EndLabel, ByteInfo3, ByteInfo),
    get_counts(ByteInfo, LabelCount, TempCount),

    ZeroLabelCode = singleton(byte_label(ZeroLabel)),
    BodyCode0 = PickupCode ++ ZeroLabelCode ++ GoalCode ++ PlaceCode,
    BodyInstrs = cord.list(BodyCode0),
    ( list.member(byte_not_supported, BodyInstrs) ->
        BodyCode = singleton(byte_not_supported)
    ;
        BodyCode = BodyCode0
    ),
    proc_id_to_int(ProcId, ProcInt),
    EnterCode = singleton(byte_enter_proc(ProcInt, Detism, LabelCount,
        EndLabel, TempCount, VarInfos)),
    (
        CodeModel = model_semi,
        EndofCode = from_list([byte_semidet_succeed, byte_label(EndLabel),
            byte_endof_proc])
    ;
        ( CodeModel = model_det
        ; CodeModel = model_non
        ),
        EndofCode = from_list([byte_label(EndLabel), byte_endof_proc])
    ),
    Code = EnterCode ++ BodyCode ++ EndofCode.

%---------------------------------------------------------------------------%

:- pred gen_goal(hlds_goal::in, byte_info::in, byte_info::out,
    byte_tree::out) is det.

gen_goal(hlds_goal(GoalExpr, GoalInfo), !ByteInfo, Code) :-
    gen_goal_expr(GoalExpr, GoalInfo, !ByteInfo, GoalCode),
    Context = goal_info_get_context(GoalInfo),
    term.context_line(Context, Line),
    Code = singleton(byte_context(Line)) ++ GoalCode.

:- pred gen_goal_expr(hlds_goal_expr::in, hlds_goal_info::in,
    byte_info::in, byte_info::out, byte_tree::out) is det.

gen_goal_expr(GoalExpr, GoalInfo, !ByteInfo, Code) :-
    (
        GoalExpr = generic_call(GenericCallType,
            ArgVars, ArgModes, _, Detism),
        (
            GenericCallType = higher_order(PredVar, _, _, _),
            gen_higher_order_call(PredVar, ArgVars, ArgModes, Detism,
                !.ByteInfo, Code)
        ;
            ( GenericCallType = class_method(_, _, _, _)
            ; GenericCallType = cast(_)
            ; GenericCallType = event_call(_)
            ),
            % XXX
            % string.append_list([
            % "bytecode for ", GenericCallFunctor, " calls"], Msg),
            % sorry($module, $pred, Msg)
            functor(GenericCallType, canonicalize, _GenericCallFunctor, _),
            Code = singleton(byte_not_supported)
        )
    ;
        GoalExpr = plain_call(PredId, ProcId, ArgVars, BuiltinState, _, _),
        (
            BuiltinState = not_builtin,
            Detism = goal_info_get_determinism(GoalInfo),
            gen_call(PredId, ProcId, ArgVars, Detism, !.ByteInfo, Code)
        ;
            ( BuiltinState = inline_builtin
            ; BuiltinState = out_of_line_builtin
            ),
            gen_builtin(PredId, ProcId, ArgVars, !.ByteInfo, Code)
        )
    ;
        GoalExpr = unify(Var, RHS, _Mode, Unification, _),
        gen_unify(Unification, Var, RHS, !.ByteInfo, Code)
    ;
        GoalExpr = negation(Goal),
        gen_goal(Goal, !ByteInfo, SomeCode),
        get_next_label(EndLabel, !ByteInfo),
        get_next_temp(FrameTemp, !ByteInfo),
        EnterCode = singleton(byte_enter_negation(FrameTemp, EndLabel)),
        EndofCode = from_list([byte_endof_negation_goal(FrameTemp),
            byte_label(EndLabel), byte_endof_negation]),
        Code =  EnterCode ++ SomeCode ++ EndofCode
    ;
        GoalExpr = scope(_, InnerGoal),
        gen_goal(InnerGoal, !ByteInfo, InnerCode),
        OuterDetism = goal_info_get_determinism(GoalInfo),
        InnerGoal = hlds_goal(_, InnerGoalInfo),
        InnerDetism = goal_info_get_determinism(InnerGoalInfo),
        determinism_to_code_model(OuterDetism, OuterCodeModel),
        determinism_to_code_model(InnerDetism, InnerCodeModel),
        ( InnerCodeModel = OuterCodeModel ->
            Code = InnerCode
        ;
            get_next_temp(Temp, !ByteInfo),
            EnterCode = singleton(byte_enter_commit(Temp)),
            EndofCode = singleton(byte_endof_commit(Temp)),
            Code = EnterCode ++ InnerCode ++ EndofCode
        )
    ;
        GoalExpr = conj(plain_conj, GoalList),
        gen_conj(GoalList, !ByteInfo, Code)
    ;
        GoalExpr = conj(parallel_conj, _GoalList),
        sorry($module, $pred, "bytecode_gen of parallel conjunction")
    ;
        GoalExpr = disj(GoalList),
        (
            GoalList = [],
            Code = singleton(byte_fail)
        ;
            GoalList = [_ | _],
            get_next_label(EndLabel, !ByteInfo),
            gen_disj(GoalList, EndLabel, !ByteInfo, DisjCode),
            EnterCode = singleton(byte_enter_disjunction(EndLabel)),
            EndofCode = from_list([byte_endof_disjunction,
                byte_label(EndLabel)]),
            Code = EnterCode ++ DisjCode ++ EndofCode
        )
    ;
        GoalExpr = switch(Var, _, CasesList),
        get_next_label(EndLabel, !ByteInfo),
        gen_switch(CasesList, Var, EndLabel, !ByteInfo, SwitchCode),
        map_var(!.ByteInfo, Var, ByteVar),
        EnterCode = singleton(byte_enter_switch(ByteVar, EndLabel)),
        EndofCode = from_list([byte_endof_switch, byte_label(EndLabel)]),
        Code = EnterCode ++ SwitchCode ++ EndofCode
    ;
        GoalExpr = if_then_else(_Vars, Cond, Then, Else),
        get_next_label(EndLabel, !ByteInfo),
        get_next_label(ElseLabel, !ByteInfo),
        get_next_temp(FrameTemp, !ByteInfo),
        gen_goal(Cond, !ByteInfo, CondCode),
        gen_goal(Then, !ByteInfo, ThenCode),
        gen_goal(Else, !ByteInfo, ElseCode),
        EnterIfCode = singleton(byte_enter_if(ElseLabel, EndLabel, FrameTemp)),
        EnterThenCode = singleton(byte_enter_then(FrameTemp)),
        EndofThenCode = from_list([byte_endof_then(EndLabel),
            byte_label(ElseLabel), byte_enter_else(FrameTemp)]),
        EndofIfCode = from_list([byte_endof_if, byte_label(EndLabel)]),
        Code = EnterIfCode ++ CondCode ++ EnterThenCode ++ ThenCode ++
            EndofThenCode ++ ElseCode ++ EndofIfCode
    ;
        GoalExpr = call_foreign_proc(_, _, _, _, _, _, _),
        Code = singleton(byte_not_supported)
    ;
        GoalExpr = shorthand(_),
        % These should have been expanded out by now.
        unexpected($module, $pred, "shorthand")
    ).

%---------------------------------------------------------------------------%

:- pred gen_places(list(pair(prog_var, arg_loc))::in,
    byte_info::in, byte_tree::out) is det.

gen_places([], _, empty).
gen_places([Var - Loc | OutputArgs], ByteInfo, Code) :-
    gen_places(OutputArgs, ByteInfo, OtherCode),
    map_var(ByteInfo, Var, ByteVar),
    (
        Loc = reg(reg_r, RegNum)
    ;
        Loc = reg(reg_f, _),
        sorry($module, $pred, "floating point register")
    ),
    Code = singleton(byte_place_arg(byte_reg_r, RegNum, ByteVar)) ++
        OtherCode.

:- pred gen_pickups(list(pair(prog_var, arg_loc))::in,
    byte_info::in, byte_tree::out) is det.

gen_pickups([], _, empty).
gen_pickups([Var - Loc | OutputArgs], ByteInfo, Code) :-
    gen_pickups(OutputArgs, ByteInfo, OtherCode),
    map_var(ByteInfo, Var, ByteVar),
    (
        Loc = reg(reg_r, RegNum)
    ;
        Loc = reg(reg_f, _),
        sorry($module, $pred, "floating point register")
    ),
    Code = singleton(byte_pickup_arg(byte_reg_r, RegNum, ByteVar)) ++
        OtherCode.

%---------------------------------------------------------------------------%

    % Generate bytecode for a higher order call.
    %
:- pred gen_higher_order_call(prog_var::in, list(prog_var)::in,
    list(mer_mode)::in, determinism::in, byte_info::in, byte_tree::out) is det.

gen_higher_order_call(PredVar, ArgVars, ArgModes, Detism, ByteInfo, Code) :-
    determinism_to_code_model(Detism, CodeModel),
    get_module_info(ByteInfo, ModuleInfo),
    list.map(get_var_type(ByteInfo), ArgVars, ArgTypes),
    make_standard_arg_infos(ArgTypes, ArgModes, CodeModel, ModuleInfo, ArgInfo),
    assoc_list.from_corresponding_lists(ArgVars, ArgInfo, ArgVarsInfos),

    arg_info.partition_args(ArgVarsInfos, InVars, OutVars),
    list.length(InVars, NInVars),
    list.length(OutVars, NOutVars),

    call_gen.input_arg_locs(ArgVarsInfos, InputArgs),
    gen_places(InputArgs, ByteInfo, PlaceArgs),

    call_gen.output_arg_locs(ArgVarsInfos, OutputArgs),
    gen_pickups(OutputArgs, ByteInfo, PickupArgs),

    map_var(ByteInfo, PredVar, BytePredVar),
    Call = singleton(byte_higher_order_call(BytePredVar, NInVars, NOutVars,
        Detism)),
    ( CodeModel = model_semi ->
        Check = singleton(byte_semidet_success_check)
    ;
        Check = empty
    ),
    Code = PlaceArgs ++ Call ++ Check ++ PickupArgs.

    % Generate bytecode for an ordinary call.
    %
:- pred gen_call(pred_id::in, proc_id::in, list(prog_var)::in,
    determinism::in, byte_info::in, byte_tree::out) is det.

gen_call(PredId, ProcId, ArgVars, Detism, ByteInfo, Code) :-
    get_module_info(ByteInfo, ModuleInfo),
    module_info_pred_proc_info(ModuleInfo, PredId, ProcId, _, ProcInfo),
    proc_info_arg_info(ProcInfo, ArgInfo),
    assoc_list.from_corresponding_lists(ArgVars, ArgInfo, ArgVarsInfos),

    module_info_pred_info(ModuleInfo, PredId, PredInfo),
    get_is_func(PredInfo, IsFunc),

    call_gen.input_arg_locs(ArgVarsInfos, InputArgs),
    gen_places(InputArgs, ByteInfo, PlaceArgs),

    call_gen.output_arg_locs(ArgVarsInfos, OutputArgs),
    gen_pickups(OutputArgs, ByteInfo, PickupArgs),

    predicate_id(ModuleInfo, PredId, ModuleName, PredName, Arity),
    proc_id_to_int(ProcId, ProcInt),
    Call = singleton(byte_call(ModuleName, PredName, Arity, IsFunc, ProcInt)),
    determinism_to_code_model(Detism, CodeModel),
    ( CodeModel = model_semi ->
        Check = singleton(byte_semidet_success_check)
    ;
        Check = empty
    ),
    Code = PlaceArgs ++ Call ++ Check ++ PickupArgs.

    % Generate bytecode for a call to a builtin.
    %
:- pred gen_builtin(pred_id::in, proc_id::in, list(prog_var)::in,
    byte_info::in, byte_tree::out) is det.

gen_builtin(PredId, ProcId, Args, ByteInfo, Code) :-
    get_module_info(ByteInfo, ModuleInfo),
    ModuleName = predicate_module(ModuleInfo, PredId),
    PredName = predicate_name(ModuleInfo, PredId),
    (
        builtin_ops.translate_builtin(ModuleName, PredName, ProcId,
            Args, SimpleCode)
    ->
        (
            SimpleCode = test(Test),
            map_test(ByteInfo, Test, Code)
        ;
            SimpleCode = assign(Var, Expr),
            map_assign(ByteInfo, Var, Expr, Code)
        ;
            SimpleCode = ref_assign(_Var, _Expr),
            unexpected($module, $pred, "ref_assign")
        ;
            SimpleCode = noop(_DefinedVars),
            Code = empty
        )
    ;
        unexpected($module, $pred, "unknown builtin predicate " ++ PredName)
    ).

:- pred map_test(byte_info::in, simple_expr(prog_var)::in(simple_test_expr),
    byte_tree::out) is det.

map_test(ByteInfo, TestExpr, Code) :-
    (
        TestExpr = binary(Binop, X, Y),
        map_arg(ByteInfo, X, ByteX),
        map_arg(ByteInfo, Y, ByteY),
        Code = singleton(byte_builtin_bintest(Binop, ByteX, ByteY))
    ;
        TestExpr = unary(Unop, X),
        map_arg(ByteInfo, X, ByteX),
        Code = singleton(byte_builtin_untest(Unop, ByteX))
    ).

:- pred map_assign(byte_info::in, prog_var::in,
    simple_expr(prog_var)::in(simple_assign_expr), byte_tree::out) is det.

map_assign(ByteInfo, Var, Expr, Code) :-
    (
        Expr = binary(Binop, X, Y),
        map_arg(ByteInfo, X, ByteX),
        map_arg(ByteInfo, Y, ByteY),
        map_var(ByteInfo, Var, ByteVar),
        Code = singleton(byte_builtin_binop(Binop, ByteX, ByteY, ByteVar))
    ;
        Expr = unary(Unop, X),
        map_arg(ByteInfo, X, ByteX),
        map_var(ByteInfo, Var, ByteVar),
        Code = singleton(byte_builtin_unop(Unop, ByteX, ByteVar))
    ;
        Expr = leaf(X),
        map_var(ByteInfo, X, ByteX),
        map_var(ByteInfo, Var, ByteVar),
        Code = singleton(byte_assign(ByteVar, ByteX))
    ).

:- pred map_arg(byte_info::in, simple_expr(prog_var)::in(simple_arg_expr),
    byte_arg::out) is det.

map_arg(ByteInfo, Expr, ByteArg) :-
    (
        Expr = leaf(Var),
        map_var(ByteInfo, Var, ByteVar),
        ByteArg = byte_arg_var(ByteVar)
    ;
        Expr = int_const(IntVal),
        ByteArg = byte_arg_int_const(IntVal)
    ;
        Expr = float_const(FloatVal),
        ByteArg = byte_arg_float_const(FloatVal)
    ).

%---------------------------------------------------------------------------%

    % Generate bytecode for a unification.
    %
:- pred gen_unify(unification::in, prog_var::in, unify_rhs::in,
    byte_info::in, byte_tree::out) is det.

gen_unify(construct(Var, ConsId, Args, UniModes, _, _, _), _, _,
        ByteInfo, Code) :-
    map_var(ByteInfo, Var, ByteVar),
    map_vars(ByteInfo, Args, ByteArgs),
    map_cons_id(ByteInfo, ConsId, ByteConsId),
    ( ByteConsId = byte_pred_const(_, _, _, _, _) ->
        Code = singleton(byte_construct(ByteVar, ByteConsId, ByteArgs))
    ;
        % Don't call map_uni_modes until after
        % the pred_const test fails, since the arg-modes on
        % unifications that create closures aren't like other arg-modes.
        map_uni_modes(UniModes, Args, ByteInfo, Dirs),
        ( all_dirs_same(Dirs, to_var) ->
            Code = singleton(byte_construct(ByteVar, ByteConsId, ByteArgs))
        ;
            assoc_list.from_corresponding_lists(ByteArgs, Dirs, Pairs),
            Code = singleton(byte_complex_construct(ByteVar, ByteConsId,
                Pairs))
        )
    ).
gen_unify(deconstruct(Var, ConsId, Args, UniModes, _, _), _, _,
        ByteInfo, Code) :-
    map_var(ByteInfo, Var, ByteVar),
    map_vars(ByteInfo, Args, ByteArgs),
    map_cons_id(ByteInfo, ConsId, ByteConsId),
    map_uni_modes(UniModes, Args, ByteInfo, Dirs),
    ( all_dirs_same(Dirs, to_arg) ->
        Code = singleton(byte_deconstruct(ByteVar, ByteConsId, ByteArgs))
    ;
        assoc_list.from_corresponding_lists(ByteArgs, Dirs, Pairs),
        Code = singleton(byte_complex_deconstruct(ByteVar, ByteConsId, Pairs))
    ).
gen_unify(assign(Target, Source), _, _, ByteInfo, Code) :-
    map_var(ByteInfo, Target, ByteTarget),
    map_var(ByteInfo, Source, ByteSource),
    Code = singleton(byte_assign(ByteTarget, ByteSource)).
gen_unify(simple_test(Var1, Var2), _, _, ByteInfo, Code) :-
    map_var(ByteInfo, Var1, ByteVar1),
    map_var(ByteInfo, Var2, ByteVar2),
    get_var_type(ByteInfo, Var1, Var1Type),
    get_var_type(ByteInfo, Var2, Var2Type),
    (
        type_to_ctor(Var1Type, TypeCtor1),
        type_to_ctor(Var2Type, TypeCtor2)
    ->
        ( TypeCtor2 = TypeCtor1 ->
            TypeCtor = TypeCtor1
        ;   unexpected($module, $pred, "simple_test between different types")
        )
    ;
        unexpected($module, $pred, "failed lookup of type id")
    ),
    ByteInfo = byte_info(_, _, ModuleInfo, _, _),
    TypeCategory = classify_type_ctor(ModuleInfo, TypeCtor),
    (
        TypeCategory = ctor_cat_builtin(cat_builtin_int),
        TestId = int_test
    ;
        TypeCategory = ctor_cat_builtin(cat_builtin_char),
        TestId = char_test
    ;
        TypeCategory = ctor_cat_builtin(cat_builtin_string),
        TestId = string_test
    ;
        TypeCategory = ctor_cat_builtin(cat_builtin_float),
        TestId = float_test
    ;
        TypeCategory = ctor_cat_builtin_dummy,
        TestId = dummy_test
    ;
        TypeCategory = ctor_cat_enum(cat_enum_mercury),
        TestId = enum_test
    ;
        TypeCategory = ctor_cat_enum(cat_enum_foreign),
        sorry($module, $pred, "foreign enums with bytecode backend")
    ;
        TypeCategory = ctor_cat_higher_order,
        unexpected($module, $pred, "higher_order_type")
    ;
        TypeCategory = ctor_cat_tuple,
        unexpected($module, $pred, "tuple_type")
    ;
        TypeCategory = ctor_cat_user(_),
        unexpected($module, $pred, "user_ctor_type")
    ;
        TypeCategory = ctor_cat_variable,
        unexpected($module, $pred, "variable_type")
    ;
        TypeCategory = ctor_cat_void,
        unexpected($module, $pred, "void_type")
    ;
        TypeCategory = ctor_cat_system(_),
        unexpected($module, $pred, "system type")
    ),
    Code = singleton(byte_test(ByteVar1, ByteVar2, TestId)).
gen_unify(complicated_unify(_,_,_), _Var, _RHS, _ByteInfo, _Code) :-
    unexpected($module, $pred, "complicated unify").

:- pred map_uni_modes(list(uni_mode)::in, list(prog_var)::in,
    byte_info::in, list(byte_dir)::out) is det.

map_uni_modes([], [], _, []).
map_uni_modes([UniMode | UniModes], [Arg | Args], ByteInfo, [Dir | Dirs]) :-
    UniMode = ((VarInitial - ArgInitial) -> (VarFinal - ArgFinal)),
    get_module_info(ByteInfo, ModuleInfo),
    get_var_type(ByteInfo, Arg, Type),
    mode_to_arg_mode(ModuleInfo, (VarInitial -> VarFinal), Type, VarMode),
    mode_to_arg_mode(ModuleInfo, (ArgInitial -> ArgFinal), Type, ArgMode),
    (
        VarMode = top_in,
        ArgMode = top_out
    ->
        Dir = to_arg
    ;
        VarMode = top_out,
        ArgMode = top_in
    ->
        Dir = to_var
    ;
        VarMode = top_unused,
        ArgMode = top_unused
    ->
        Dir = to_none
    ;
        unexpected($module, $pred,
            "invalid mode for (de)construct unification")
    ),
    map_uni_modes(UniModes, Args, ByteInfo, Dirs).
map_uni_modes([], [_|_], _, _) :-
    unexpected($module, $pred, "length mismatch").
map_uni_modes([_|_], [], _, _) :-
    unexpected($module, $pred, "length mismatch").

:- pred all_dirs_same(list(byte_dir)::in, byte_dir::in)
    is semidet.

all_dirs_same([], _).
all_dirs_same([Dir | Dirs], Dir) :-
    all_dirs_same(Dirs, Dir).

%---------------------------------------------------------------------------%

    % Generate bytecode for a conjunction
    %
:- pred gen_conj(list(hlds_goal)::in, byte_info::in, byte_info::out,
    byte_tree::out) is det.

gen_conj([], !ByteInfo, empty).
gen_conj([Goal | Goals], !ByteInfo, Code) :-
    gen_goal(Goal, !ByteInfo, ThisCode),
    gen_conj(Goals, !ByteInfo, OtherCode),
    Code = ThisCode ++ OtherCode.

%---------------------------------------------------------------------------%

    % Generate bytecode for each disjunct of a disjunction.
    %
:- pred gen_disj(list(hlds_goal)::in, int::in,
    byte_info::in, byte_info::out,  byte_tree::out) is det.

gen_disj([], _, _, _, _) :-
    unexpected($module, $pred, "empty disjunction").
gen_disj([Disjunct | Disjuncts], EndLabel, !ByteInfo, Code) :-
    gen_goal(Disjunct, !ByteInfo, ThisCode),
    (
        Disjuncts = [],
        EnterCode = singleton(byte_enter_disjunct(-1)),
        EndofCode = singleton(byte_endof_disjunct(EndLabel)),
        Code = EnterCode ++ ThisCode ++ EndofCode
    ;
        Disjuncts = [_ | _],
        gen_disj(Disjuncts, EndLabel, !ByteInfo, OtherCode),
        get_next_label(NextLabel, !ByteInfo),
        EnterCode = singleton(byte_enter_disjunct(NextLabel)),
        EndofCode = from_list([byte_endof_disjunct(EndLabel),
            byte_label(NextLabel)]),
        Code = EnterCode ++ ThisCode ++ EndofCode ++ OtherCode
    ).

%---------------------------------------------------------------------------%

    % Generate bytecode for each arm of a switch.
    %
:- pred gen_switch(list(case)::in, prog_var::in, int::in,
    byte_info::in, byte_info::out, byte_tree::out) is det.

gen_switch([], _, _, !ByteInfo, empty).
gen_switch([Case | Cases], Var, EndLabel, !ByteInfo, Code) :-
    Case = case(MainConsId, OtherConsIds, Goal),
    map_cons_id(!.ByteInfo, MainConsId, ByteMainConsId),
    list.map(map_cons_id(!.ByteInfo), OtherConsIds, ByteOtherConsIds),
    gen_goal(Goal, !ByteInfo, GoalCode),
    gen_switch(Cases, Var, EndLabel, !ByteInfo, CasesCode),
    get_next_label(NextLabel, !ByteInfo),
    EnterCode = singleton(byte_enter_switch_arm(ByteMainConsId,
        ByteOtherConsIds, NextLabel)),
    EndofCode = from_list([byte_endof_switch_arm(EndLabel),
        byte_label(NextLabel)]),
    Code = EnterCode ++ GoalCode ++ EndofCode ++ CasesCode.

%---------------------------------------------------------------------------%

:- pred map_cons_id(byte_info::in, cons_id::in, byte_cons_id::out) is det.

map_cons_id(ByteInfo, ConsId, ByteConsId) :-
    get_module_info(ByteInfo, ModuleInfo),
    (
        ConsId = cons(Functor, Arity, _TypeCtor),
        (
            Functor = qualified(ModuleName, FunctorName)
        ;
            Functor = unqualified(_),
            unexpected($module, $pred, "unqualified cons")
        ),
        ConsTag = cons_id_to_tag(ModuleInfo, ConsId),
        map_cons_tag(ConsTag, ByteConsTag),
        ByteConsId = byte_cons(ModuleName, FunctorName, Arity, ByteConsTag)
    ;
        ConsId = tuple_cons(Arity),
        ModuleName = unqualified("builtin"),
        FunctorName = "{}",
        ConsTag = cons_id_to_tag(ModuleInfo, ConsId),
        map_cons_tag(ConsTag, ByteConsTag),
        % XXX We should have a byte_tuple_cons separate from byte_cons.
        ByteConsId = byte_cons(ModuleName, FunctorName, Arity, ByteConsTag)
    ;
        ConsId = closure_cons(ShroudedPredProcId, _EvalMethod),
        proc(PredId, ProcId) = unshroud_pred_proc_id(ShroudedPredProcId),
        predicate_id(ModuleInfo, PredId, ModuleName, PredName, Arity),

        module_info_pred_info(ModuleInfo, PredId, PredInfo),
        get_is_func(PredInfo, IsFunc),

        proc_id_to_int(ProcId, ProcInt),
        ByteConsId = byte_pred_const(ModuleName, PredName, Arity, IsFunc,
            ProcInt)
    ;
        ConsId = int_const(IntVal),
        ByteConsId = byte_int_const(IntVal)
    ;
        ConsId = float_const(FloatVal),
        ByteConsId = byte_float_const(FloatVal)
    ;
        ConsId = char_const(CharVal),
        ByteConsId = byte_char_const(CharVal)
    ;
        ConsId = string_const(StringVal),
        ByteConsId = byte_string_const(StringVal)
    ;
        ConsId = impl_defined_const(_),
        unexpected($module, $pred, "impl_defined_const")
    ;
        ConsId = type_ctor_info_const(ModuleName, TypeName, TypeArity),
        ByteConsId = byte_type_ctor_info_const(ModuleName, TypeName, TypeArity)
    ;
        ConsId = base_typeclass_info_const(ModuleName, ClassId, _, Instance),
        ByteConsId = byte_base_typeclass_info_const(ModuleName, ClassId,
            Instance)
    ;
        ConsId = type_info_cell_constructor(_),
        ByteConsId = byte_type_info_cell_constructor
    ;
        ConsId = typeclass_info_cell_constructor,
        ByteConsId = byte_typeclass_info_cell_constructor
    ;
        ConsId = type_info_const(_),
        sorry($module, $pred, "bytecode doesn't implement type_info_const")
    ;
        ConsId = typeclass_info_const(_),
        sorry($module, $pred, "bytecode doesn't implement typeclass_info_const")
    ;
        ConsId = ground_term_const(_, _),
        sorry($module, $pred, "bytecode doesn't implement ground_term_const")
    ;
        ConsId = tabling_info_const(_),
        sorry($module, $pred, "bytecode cannot implement tabling")
    ;
        ConsId = table_io_decl(_),
        sorry($module, $pred, "bytecode cannot implement table io decl")
    ;
        ConsId = deep_profiling_proc_layout(_),
        sorry($module, $pred, "bytecode cannot implement deep profiling")
    ).

:- pred map_cons_tag(cons_tag::in, byte_cons_tag::out) is det.

map_cons_tag(no_tag, byte_no_tag).
    % `single_functor' is just an optimized version of `unshared_tag(0)'
    % this optimization is not important for the bytecode
map_cons_tag(single_functor_tag, byte_unshared_tag(0)).
map_cons_tag(unshared_tag(Primary), byte_unshared_tag(Primary)).
map_cons_tag(direct_arg_tag(_), _) :-
    sorry($module, $pred, "bytecode with direct_arg_tag").
map_cons_tag(shared_remote_tag(Primary, Secondary),
    byte_shared_remote_tag(Primary, Secondary)).
map_cons_tag(shared_local_tag(Primary, Secondary),
    byte_shared_local_tag(Primary, Secondary)).
map_cons_tag(string_tag(_), _) :-
    unexpected($module, $pred, "string_tag cons tag " ++
        "for non-string_constant cons id").
map_cons_tag(int_tag(IntVal), byte_enum_tag(IntVal)).
map_cons_tag(foreign_tag(_, _), _) :-
    sorry($module, $pred, "bytecode with foreign tags").
map_cons_tag(float_tag(_), _) :-
    unexpected($module, $pred, "float_tag cons tag " ++
        "for non-float_constant cons id").
map_cons_tag(closure_tag(_, _, _), _) :-
    unexpected($module, $pred, "closure_tag cons tag " ++
        "for non-closure_cons cons id").
map_cons_tag(type_ctor_info_tag(_, _, _), _) :-
    unexpected($module, $pred, "type_ctor_info_tag cons tag " ++
        "for non-type_ctor_info_constant cons id").
map_cons_tag(base_typeclass_info_tag(_, _, _), _) :-
    unexpected($module, $pred, "base_typeclass_info_tag cons tag " ++
        "for non-base_typeclass_info_constant cons id").
map_cons_tag(type_info_const_tag(_), _) :-
    unexpected($module, $pred, "type_info_const cons tag " ++
        "for non-type_info_const cons id").
map_cons_tag(typeclass_info_const_tag(_), _) :-
    unexpected($module, $pred, "typeclass_info_const cons tag " ++
        "for non-typeclass_info_const cons id").
map_cons_tag(ground_term_const_tag(_, _), _) :-
    unexpected($module, $pred, "ground_term_const cons tag " ++
        "for non-ground_term_const cons id").
map_cons_tag(tabling_info_tag(_, _), _) :-
    unexpected($module, $pred, "tabling_info_tag cons tag " ++
        "for non-tabling_info_constant cons id").
map_cons_tag(deep_profiling_proc_layout_tag(_, _), _) :-
    unexpected($module, $pred, "deep_profiling_proc_layout_tag cons tag " ++
        "for non-deep_profiling_proc_static cons id").
map_cons_tag(table_io_decl_tag(_, _), _) :-
    unexpected($module, $pred, "table_io_decl_tag cons tag " ++
        "for non-table_io_decl cons id").
map_cons_tag(reserved_address_tag(_), _) :-
    % These should only be generated if the --num-reserved-addresses
    % or --num-reserved-objects options are used.
    sorry($module, $pred, "bytecode with --num-reserved-addresses " ++
        "or --num-reserved-objects").
map_cons_tag(shared_with_reserved_addresses_tag(_, _), _) :-
    % These should only be generated if the --num-reserved-addresses
    % or --num-reserved-objects options are used.
    sorry($module, $pred, "bytecode with --num-reserved-addresses " ++
        "or --num-reserved-objects").

%---------------------------------------------------------------------------%

:- pred create_varmap(list(prog_var)::in, prog_varset::in,
    vartypes::in, int::in, map(prog_var, byte_var)::in,
    map(prog_var, byte_var)::out, list(byte_var_info)::out) is det.

create_varmap([], _, _, _, !VarMap, []).
create_varmap([Var | VarList], VarSet, VarTypes, N0, !VarMap, VarInfos) :-
    map.det_insert(Var, N0, !VarMap),
    N1 = N0 + 1,
    varset.lookup_name(VarSet, Var, VarName),
    map.lookup(VarTypes, Var, VarType),
    create_varmap(VarList, VarSet, VarTypes, N1, !VarMap, VarInfosTail),
    VarInfos = [var_info(VarName, VarType) | VarInfosTail].

%---------------------------------------------------------------------------%(

:- type byte_info
    --->    byte_info(
                byteinfo_varmap         :: map(prog_var, byte_var),
                byteinfo_vartypes       :: vartypes,
                byteinfo_moduleinfo     :: module_info,
                byteinfo_label_counter  :: counter,
                byteinfo_temp_counter   :: counter
            ).

:- pred init_byte_info(module_info::in, map(prog_var, byte_var)::in,
    vartypes::in, byte_info::out) is det.

init_byte_info(ModuleInfo, VarMap, VarTypes, ByteInfo) :-
    ByteInfo = byte_info(VarMap, VarTypes, ModuleInfo,
        counter.init(0), counter.init(0)).

:- pred get_module_info(byte_info::in, module_info::out) is det.

get_module_info(ByteInfo, ByteInfo ^ byteinfo_moduleinfo).

:- pred map_vars(byte_info::in,
    list(prog_var)::in, list(byte_var)::out) is det.

map_vars(ByteInfo, Vars, ByteVars) :-
    map_vars_2(ByteInfo ^ byteinfo_varmap, Vars, ByteVars).

:- pred map_vars_2(map(prog_var, byte_var)::in,
    list(prog_var)::in, list(byte_var)::out) is det.

map_vars_2(_VarMap, [], []).
map_vars_2(VarMap, [Var | Vars], [ByteVar | ByteVars]) :-
    map.lookup(VarMap, Var, ByteVar),
    map_vars_2(VarMap, Vars, ByteVars).

:- pred map_var(byte_info::in, prog_var::in,
    byte_var::out) is det.

map_var(ByteInfo, Var, ByteVar) :-
    map.lookup(ByteInfo ^ byteinfo_varmap, Var, ByteVar).

:- pred get_var_type(byte_info::in, prog_var::in,
    mer_type::out) is det.

get_var_type(ByteInfo, Var, Type) :-
    map.lookup(ByteInfo ^ byteinfo_vartypes, Var, Type).

:- pred get_next_label(int::out, byte_info::in, byte_info::out)
    is det.

get_next_label(Label, !ByteInfo) :-
    LabelCounter0 = !.ByteInfo ^ byteinfo_label_counter,
    counter.allocate(Label, LabelCounter0, LabelCounter),
    !ByteInfo ^ byteinfo_label_counter := LabelCounter.

:- pred get_next_temp(int::out, byte_info::in, byte_info::out)
    is det.

get_next_temp(Temp, !ByteInfo) :-
    TempCounter0 = !.ByteInfo ^ byteinfo_temp_counter,
    counter.allocate(Temp, TempCounter0, TempCounter),
    !ByteInfo ^ byteinfo_temp_counter := TempCounter.

:- pred get_counts(byte_info::in, int::out, int::out) is det.

get_counts(ByteInfo0, Label, Temp) :-
    LabelCounter0 = ByteInfo0 ^ byteinfo_label_counter,
    counter.allocate(Label, LabelCounter0, _LabelCounter),
    TempCounter0 = ByteInfo0 ^ byteinfo_temp_counter,
    counter.allocate(Temp, TempCounter0, _TempCounter).

%---------------------------------------------------------------------------%

:- pred get_is_func(pred_info::in, byte_is_func::out) is det.

get_is_func(PredInfo, IsFunc) :-
    PredOrFunc = pred_info_is_pred_or_func(PredInfo),
    (
        PredOrFunc = pf_predicate,
        IsFunc = 0
    ;
        PredOrFunc = pf_function,
        IsFunc = 1
    ).

%---------------------------------------------------------------------------%
:- end_module bytecode_backend.bytecode_gen.
%---------------------------------------------------------------------------%
