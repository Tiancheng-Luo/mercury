%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 1994-2008, 2010-2011 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: live_vars.m.
% Main authors: conway, zs.
%
% This module finds out what variables need to be saved across calls,
% across goals that may fail, and in parallel conjunctions. It then does those
% things with that information. First, it attaches that information to the
% relevant goal as a LLDS-backend-specific annotation. Second, it invokes
% the relevant type class method of the allocator-specific data structure
% it is passed; the basic stack slot allocator and the optimizing stack slot
% allocator pass different instances of this type class.
%
%-----------------------------------------------------------------------------%

:- module ll_backend.live_vars.
:- interface.

:- import_module check_hlds.type_util.
:- import_module hlds.hlds_goal.
:- import_module hlds.hlds_llds.
:- import_module hlds.hlds_module.
:- import_module hlds.hlds_pred.
:- import_module parse_tree.prog_data.
:- import_module parse_tree.set_of_var.

:- import_module array.
:- import_module bool.
:- import_module list.

%-----------------------------------------------------------------------------%

:- pred build_dummy_type_array(module_info::in, vartypes::in,
    array(is_dummy_type)::out, list(prog_var)::out) is det.

%-----------------------------------------------------------------------------%

:- type alloc_data
    --->    alloc_data(
                ad_module_info          ::  module_info,
                ad_proc_info            ::  proc_info,
                ad_typeinfo_liveness    ::  bool,
                ad_opt_no_return_calls  ::  bool,

                % We want to remove variables of dummy types from the live sets
                % we generate. The array is indexed by variable number: each
                % slot says whether the corresponding variable is of a dummy
                % type or not.
                %
                % The array may itself be a dummy if the operations of the
                % stack_alloc_info type class do not need it.
                ad_dummy_var_array      ::  array(is_dummy_type)
            ).

:- typeclass stack_alloc_info(T) where [
    pred at_call_site(need_across_call::in, alloc_data::in,
        T::in, T::out) is det,
    pred at_resume_site(need_in_resume::in, alloc_data::in,
        T::in, T::out) is det,
    pred at_par_conj(need_in_par_conj::in, alloc_data::in,
        T::in, T::out) is det
].

:- pred build_live_sets_in_goal_no_par_stack(hlds_goal::in, hlds_goal::out,
    set_of_progvar::in, alloc_data::in, T::in, T::out,
    set_of_progvar::in, set_of_progvar::out,
    set_of_progvar::in, set_of_progvar::out) is det <= stack_alloc_info(T).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module hlds.arg_info.
:- import_module hlds.code_model.
:- import_module hlds.hlds_goal.
:- import_module hlds.hlds_llds.
:- import_module hlds.hlds_rtti.
:- import_module hlds.instmap.
:- import_module parse_tree.prog_data.

:- import_module assoc_list.
:- import_module enum.
:- import_module int.
:- import_module map.
:- import_module pair.
:- import_module require.

%-----------------------------------------------------------------------------%

build_dummy_type_array(ModuleInfo, VarTypes, DummyTypeArray, DummyVars) :-
    map.to_assoc_list(VarTypes, VarsTypes),
    list.foldl(max_var_num, VarsTypes, 0, MaxVarNum),
    % We want to index the array with variable numbers, which will be from
    % 1 to MaxVarNum.
    array.init(MaxVarNum + 1, is_not_dummy_type, DummyTypeArray0),
    set_dummy_array_elements(ModuleInfo, VarsTypes,
        DummyTypeArray0, DummyTypeArray, [], DummyVars).

:- pred max_var_num(pair(prog_var, mer_type)::in, int::in, int::out) is det.

max_var_num(Var - _Type, !MaxVarNum) :-
    VarNum = to_int(Var),
    int.max(VarNum, !MaxVarNum).

:- pred set_dummy_array_elements(module_info::in,
    assoc_list(prog_var, mer_type)::in,
    array(is_dummy_type)::array_di, array(is_dummy_type)::array_uo,
    list(prog_var)::in, list(prog_var)::out) is det.

set_dummy_array_elements(_, [], !DummyTypeArray, !DummyVars).
set_dummy_array_elements(ModuleInfo, [VarType | VarsTypes],
        !DummyTypeArray, !DummyVars) :-
    VarType = Var - Type,
    IsDummyType = check_dummy_type(ModuleInfo, Type),
    (
        IsDummyType = is_dummy_type,
        array.set(to_int(Var), IsDummyType, !DummyTypeArray),
        !:DummyVars = [Var | !.DummyVars]
    ;
        IsDummyType = is_not_dummy_type
        % This is the default; the array slot already has the right value.
    ),
    set_dummy_array_elements(ModuleInfo, VarsTypes,
        !DummyTypeArray, !DummyVars).

%-----------------------------------------------------------------------------%

    % Information about which variables in a parallel conjunction need stack
    % slots.
    %
:- type parallel_stackvars
    --->    parallel_stackvars(
                % Variables nonlocal to the parallel conjunction which need
                % their own stack slots.
                set_of_progvar,

                % Variables local to parallel conjuncts prior to the
                % current conjunct which need stack slots.
                list(set_of_progvar),

                % Accumulating set of variables local to the current
                % parallel conjunct which need stack slots.
                set_of_progvar
            ).

%-----------------------------------------------------------------------------%

% The stack_slots structure (map(prog_var, lval)) is threaded through the
% traversal of the goal. The liveness information is computed from the liveness
% delta annotations.

build_live_sets_in_goal_no_par_stack(Goal0, Goal,
        ResumeVars0, AllocData, !StackAlloc, !Liveness, !NondetLiveness) :-
    ParStackVars0 = parallel_stackvars(set_of_var.init, [], set_of_var.init),
    build_live_sets_in_goal(Goal0, Goal, ResumeVars0,
        AllocData, !StackAlloc, !Liveness, !NondetLiveness,
        ParStackVars0, _ParStackVars).

:- pred build_live_sets_in_goal(hlds_goal::in, hlds_goal::out,
    set_of_progvar::in, alloc_data::in, T::in, T::out,
    set_of_progvar::in, set_of_progvar::out,
    set_of_progvar::in, set_of_progvar::out,
    parallel_stackvars::in, parallel_stackvars::out)
    is det <= stack_alloc_info(T).

build_live_sets_in_goal(Goal0, Goal, ResumeVars0,
        AllocData, !StackAlloc, !Liveness, !NondetLiveness, !ParStackVars) :-
    Goal0 = hlds_goal(GoalExpr0, GoalInfo0),
    goal_info_get_pre_deaths(GoalInfo0, PreDeaths),
    goal_info_get_pre_births(GoalInfo0, PreBirths),
    goal_info_get_post_deaths(GoalInfo0, PostDeaths),
    goal_info_get_post_births(GoalInfo0, PostBirths),

    % note: we must be careful to apply deaths before births
    set_of_var.difference(!.Liveness, PreDeaths, !:Liveness),
    set_of_var.union(!.Liveness, PreBirths, !:Liveness),

    % If the goal is atomic, we want to apply the postdeaths before processing
    % the goal, but if the goal is a compound goal, then we want to apply them
    % after processing it.
    HasSubGoals = goal_expr_has_subgoals(GoalExpr0),
    (
        HasSubGoals = does_not_have_subgoals,
        set_of_var.difference(!.Liveness, PostDeaths, !:Liveness)
    ;
        HasSubGoals = has_subgoals
    ),

    goal_info_get_resume_point(GoalInfo0, ResumePoint),
    (
        ResumePoint = no_resume_point,
        ResumeVars1 = ResumeVars0,
        GoalInfo1 = GoalInfo0
    ;
        ResumePoint = resume_point(ResumePointVars, Locs),
        ( resume_locs_include_stack(Locs, yes) ->
            set_of_var.union(ResumeVars0, ResumePointVars, ResumeVars1),
            ResumeOnStack = yes
        ;
            ResumeVars1 = ResumeVars0,
            ResumeOnStack = no
        ),
        NeedInResume = need_in_resume(ResumeOnStack, ResumeVars1,
            !.NondetLiveness),
        record_resume_site(NeedInResume, AllocData,
            GoalInfo0, GoalInfo1, !StackAlloc)
    ),

    build_live_sets_in_goal_2(GoalExpr0, GoalExpr, GoalInfo1, GoalInfo,
        ResumeVars1, AllocData, !StackAlloc, !Liveness, !NondetLiveness,
        !ParStackVars),

    (
        HasSubGoals = does_not_have_subgoals
    ;
        HasSubGoals = has_subgoals,
        set_of_var.difference(!.Liveness, PostDeaths, !:Liveness)
    ),

    set_of_var.union(!.Liveness, PostBirths, !:Liveness),
    Goal = hlds_goal(GoalExpr, GoalInfo).

:- pred resume_locs_include_stack(resume_locs::in, bool::out) is det.

resume_locs_include_stack(resume_locs_orig_only, no).
resume_locs_include_stack(resume_locs_stack_only, yes).
resume_locs_include_stack(resume_locs_orig_and_stack, yes).
resume_locs_include_stack(resume_locs_stack_and_orig, yes).

%-----------------------------------------------------------------------------%

    % Here we process each of the different sorts of goals. `Liveness' is the
    % set of live variables, i.e. vars which have been referenced and may be
    % referenced again (during forward execution). `ResumeVars' is the set
    % of variables that may or may not be `live' during the current forward
    % execution but will become live again on backtracking. `StackAlloc' is the
    % interference graph, i.e. the set of sets of variables which need to be
    % on the stack at the same time.
    %
:- pred build_live_sets_in_goal_2(hlds_goal_expr::in, hlds_goal_expr::out,
    hlds_goal_info::in, hlds_goal_info::out,
    set_of_progvar::in, alloc_data::in, T::in, T::out,
    set_of_progvar::in, set_of_progvar::out,
    set_of_progvar::in, set_of_progvar::out,
    parallel_stackvars::in, parallel_stackvars::out)
    is det <= stack_alloc_info(T).

build_live_sets_in_goal_2(GoalExpr0, GoalExpr, GoalInfo0, GoalInfo,
        ResumeVars0, AllocData, !StackAlloc, !Liveness, !NondetLiveness,
        !ParStackVars) :-
    (
        GoalExpr0 = conj(ConjType, Goals0),
        (
            ConjType = plain_conj,
            GoalInfo = GoalInfo0,
            build_live_sets_in_conj(Goals0, Goals, ResumeVars0, AllocData,
                !StackAlloc, !Liveness, !NondetLiveness, !ParStackVars)
        ;
            ConjType = parallel_conj,
            !.ParStackVars = parallel_stackvars(OuterNonLocals,
                OuterLocalStackVars, OuterAccStackVars0),

            % Since each parallel conjunct may be run in a different Mercury
            % context to the current context, we must save all the variables
            % that are live or nonlocal to the parallel conjunction. Nonlocal
            % variables that are currently free, but are bound inside one of
            % the conjuncts need a stackslot because they are passed out
            % by reference to that stackslot. Variables needed on backtracking
            % must be available in a stackslot past the parallel conjunction
            % as well.
            NonLocals = goal_info_get_code_gen_nonlocals(GoalInfo0),
            LiveSet = set_of_var.union_list([set_to_bitset(NonLocals),
                !.Liveness, ResumeVars0]),

            InnerNonLocals = LiveSet `set_of_var.union` OuterNonLocals,
            InnerParStackVars0 =
                parallel_stackvars(InnerNonLocals, [], set_of_var.init),
            build_live_sets_in_par_conj(Goals0, Goals, ResumeVars0, AllocData,
                !StackAlloc, !Liveness, !NondetLiveness,
                InnerParStackVars0, InnerParStackVars),
            InnerParStackVars = parallel_stackvars(_, InnerStackVars, _),

            % This is safe but suboptimal. It causes all variables which need
            % stack slots in a parallel conjunction to have distinct stack
            % slots. Variables local to a single conjunct could share stack
            % slots, as long as the _sets_ of stack slots allocated to
            % different parallel conjuncts are distinct.
            NeedInParConj = need_in_par_conj(InnerNonLocals `set_of_var.union`
                set_of_var.union_list(InnerStackVars)),
            record_par_conj(NeedInParConj, AllocData,
                GoalInfo0, GoalInfo, !StackAlloc),

            % All the local variables which needed stack slots in the parallel
            % conjuncts (InnerStackVars) become part of the accumulating set of
            % variables that have stack slots.  Variables which are not local
            % to but are needed in the parallel conjunctions also become part
            % of the accumulating set.
            OuterAccStackVars = OuterAccStackVars0
                `set_of_var.union` set_of_var.union_list(InnerStackVars)
                `set_of_var.union`
                    (LiveSet `set_of_var.difference` OuterNonLocals),
            !:ParStackVars = parallel_stackvars(OuterNonLocals,
                OuterLocalStackVars, OuterAccStackVars)
        ),
        GoalExpr = conj(ConjType, Goals)
    ;
        GoalExpr0 = disj(Goals0),
        build_live_sets_in_disj(Goals0, Goals, GoalInfo0,
            ResumeVars0, AllocData, !StackAlloc, !Liveness, !NondetLiveness,
            !ParStackVars),
        (
            Goals = [FirstGoal | _],
            FirstGoal = hlds_goal(_, FirstGoalInfo),
            goal_info_get_resume_point(FirstGoalInfo, ResumePoint),
            (
                ResumePoint = resume_point(ResumeVars, _Locs),
                % If we can backtrack into the disjunction, we must protect the
                % stack slots needed by any of its resumption points from being
                % reused in the following code. The first resumption point's
                % variables include all the variables needed by all the
                % resumption points. However, the first disjunct can be
                % orig_only while later disjuncts are include the stack.

                % Note that we must check the disjunction's code model, not any
                % disjuncts'; the disjunction as a whole can be model_non
                % without any disjunct being model_non.
                (
                    goal_info_get_code_model(GoalInfo0) = model_non,
                    some [Disjunct] (
                        list.member(Disjunct, Goals),
                        Disjunct = hlds_goal(_, DisjunctGoalInfo),
                        goal_info_get_resume_point(DisjunctGoalInfo,
                            DisjunctResumePoint),
                        DisjunctResumePoint = resume_point(_, Locs),
                        resume_locs_include_stack(Locs, yes)
                    )
                ->
                    set_of_var.union(!.NondetLiveness, ResumeVars,
                        !:NondetLiveness)
                ;
                    true
                )
            ;
                % We can get here if the disjunction is not really a
                % disjunction, because the first alternative cannot fail
                % and will be committed to (e.g. in a first-solution context).
                % Simplification should eliminate such disjunctions, replacing
                % them with the first disjunct, but until that is done,
                % we must handle them here.
                ResumePoint = no_resume_point
            )
        ;
            Goals = []
        ),
        GoalExpr = disj(Goals),
        GoalInfo = GoalInfo0
    ;
        GoalExpr0 = switch(Var, CanFail, Cases0),
        build_live_sets_in_cases(Cases0, Cases, ResumeVars0, AllocData,
            !StackAlloc, !Liveness, !NondetLiveness, !ParStackVars),
        GoalExpr = switch(Var, CanFail, Cases),
        GoalInfo = GoalInfo0
    ;
        GoalExpr0 = if_then_else(Vars, Cond0, Then0, Else0),
        Liveness0 = !.Liveness,
        NondetLiveness0 = !.NondetLiveness,
        build_live_sets_in_goal(Cond0, Cond, ResumeVars0, AllocData,
            !StackAlloc, Liveness0, LivenessCond,
            NondetLiveness0, NondetLivenessCond, !ParStackVars),
        build_live_sets_in_goal(Then0, Then, ResumeVars0, AllocData,
            !StackAlloc, LivenessCond, _LivenessThen,
            NondetLivenessCond, NondetLivenessThen, !ParStackVars),
        build_live_sets_in_goal(Else0, Else, ResumeVars0, AllocData,
            !StackAlloc, Liveness0, Liveness,
            NondetLiveness0, NondetLivenessElse, !ParStackVars),
        set_of_var.union(NondetLivenessThen, NondetLivenessElse,
            NondetLiveness),
        !:Liveness = Liveness,
        !:NondetLiveness = NondetLiveness,
        GoalExpr = if_then_else(Vars, Cond, Then, Else),
        GoalInfo = GoalInfo0
    ;
        GoalExpr0 = negation(SubGoal0),
        build_live_sets_in_goal(SubGoal0, SubGoal, ResumeVars0, AllocData,
            !StackAlloc, !Liveness, !NondetLiveness, !ParStackVars),
        GoalExpr = negation(SubGoal),
        GoalInfo = GoalInfo0
    ;
        GoalExpr0 = scope(Reason, SubGoal0),
        ( Reason = from_ground_term(TermVar, from_ground_term_construct) ->
            % We do not modify construct unifications or conjunctions,
            % so we do not modify these scopes, which contain only a
            % conjunction of construct unifications.
            GoalExpr = GoalExpr0,
            GoalInfo = GoalInfo0,
            % The scope does not contain any calls, resume points or parallel
            % conjunctions, so there are no updates to !StackAlloc,
            % !NondetLiveness, or !ParStackVars.
            set_of_var.insert(TermVar, !Liveness)
        ;
            NondetLiveness0 = !.NondetLiveness,
            build_live_sets_in_goal(SubGoal0, SubGoal, ResumeVars0, AllocData,
                !StackAlloc, !Liveness, !NondetLiveness, !ParStackVars),
            % If the "some" goal cannot succeed more than once, then execution
            % cannot backtrack into the inner goal once control has left it.
            % Therefore the code following the scope can reuse any stack slots
            % needed by nondet code in the inner goal.
            CodeModel = goal_info_get_code_model(GoalInfo0),
            (
                CodeModel = model_non
            ;
                ( CodeModel = model_det
                ; CodeModel = model_semi
                ),
                !:NondetLiveness = NondetLiveness0
            ),
            GoalExpr = scope(Reason, SubGoal),
            GoalInfo = GoalInfo0
        )
    ;
        GoalExpr0 = generic_call(GenericCall, ArgVars, Modes, _Det),
        GoalExpr = GoalExpr0,
        (
            GenericCall = cast(_),
            GoalInfo = GoalInfo0
        ;
            ( GenericCall = higher_order(_, _, _, _)
            ; GenericCall = class_method(_, _, _, _)
            ; GenericCall = event_call(_)
            ),
            ProcInfo = AllocData ^ ad_proc_info,
            proc_info_get_vartypes(ProcInfo, VarTypes),
            map.apply_to_list(ArgVars, VarTypes, Types),
            ModuleInfo = AllocData ^ ad_module_info,
            arg_info.partition_generic_call_args(ModuleInfo, ArgVars,
                Types, Modes, _InVars, OutVars, _UnusedVars),
            build_live_sets_in_call(set_to_bitset(OutVars),
                GoalInfo0, GoalInfo, ResumeVars0, AllocData,
                !StackAlloc, !.Liveness, !NondetLiveness, !ParStackVars)
        )
    ;
        GoalExpr0 = plain_call(PredId, ProcId, ArgVars, Builtin, _, _),
        GoalExpr = GoalExpr0,
        ModuleInfo = AllocData ^ ad_module_info,
        CallerProcInfo = AllocData ^ ad_proc_info,
        proc_info_get_vartypes(CallerProcInfo, VarTypes),
        module_info_pred_proc_info(ModuleInfo, PredId, ProcId, _, ProcInfo),
        arg_info.partition_proc_call_args(ProcInfo, VarTypes, ModuleInfo,
            ArgVars, _InVars, OutVars, _UnusedVars),
        (
            Builtin = inline_builtin,
            GoalInfo = GoalInfo0
        ;
            ( Builtin = out_of_line_builtin
            ; Builtin = not_builtin
            ),
            build_live_sets_in_call(set_to_bitset(OutVars),
                GoalInfo0, GoalInfo, ResumeVars0, AllocData,
                !StackAlloc, !.Liveness, !NondetLiveness, !ParStackVars)
        )
    ;
        GoalExpr0 = unify(_, _, _, Unification, _),
        GoalExpr = GoalExpr0,
        GoalInfo = GoalInfo0,
        (
            ( Unification = construct(_, _, _, _, _, _, _)
            ; Unification = deconstruct(_, _, _, _, _, _)
            ; Unification = assign(_, _)
            ; Unification = simple_test(_, _)
            )
        ;
            Unification = complicated_unify(_, _, _),
            unexpected($module, $pred, "complicated_unify")
        )
    ;
        GoalExpr0 = call_foreign_proc(Attributes, PredId, ProcId, Args,
            _, _, _),
        GoalExpr = GoalExpr0,
        ModuleInfo = AllocData ^ ad_module_info,
        CallerProcInfo = AllocData ^ ad_proc_info,
        proc_info_get_vartypes(CallerProcInfo, VarTypes),
        module_info_pred_proc_info(ModuleInfo, PredId, ProcId, _, ProcInfo),
        ArgVars = list.map(foreign_arg_var, Args),
        arg_info.partition_proc_call_args(ProcInfo, VarTypes, ModuleInfo,
            ArgVars, _InVars, OutVars, _UnusedVars),
        CodeModel = goal_info_get_code_model(GoalInfo0),
        (
            % We don't need to save any variables onto the stack before a
            % foreign_proc if we know that it can't succeed more than once
            % and that it is not going to call back Mercury code, because
            % such pragma C code won't clobber the registers.

            CodeModel \= model_non,
            get_may_call_mercury(Attributes) = proc_will_not_call_mercury
        ->
            GoalInfo = GoalInfo0
        ;
            % The variables which need to be saved onto the stack before
            % the call are all the variables that are live after the call
            % (except for the output arguments produced by the call), plus
            % all the variables that may be needed at an enclosing resumption
            % point.
            build_live_sets_in_call(set_to_bitset(OutVars),
                GoalInfo0, GoalInfo, ResumeVars0, AllocData,
                !StackAlloc, !.Liveness, !NondetLiveness, !ParStackVars)
        )
    ;
        GoalExpr0 = shorthand(_),
        % These should have been expanded out by now.
        unexpected($module, $pred, "shorthand")
    ).

%-----------------------------------------------------------------------------%

    % The variables which need to be saved onto the stack, directly or
    % indirectly, before a call or may_call_mercury foreign_proc are all
    % the variables that are live after the goal except for the output
    % arguments produced by the goal, plus all the variables that may be
    % needed at an enclosing resumption point.
    %
:- pred build_live_sets_in_call(set_of_progvar::in, hlds_goal_info::in,
    hlds_goal_info::out, set_of_progvar::in, alloc_data::in, T::in, T::out,
    set_of_progvar::in, set_of_progvar::in, set_of_progvar::out,
    parallel_stackvars::in, parallel_stackvars::out)
    is det <= stack_alloc_info(T).

build_live_sets_in_call(OutVars, GoalInfo0, GoalInfo, ResumeVars0, AllocData,
        !StackAlloc, Liveness, !NondetLiveness, !ParStackVars) :-
    set_of_var.difference(Liveness, OutVars, ForwardVars0),

    % Might need to add more live variables with typeinfo liveness
    % calculation.

    maybe_add_typeinfo_liveness(AllocData ^ ad_proc_info,
        AllocData ^ ad_typeinfo_liveness, OutVars, ForwardVars0, ForwardVars),

    Detism = goal_info_get_determinism(GoalInfo0),
    (
        Detism = detism_erroneous,
        AllocData ^ ad_opt_no_return_calls = yes
    ->
        NeedAcrossCall = need_across_call(set_of_var.init, set_of_var.init,
            set_of_var.init)
    ;
        NeedAcrossCall = need_across_call(ForwardVars, ResumeVars0,
            !.NondetLiveness)
    ),

    record_call_site(NeedAcrossCall, AllocData,
        GoalInfo0, GoalInfo, !StackAlloc),

    % If this is a nondet call, then all the stack slots we need
    % must be protected against reuse in following code.

    CodeModel = goal_info_get_code_model(GoalInfo),
    (
        CodeModel = model_det
    ;
        CodeModel = model_semi
    ;
        CodeModel = model_non,
        set_of_var.union(!.NondetLiveness, ForwardVars, !:NondetLiveness)
    ),

    % In a parallel conjunction all the stack slots we need must not be reused
    % in other parallel conjuncts.  We keep track of which variables have been
    % allocated stack slots in each conjunct.

    !.ParStackVars = parallel_stackvars(Nonlocals, ParallelVars, AccVars0),
    AccVars = AccVars0 `set_of_var.union`
        (ForwardVars `set_of_var.difference` Nonlocals),
    !:ParStackVars = parallel_stackvars(Nonlocals, ParallelVars, AccVars).

%-----------------------------------------------------------------------------%

:- pred build_live_sets_in_conj(list(hlds_goal)::in, list(hlds_goal)::out,
    set_of_progvar::in, alloc_data::in, T::in, T::out,
    set_of_progvar::in, set_of_progvar::out,
    set_of_progvar::in, set_of_progvar::out,
    parallel_stackvars::in, parallel_stackvars::out)
    is det <= stack_alloc_info(T).

build_live_sets_in_conj([], [], _, _, !StackAlloc, !Liveness, !NondetLiveness,
        !ParStackVars).
build_live_sets_in_conj([Goal0 | Goals0], [Goal | Goals], ResumeVars0,
        AllocData, !StackAlloc, !Liveness, !NondetLiveness, !ParStackVars) :-
    (
        Goal0 = hlds_goal(_, GoalInfo),
        InstMapDelta = goal_info_get_instmap_delta(GoalInfo),
        instmap_delta_is_unreachable(InstMapDelta)
    ->
        build_live_sets_in_goal(Goal0, Goal, ResumeVars0, AllocData,
            !StackAlloc, !Liveness, !NondetLiveness, !ParStackVars),
        Goals = [] % XXX was Goals = Goal0
    ;
        build_live_sets_in_goal(Goal0, Goal, ResumeVars0, AllocData,
            !StackAlloc, !Liveness, !NondetLiveness, !ParStackVars),
        build_live_sets_in_conj(Goals0, Goals, ResumeVars0, AllocData,
            !StackAlloc, !Liveness, !NondetLiveness, !ParStackVars)
    ).

%-----------------------------------------------------------------------------%

:- pred build_live_sets_in_par_conj(list(hlds_goal)::in, list(hlds_goal)::out,
    set_of_progvar::in, alloc_data::in, T::in, T::out,
    set_of_progvar::in, set_of_progvar::out,
    set_of_progvar::in, set_of_progvar::out,
    parallel_stackvars::in, parallel_stackvars::out)
    is det <= stack_alloc_info(T).

build_live_sets_in_par_conj([], [], _, _,
        !StackAlloc, Liveness, Liveness, !NondetLiveness,
        ParStackVars, ParStackVars).
build_live_sets_in_par_conj([Goal0 | Goals0], [Goal | Goals], ResumeVars0,
        AllocData, !StackAlloc, Liveness0, Liveness, !NondetLiveness,
        ParStackVars0, ParStackVars) :-
    build_live_sets_in_goal(Goal0, Goal, ResumeVars0, AllocData,
        !StackAlloc, Liveness0, Liveness, !NondetLiveness,
        ParStackVars0, ParStackVars1),
    ParStackVars1 = parallel_stackvars(Nonlocals, PrevSets1, CurSet1),
    ParStackVars2 = parallel_stackvars(Nonlocals, [CurSet1 | PrevSets1],
        set_of_var.init),
    build_live_sets_in_par_conj(Goals0, Goals, ResumeVars0, AllocData,
        !StackAlloc, Liveness0, _Liveness1, !NondetLiveness,
        ParStackVars2, ParStackVars).

%-----------------------------------------------------------------------------%

:- pred build_live_sets_in_disj(list(hlds_goal)::in, list(hlds_goal)::out,
    hlds_goal_info::in, set_of_progvar::in, alloc_data::in,
    T::in, T::out, set_of_progvar::in, set_of_progvar::out,
    set_of_progvar::in, set_of_progvar::out,
    parallel_stackvars::in, parallel_stackvars::out)
    is det <= stack_alloc_info(T).

build_live_sets_in_disj([], [], _, _, _,
        !StackAlloc, !Liveness, !NondetLiveness, !ParStackVars).
build_live_sets_in_disj([Goal0 | Goals0], [Goal | Goals],
        DisjGoalInfo, ResumeVars0, AllocData, !StackAlloc,
        Liveness0, Liveness, NondetLiveness0, NondetLiveness, !ParStackVars) :-
    Goal = hlds_goal(_, GoalInfo),
    build_live_sets_in_goal(Goal0, Goal, ResumeVars0, AllocData,
        !StackAlloc, Liveness0, Liveness,
        NondetLiveness0, NondetLiveness1, !ParStackVars),
    build_live_sets_in_disj(Goals0, Goals, DisjGoalInfo, ResumeVars0,
        AllocData, !StackAlloc, Liveness0, _Liveness2,
        NondetLiveness0, NondetLiveness2, !ParStackVars),
    DisjCodeModel = goal_info_get_code_model(DisjGoalInfo),
    (
        DisjCodeModel = model_non,
        % NondetLiveness should be a set of prog_var sets. Instead of taking
        % the union of the NondetLive sets at the ends of disjuncts, we should
        % just keep them in this set of sets.
        set_of_var.union(NondetLiveness1, NondetLiveness2, NondetLiveness3),
        goal_info_get_resume_point(GoalInfo, Resume),
        (
            Resume = resume_point(ResumePointVars, Locs),
            resume_locs_include_stack(Locs, yes)
        ->
            set_of_var.union(NondetLiveness3, ResumePointVars, NondetLiveness)
        ;
            NondetLiveness = NondetLiveness3
        )
    ;
        ( DisjCodeModel = model_det
        ; DisjCodeModel = model_semi
        ),
        NondetLiveness = NondetLiveness0
    ).

%-----------------------------------------------------------------------------%

:- pred build_live_sets_in_cases(list(case)::in, list(case)::out,
    set_of_progvar::in, alloc_data::in, T::in, T::out,
    set_of_progvar::in, set_of_progvar::out,
    set_of_progvar::in, set_of_progvar::out,
    parallel_stackvars::in, parallel_stackvars::out)
    is det <= stack_alloc_info(T).

build_live_sets_in_cases([], [], _, _,
        !StackAlloc, !Liveness, !NondetLiveness, !ParStackVars).
build_live_sets_in_cases([Case0 | Cases0], [Case | Cases],
        ResumeVars0, AllocData, !StackAlloc,
        Liveness0, Liveness, NondetLiveness0, NondetLiveness, !ParStackVars) :-
    Case0 = case(MainConsId, OtherConsIds, Goal0),
    build_live_sets_in_goal(Goal0, Goal, ResumeVars0, AllocData,
        !StackAlloc, Liveness0, Liveness, NondetLiveness0, NondetLiveness1,
        !ParStackVars),
    Case = case(MainConsId, OtherConsIds, Goal),
    build_live_sets_in_cases(Cases0, Cases, ResumeVars0, AllocData,
        !StackAlloc, Liveness0, _Liveness2, NondetLiveness0, NondetLiveness2,
        !ParStackVars),
    set_of_var.union(NondetLiveness1, NondetLiveness2, NondetLiveness).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

    % If doing typeinfo liveness calculation, any typeinfos for output
    % variables or live variables are also live. This is because if you want
    % to examine the live data, you need to know what shape the polymorphic
    % args of the variables are, so you need the typeinfos to be present
    % on the stack.
    %
    % The live variables obviously need their typeinfos live, but the output
    % variables also need their typeinfos saved (otherwise we would throw out
    % typeinfos and might need one at a continuation point just after a call).
    %
    % maybe_add_typeinfo_liveness takes a set of vars (output vars) and a set
    % of live vars and if we are doing typeinfo liveness, adds the appropriate
    % typeinfo variables to the set of variables. If not, it returns the live
    % vars unchanged.
    %
    % Make sure you get the output vars first, and the live vars second,
    % since this makes a significant difference to the output set of vars.
    %
:- pred maybe_add_typeinfo_liveness(proc_info::in, bool::in,
    set_of_progvar::in, set_of_progvar::in, set_of_progvar::out) is det.

maybe_add_typeinfo_liveness(ProcInfo, TypeInfoLiveness, OutVars, !LiveVars) :-
    (
        TypeInfoLiveness = yes,
        proc_info_get_vartypes(ProcInfo, VarTypes),
        proc_info_get_rtti_varmaps(ProcInfo, RttiVarMaps),
        get_typeinfo_vars(!.LiveVars, VarTypes, RttiVarMaps, TypeInfoVarsLive),
        get_typeinfo_vars(OutVars, VarTypes, RttiVarMaps, TypeInfoVarsOut),
        set_of_var.union(!.LiveVars, TypeInfoVarsOut, !:LiveVars),
        set_of_var.union(!.LiveVars, TypeInfoVarsLive, !:LiveVars)
    ;
        TypeInfoLiveness = no
    ).

%-----------------------------------------------------------------------------%

:- pred record_call_site(need_across_call::in, alloc_data::in,
    hlds_goal_info::in, hlds_goal_info::out, T::in, T::out) is det
    <= stack_alloc_info(T).

record_call_site(NeedAcrossCall, AllocData, !GoalInfo, !StackAlloc) :-
    goal_info_set_need_across_call(NeedAcrossCall, !GoalInfo),
    at_call_site(NeedAcrossCall, AllocData, !StackAlloc).

:- pred record_resume_site(need_in_resume::in, alloc_data::in,
    hlds_goal_info::in, hlds_goal_info::out, T::in, T::out) is det
    <= stack_alloc_info(T).

record_resume_site(NeedInResume, AllocData, !GoalInfo, !StackAlloc) :-
    goal_info_set_need_in_resume(NeedInResume, !GoalInfo),
    at_resume_site(NeedInResume, AllocData, !StackAlloc).

:- pred record_par_conj(need_in_par_conj::in, alloc_data::in,
    hlds_goal_info::in, hlds_goal_info::out, T::in, T::out) is det
    <= stack_alloc_info(T).

record_par_conj(NeedInParConj, AllocData, !GoalInfo, !StackAlloc) :-
    goal_info_set_need_in_par_conj(NeedInParConj, !GoalInfo),
    at_par_conj(NeedInParConj, AllocData, !StackAlloc).

%-----------------------------------------------------------------------------%
:- end_module ll_backend.live_vars.
%-----------------------------------------------------------------------------%
