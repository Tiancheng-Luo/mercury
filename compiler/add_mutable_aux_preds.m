%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% Copyright (C) 2015 The Mercury team.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%---------------------------------------------------------------------------%

:- module hlds.make_hlds.add_mutable_aux_preds.
:- interface.

:- import_module hlds.hlds_module.
:- import_module hlds.make_hlds.qual_info.
:- import_module parse_tree.error_util.

:- import_module list.

%---------------------------------------------------------------------------%

    % If the given mutable item is local to this module,
    % add the declarations of its auxiliary predicates to the HLDS.
    %
:- pred add_aux_pred_decls_for_mutable_if_local(
    sec_item(item_mutable_info)::in, module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

    % If the given mutable item is local to this module,
    % add the definitions of its auxiliary predicates to the HLDS,
    % add the (backend-specific) data structure holding the mutable's value
    % to the HLDS, and arrange for this data structure to be initialized.
    %
:- pred add_aux_pred_defns_for_mutable_if_local(
    sec_item(item_mutable_info)::in,
    module_info::in, module_info::out, qual_info::in, qual_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

:- implementation.

:- import_module backend_libs.
:- import_module backend_libs.foreign.
:- import_module hlds.error_msg_inst.
:- import_module hlds.make_hlds.add_clause.
:- import_module hlds.make_hlds.add_foreign_proc.
:- import_module hlds.make_hlds.make_hlds_error.
:- import_module libs.
:- import_module libs.globals.
:- import_module libs.options.
:- import_module mdbcomp.builtin_modules.
:- import_module mdbcomp.sym_name.
:- import_module parse_tree.builtin_lib_types.
:- import_module parse_tree.maybe_error.
:- import_module parse_tree.prog_data.
:- import_module parse_tree.prog_data_foreign.
:- import_module parse_tree.prog_foreign.
:- import_module parse_tree.prog_mode.
:- import_module parse_tree.prog_mutable.

:- import_module bool.
:- import_module map.
:- import_module require.
:- import_module string.
:- import_module varset.

%---------------------------------------------------------------------------%

add_aux_pred_decls_for_mutable_if_local(SectionItem, !ModuleInfo, !Specs) :-
    SectionItem = sec_item(SectionInfo, ItemMutable),
    SectionInfo = sec_info(ItemMercuryStatus, NeedQual),
    (
        ItemMercuryStatus = item_defined_in_this_module(ItemExport),
        check_mutable(ItemMutable, ItemExport, !.ModuleInfo, !Specs),
        item_mercury_status_to_pred_status(ItemMercuryStatus, PredStatus),
        add_aux_pred_decls_for_mutable(ItemMutable, PredStatus, NeedQual,
            !ModuleInfo, !Specs)
    ;
        ItemMercuryStatus = item_defined_in_other_module(_)
        % We don't implement the `mutable' declaration unless it is defined
        % in this module. If we did not have this check, we would duplicate
        % the definition of the global variable storing the mutable
        % in any submodules of the module that actually defined the mutable.
    ).

:- pred check_mutable(item_mutable_info::in, item_export::in, module_info::in,
    list(error_spec)::in, list(error_spec)::out) is det.

check_mutable(ItemMutable, ItemExport, ModuleInfo, !Specs) :-
    ItemMutable = item_mutable_info(MutableName,
        _OrigType, _Type, OrigInst, Inst,
        _InitTerm, _VarSetMutable, MutAttrs, Context, _SeqNum),
    (
        ( ItemExport = item_export_nowhere
        ; ItemExport = item_export_only_submodules
        )
    ;
        ItemExport = item_export_anywhere,
        error_is_exported(Context,
            [decl("mutable"), words("declaration")], !Specs)
    ),

    % XXX We don't currently support the foreign_name attribute
    % for all languages.
    module_info_get_globals(ModuleInfo, Globals),
    globals.get_target(Globals, CompilationTarget),
    (
        ( CompilationTarget = target_c,      ForeignLanguage = lang_c
        ; CompilationTarget = target_java,   ForeignLanguage = lang_java
        ; CompilationTarget = target_csharp, ForeignLanguage = lang_csharp
        ; CompilationTarget = target_erlang, ForeignLanguage = lang_erlang
        ),
        mutable_var_maybe_foreign_names(MutAttrs) = MaybeForeignNames,
        (
            MaybeForeignNames = no
        ;
            MaybeForeignNames = yes(ForeignNames),
            % Report any errors with the foreign_name attributes
            % during this pass.
            module_info_get_name(ModuleInfo, ModuleName),
            get_global_name_from_foreign_names(ModuleInfo, Context,
                ModuleName, MutableName, ForeignLanguage, ForeignNames,
                _TargetMutableName, !Specs)
        )
    ),

    % If the mutable is to be trailed, then we need to be in a trailing grade.
    TrailMutableUpdates = mutable_var_trailed(MutAttrs),
    globals.lookup_bool_option(Globals, use_trail, UseTrail),
    ( if
        TrailMutableUpdates = mutable_trailed,
        UseTrail = no
    then
        TrailPieces = [words("Error: trailed"), decl("mutable"),
            words("declaration in non-trailing grade."), nl],
        TrailMsg = simple_msg(Context, [always(TrailPieces)]),
        TrailSpec = error_spec(severity_error,
            phase_parse_tree_to_hlds, [TrailMsg]),
        !:Specs = [TrailSpec | !.Specs]
    else
        true
    ),

    % Check that the inst in the mutable declaration is a valid inst
    % for a mutable declaration.
    % It is okay to pass a dummy varset in here since any attempt
    % to use inst variables in a mutable declaration should already
    % been dealt with when the mutable declaration was parsed.
    DummyInstVarSet = varset.init,
    check_mutable_inst(ModuleInfo, Context, DummyInstVarSet, [], Inst,
        [], ExpandedInstSpecs),
    (
        ExpandedInstSpecs = []
    ;
        ExpandedInstSpecs = [_ | _],
        % We found some insts in Inst that are not allowed in mutables.
        %
        % Inst has been processed by equiv_type.m, which replaces named insts
        % with the definition of the named inst. When we check it, the error
        % messages we generate for any errors in it will lack information
        % about what nested sequence of named inst definitions the errors is
        % inside. We therefore compute the error messages on the original
        % inst as well.
        %
        % If ExpandedInstSpecs is nonempty, then UnexpandedInstSpecs should
        % be nonempty as well, but we prepare for it to be empty just in case.
        check_mutable_inst(ModuleInfo, Context, DummyInstVarSet, [], OrigInst,
            [], UnexpandedInstSpecs),
        (
            UnexpandedInstSpecs = [],
            % Printing error messages without the proper context is better than
            % not printing error messages at all, once we have discovered
            % an error.
            !:Specs = ExpandedInstSpecs ++ !.Specs
        ;
            UnexpandedInstSpecs = [_ | _],
            !:Specs = UnexpandedInstSpecs ++ !.Specs
        )
    ).

%---------------------------------------------------------------------------%

    % Add an error to !Specs for each part of the inst that isn't allowed
    % inside a mutable declaration.
    %
:- pred check_mutable_inst(module_info::in, prog_context::in,
    inst_varset::in, list(inst_id)::in, mer_inst::in,
    list(error_spec)::in, list(error_spec)::out) is det.

check_mutable_inst(ModuleInfo, Context, InstVarSet, ParentInsts, Inst,
        !Specs) :-
    (
        ( Inst = any(Uniq, _)
        ; Inst = ground(Uniq, _)
        ),
        check_mutable_inst_uniqueness(ModuleInfo, Context, InstVarSet,
            ParentInsts, Inst, Uniq, !Specs)
    ;
        Inst = bound(Uniq, _, BoundInsts),
        check_mutable_inst_uniqueness(ModuleInfo, Context, InstVarSet,
            ParentInsts, Inst, Uniq, !Specs),
        check_mutable_bound_insts(ModuleInfo, Context, InstVarSet,
            ParentInsts, BoundInsts, !Specs)
    ;
        Inst = defined_inst(InstName),
        (
            InstName = user_inst(UserInstSymName, UserInstArgs),
            list.length(UserInstArgs, UserInstArity),
            UserInstId = inst_id(UserInstSymName, UserInstArity),
            ( if
                list.member(UserInstId, ParentInsts)
            then
                true
            else if
                UserInstSymName =
                    qualified(UserInstModuleName, UserInstBaseName),
                UserInstModuleName = mercury_public_builtin_module,
                UserInstArity = 0,
                ( UserInstBaseName = "dead"
                ; UserInstBaseName = "mostly_dead"
                )
            then
                FreePieces = [words("may not appear in"),
                    decl("mutable"), words("declarations.")],
                UnqualInstName =
                    user_inst(unqualified(UserInstBaseName), UserInstArgs),
                UnqualInst = defined_inst(UnqualInstName),
                invalid_inst_in_mutable(ModuleInfo, Context, InstVarSet,
                    ParentInsts, UnqualInst, FreePieces, !Specs)
            else
                check_mutable_insts(ModuleInfo, Context, InstVarSet,
                    ParentInsts, UserInstArgs, !Specs),

                module_info_get_inst_table(ModuleInfo, InstTable),
                inst_table_get_user_insts(InstTable, UserInstTable),
                ( if map.search(UserInstTable, UserInstId, InstDefn) then
                    InstDefn = hlds_inst_defn(DefnInstVarSet, _Params,
                        InstBody, _MMTC, _Context, _Status),
                    (
                        InstBody = eqv_inst(EqvInst),
                        DefnParentInsts = [UserInstId | ParentInsts],
                        check_mutable_inst(ModuleInfo, Context, DefnInstVarSet,
                            DefnParentInsts, EqvInst, !Specs)
                    ;
                        InstBody = abstract_inst
                    )
                else
                    UndefinedPieces = [words("is not defined.")],
                    invalid_inst_in_mutable(ModuleInfo, Context, InstVarSet,
                        ParentInsts, Inst, UndefinedPieces, !Specs)
                )
            )
        ;
            ( InstName = unify_inst(_, _, _, _)
            ; InstName = merge_inst(_, _)
            ; InstName = ground_inst(_, _, _, _)
            ; InstName = any_inst(_, _, _, _)
            ; InstName = shared_inst(_)
            ; InstName = mostly_uniq_inst(_)
            ; InstName = typed_inst(_, _)
            ; InstName = typed_ground(_, _)
            ),
            unexpected($module, $pred, "non-user inst")
        )
    ;
        ( Inst = free
        ; Inst = free(_)
        ),
        FreePieces = [words("may not appear in"),
            decl("mutable"), words("declarations.")],
        invalid_inst_in_mutable(ModuleInfo, Context, InstVarSet, ParentInsts,
            Inst, FreePieces, !Specs)
    ;
        Inst = constrained_inst_vars(_, _),
        ConstrainedPieces = [words("is constrained, and thus"),
            words("may not appear in"), decl("mutable"),
            words("declarations.")],
        invalid_inst_in_mutable(ModuleInfo, Context, InstVarSet, ParentInsts,
            Inst, ConstrainedPieces, !Specs)
    ;
        Inst = abstract_inst(_, _),
        AbstractPieces = [words("is abstract, and thus"),
            words("may not appear in"), decl("mutable"),
            words("declarations.")],
        invalid_inst_in_mutable(ModuleInfo, Context, InstVarSet, ParentInsts,
            Inst, AbstractPieces, !Specs)
    ;
        Inst = inst_var(_)
        % The parser ensures that the inst in the mutable declaration does
        % not have any variables. Any variables we encounter here must be
        % a parameter from a named inst that the top level inst refers to
        % either directly or indirectly.
    ;
        Inst = not_reached,
        unexpected($module, $pred, "not_reached")
    ).

:- pred check_mutable_bound_insts(module_info::in, prog_context::in,
    inst_varset::in, list(inst_id)::in, list(bound_inst)::in,
    list(error_spec)::in, list(error_spec)::out) is det.

check_mutable_bound_insts(_ModuleInfo, _Context, _InstVarSet, _ParentInsts,
        [], !Specs).
check_mutable_bound_insts(ModuleInfo, Context, InstVarSet, ParentInsts,
        [BoundInst | BoundInsts], !Specs) :-
    BoundInst = bound_functor(_ConsId, ArgInsts),
    check_mutable_insts(ModuleInfo, Context, InstVarSet, ParentInsts,
        ArgInsts, !Specs),
    check_mutable_bound_insts(ModuleInfo, Context, InstVarSet, ParentInsts,
        BoundInsts, !Specs).

:- pred check_mutable_insts(module_info::in, prog_context::in,
    inst_varset::in, list(inst_id)::in, list(mer_inst)::in,
    list(error_spec)::in, list(error_spec)::out) is det.

check_mutable_insts(_ModuleInfo, _Context, _InstVarSet, _ParentInsts,
        [], !Specs).
check_mutable_insts(ModuleInfo, Context, InstVarSet, ParentInsts,
        [Inst | Insts], !Specs) :-
    check_mutable_inst(ModuleInfo, Context, InstVarSet, ParentInsts,
        Inst, !Specs),
    check_mutable_insts(ModuleInfo, Context, InstVarSet, ParentInsts,
        Insts, !Specs).

%---------------------%

:- pred check_mutable_inst_uniqueness(module_info::in, prog_context::in,
    inst_varset::in, list(inst_id)::in, mer_inst::in, uniqueness::in,
    list(error_spec)::in, list(error_spec)::out) is det.

check_mutable_inst_uniqueness(ModuleInfo, Context, InstVarSet, ParentInsts,
        Inst, Uniq, !Specs) :-
    (
        Uniq = shared
    ;
        (
            Uniq = unique,
            UniqStr = "unique"
        ;
            Uniq = mostly_unique,
            UniqStr = "mostly_unique"
        ;
            Uniq = clobbered,
            UniqStr = "clobbered"
        ;
            Uniq = mostly_clobbered,
            UniqStr = "mostly_clobbered"
        ),
        ( if Inst = ground(Uniq, _) then
            UniqPieces = [words("may not appear in"),
                decl("mutable"), words("declarations.")]
        else
            UniqPieces = [words("has uniqueness"), quote(UniqStr), suffix(","),
                words("which may not appear in"),
                decl("mutable"), words("declarations.")]
        ),
        invalid_inst_in_mutable(ModuleInfo, Context, InstVarSet, ParentInsts,
            Inst, UniqPieces, !Specs)
    ).

:- pred invalid_inst_in_mutable(module_info::in, prog_context::in,
    inst_varset::in, list(inst_id)::in, mer_inst::in,
    list(format_component)::in,
    list(error_spec)::in, list(error_spec)::out) is det.

invalid_inst_in_mutable(ModuleInfo, Context, InstVarSet, ParentInsts, Inst,
        ProblemPieces, !Specs) :-
    named_parents_to_pieces(ParentInsts, ParentPieces),
    InstPieces = error_msg_inst(ModuleInfo, InstVarSet,
        dont_expand_named_insts, quote_short_inst,
        [], [nl_indent_delta(1)], [nl_indent_delta(-1)], Inst),
    Pieces = [words("Error:") | ParentPieces] ++
        [words("the inst") | InstPieces] ++ ProblemPieces ++ [nl],
    Msg = simple_msg(Context, [always(Pieces)]),
    Spec = error_spec(severity_error, phase_parse_tree_to_hlds, [Msg]),
    !:Specs = [Spec | !.Specs].

:- pred named_parents_to_pieces(list(inst_id)::in,
    list(format_component)::out) is det.

named_parents_to_pieces([], []).
named_parents_to_pieces([InstId | InstIds], Pieces) :-
    named_parent_to_pieces(InstId, HeadPieces),
    named_parents_to_pieces(InstIds, TailPieces),
    Pieces = HeadPieces ++ TailPieces.

:- pred named_parent_to_pieces(inst_id::in,
    list(format_component)::out) is det.

named_parent_to_pieces(InstId, Pieces) :-
    InstId = inst_id(InstName, InstArity),
    Pieces = [words("in the expansion of the named inst"),
        sym_name_and_arity(sym_name_arity(InstName, InstArity)),
        suffix(":"), nl].

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

:- pred add_aux_pred_decls_for_mutable(item_mutable_info::in,
    pred_status::in, need_qualifier::in, module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

add_aux_pred_decls_for_mutable(ItemMutable, PredStatus, NeedQual,
        !ModuleInfo, !Specs) :-
    ItemMutable = item_mutable_info(MutableName,
        _OrigType, Type, _OrigInst, Inst,
        _InitTerm, _VarSetMutable, MutAttrs, Context, _SeqNum),
    get_mutable_target_params(!.ModuleInfo, MutAttrs, MaybeTargetParams),
    (
        MaybeTargetParams = no
    ;
        MaybeTargetParams = yes(TargetParams),
        TargetParams = mutable_target_params(_ImplLang, _Lang, _BoxPolicy,
            PreInit, LockUnlock, UnsafeAccess),
        module_info_get_name(!.ModuleInfo, ModuleName),

        % The logic of this code should match the logic of define_aux_preds.
        % Parts of this logic are also duplicated (though they shouldn't be)
        % in the parts of write_module_interface_files.m that handle mutables.

        % Create the pre-initialisation predicate,
        % if needed by the initialisation predicate.
        (
            PreInit = dont_need_pre_init_pred
        ;
            PreInit = need_pre_init_pred,
            add_mutable_pre_init_pred_decl(ModuleName, MutableName,
                PredStatus, NeedQual, Context, !ModuleInfo, !Specs)
        ),

        % Create the mutable initialisation predicate.
        add_mutable_init_pred_decl(ModuleName, MutableName,
            PredStatus, NeedQual, Context, !ModuleInfo, !Specs),

        % Create the primitive access and locking predicates, if needed.
        (
            LockUnlock = dont_need_lock_unlock_preds
        ;
            LockUnlock = need_lock_unlock_preds,
            add_mutable_lock_pred_decl(ModuleName, MutableName,
                PredStatus, NeedQual, Context, !ModuleInfo, !Specs),
            add_mutable_unlock_pred_decl(ModuleName, MutableName,
                PredStatus, NeedQual, Context, !ModuleInfo, !Specs)
        ),
        (
            UnsafeAccess = dont_need_unsafe_get_set_preds
        ;
            UnsafeAccess = need_unsafe_get_set_preds,
            add_mutable_unsafe_get_pred_decl(ModuleName, MutableName,
                Type, Inst, PredStatus, NeedQual, Context,
                !ModuleInfo, !Specs),
            add_mutable_unsafe_set_pred_decl(ModuleName, MutableName,
                Type, Inst, PredStatus, NeedQual, Context,
                !ModuleInfo, !Specs)
        ),

        IsConstant = mutable_var_constant(MutAttrs),
        AttachToIO = mutable_var_attach_to_io_state(MutAttrs),
        (
            IsConstant = mutable_constant,
            expect(unify(PreInit, dont_need_pre_init_pred),
                $module, $pred, "PreInit = need_pre_init_pred"),
            expect(unify(LockUnlock, dont_need_lock_unlock_preds),
                $module, $pred, "LockUnlock = need_lock_unlock_preds"),
            expect(unify(UnsafeAccess, dont_need_unsafe_get_set_preds),
                $module, $pred, "UnsafeAccess = need_unsafe_get_set_preds"),
            expect(unify(AttachToIO, mutable_dont_attach_to_io_state),
                $module, $pred, "AttachToIO = mutable_attach_to_io_state"),

            % We create the "get" access predicate, which is pure since
            % it always returns the same value, but we must also create
            % a secret "set" predicate for use by the initialization code.
            ConstantGetPredDecl = constant_get_pred_decl(ModuleName,
                MutableName, Type, Inst, Context),
            ConstantSetPredDecl = constant_set_pred_decl(ModuleName,
                MutableName, Type, Inst, Context),
            add_pred_decl_info_for_mutable_aux_pred(ConstantGetPredDecl,
                ModuleName, MutableName, mutable_pred_constant_get,
                PredStatus, NeedQual, !ModuleInfo, !Specs),
            add_pred_decl_info_for_mutable_aux_pred(ConstantSetPredDecl,
                ModuleName, MutableName, mutable_pred_constant_secret_set,
                PredStatus, NeedQual, !ModuleInfo, !Specs)
        ;
            IsConstant = mutable_not_constant,
            % Create the standard, non-pure access predicates. These are
            % always created for non-constant mutables, even if the
            % `attach_to_io_state' attribute has been specified.
            StdGetPredDecl = std_get_pred_decl(ModuleName, MutableName,
                Type, Inst, Context),
            StdSetPredDecl = std_set_pred_decl(ModuleName, MutableName,
                Type, Inst, Context),
            add_pred_decl_info_for_mutable_aux_pred(StdGetPredDecl,
                ModuleName, MutableName, mutable_pred_std_get,
                PredStatus, NeedQual, !ModuleInfo, !Specs),
            add_pred_decl_info_for_mutable_aux_pred(StdSetPredDecl,
                ModuleName, MutableName, mutable_pred_std_set,
                PredStatus, NeedQual, !ModuleInfo, !Specs),

            % If requested, create pure access predicates using
            % the I/O state as well.
            (
                AttachToIO = mutable_dont_attach_to_io_state
            ;
                AttachToIO = mutable_attach_to_io_state,
                IOGetPredDecl = io_get_pred_decl(ModuleName, MutableName,
                    Type, Inst, Context),
                IOSetPredDecl = io_set_pred_decl(ModuleName, MutableName,
                    Type, Inst, Context),
                add_pred_decl_info_for_mutable_aux_pred(IOGetPredDecl,
                    ModuleName, MutableName, mutable_pred_io_get,
                    PredStatus, NeedQual, !ModuleInfo, !Specs),
                add_pred_decl_info_for_mutable_aux_pred(IOSetPredDecl,
                    ModuleName, MutableName, mutable_pred_io_set,
                    PredStatus, NeedQual, !ModuleInfo, !Specs)
            )
        )
    ).

%---------------------------------------------------------------------------%

    % Add predmode declarations for the four primitive operations.
    %
:- pred add_mutable_unsafe_get_pred_decl(module_name::in, string::in,
    mer_type::in, mer_inst::in, pred_status::in, need_qualifier::in,
    prog_context::in, module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.
:- pred add_mutable_unsafe_set_pred_decl(module_name::in, string::in,
    mer_type::in, mer_inst::in, pred_status::in, need_qualifier::in,
    prog_context::in, module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.
:- pred add_mutable_lock_pred_decl(module_name::in, string::in,
    pred_status::in, need_qualifier::in, prog_context::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.
:- pred add_mutable_unlock_pred_decl(module_name::in, string::in,
    pred_status::in, need_qualifier::in, prog_context::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

add_mutable_unsafe_get_pred_decl(ModuleName, MutableName, Type, Inst,
        PredStatus, NeedQual, Context, !ModuleInfo, !Specs) :-
    PredName = mutable_unsafe_get_pred_sym_name(ModuleName, MutableName),
    ArgTypesAndModes = [type_and_mode(Type, out_mode(Inst))],
    add_mutable_aux_pred_decl(ModuleName, MutableName, mutable_pred_unsafe_get,
        PredName, ArgTypesAndModes, purity_semipure, PredStatus, NeedQual,
        Context, !ModuleInfo, !Specs).

add_mutable_unsafe_set_pred_decl(ModuleName, MutableName, Type, Inst,
        PredStatus, NeedQual, Context, !ModuleInfo, !Specs) :-
    PredName = mutable_unsafe_set_pred_sym_name(ModuleName, MutableName),
    ArgTypesAndModes = [type_and_mode(Type, in_mode(Inst))],
    add_mutable_aux_pred_decl(ModuleName, MutableName, mutable_pred_unsafe_set,
        PredName, ArgTypesAndModes, purity_impure, PredStatus, NeedQual,
        Context, !ModuleInfo, !Specs).

add_mutable_lock_pred_decl(ModuleName, MutableName, PredStatus, NeedQual,
        Context, !ModuleInfo, !Specs) :-
    PredName = mutable_lock_pred_sym_name(ModuleName, MutableName),
    ArgTypesAndModes = [],
    add_mutable_aux_pred_decl(ModuleName, MutableName, mutable_pred_lock,
        PredName, ArgTypesAndModes, purity_impure, PredStatus, NeedQual,
        Context, !ModuleInfo, !Specs).

add_mutable_unlock_pred_decl(ModuleName, MutableName, PredStatus, NeedQual,
        Context, !ModuleInfo, !Specs) :-
    PredName = mutable_unlock_pred_sym_name(ModuleName, MutableName),
    ArgTypesAndModes = [],
    add_mutable_aux_pred_decl(ModuleName, MutableName, mutable_pred_unlock,
        PredName, ArgTypesAndModes, purity_impure, PredStatus, NeedQual,
        Context, !ModuleInfo, !Specs).

    % Add a predmode declaration for the mutable initialisation predicate.
    %
:- pred add_mutable_init_pred_decl(module_name::in, string::in,
    pred_status::in, need_qualifier::in, prog_context::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

add_mutable_init_pred_decl(ModuleName, MutableName, PredStatus, NeedQual,
        Context, !ModuleInfo, !Specs) :-
    PredName = mutable_init_pred_sym_name(ModuleName, MutableName),
    ArgTypesAndModes = [],
    add_mutable_aux_pred_decl(ModuleName, MutableName, mutable_pred_pre_init,
        PredName, ArgTypesAndModes, purity_impure, PredStatus, NeedQual,
        Context, !ModuleInfo, !Specs).

    % Add a predmode declaration for the mutable pre-initialisation
    % predicate. For normal mutables, this initialises the mutex protecting
    % the mutable. For thread-local mutables, this allocates an index
    % into an array of thread-local mutable values.
    %
:- pred add_mutable_pre_init_pred_decl(module_name::in, string::in,
    pred_status::in, need_qualifier::in, prog_context::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

add_mutable_pre_init_pred_decl(ModuleName, MutableName, PredStatus, NeedQual,
        Context, !ModuleInfo, !Specs) :-
    PredName = mutable_pre_init_pred_sym_name(ModuleName, MutableName),
    ArgTypesAndModes = [],
    add_mutable_aux_pred_decl(ModuleName, MutableName, mutable_pred_pre_init,
        PredName, ArgTypesAndModes, purity_impure, PredStatus, NeedQual,
        Context, !ModuleInfo, !Specs).

%---------------------------------------------------------------------------%

:- pred add_mutable_aux_pred_decl(module_name::in, string::in,
    mutable_pred_kind::in, sym_name::in, list(type_and_mode)::in, purity::in,
    pred_status::in, need_qualifier::in, prog_context::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

add_mutable_aux_pred_decl(ModuleName, MutableName, Kind, PredName,
        ArgTypesAndModes, Purity, PredStatus, NeedQual, Context,
        !ModuleInfo, !Specs) :-
    PredOrigin = origin_mutable(ModuleName, MutableName, Kind),
    ItemNumber = -1,
    MaybeItemMercuryStatus = maybe.no,
    TypeVarSet = varset.init,
    InstVarSet = varset.init,
    ExistQVars = [],
    Constraints = constraints([], []),
    marker_list_to_markers([marker_mutable_access_pred], Markers),
    module_add_pred_or_func(PredOrigin, Context, ItemNumber,
        MaybeItemMercuryStatus, PredStatus, NeedQual,
        pf_predicate, PredName, TypeVarSet, InstVarSet, ExistQVars,
        ArgTypesAndModes, Constraints, yes(detism_det),
        Purity, Markers, _, !ModuleInfo, !Specs).

%---------------------------------------------------------------------------%

:- pred add_pred_decl_info_for_mutable_aux_pred(item_pred_decl_info::in,
    module_name::in, string::in, mutable_pred_kind::in,
    pred_status::in, need_qualifier::in, module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

add_pred_decl_info_for_mutable_aux_pred(ItemPredDecl, ModuleName, MutableName,
        Kind, PredStatus, NeedQual, !ModuleInfo, !Specs) :-
    PredOrigin = origin_mutable(ModuleName, MutableName, Kind),
    ItemNumber = -1,
    MaybeItemMercuryStatus = maybe.no,
    ItemPredDecl = item_pred_decl_info(PredName, PredOrFunc, TypesAndModes,
        WithType, WithInst, MaybeDetism, _Origin, TypeVarSet, InstVarSet,
        ExistQVars, Purity, Constraints, Context, _SeqNum),
    expect(unify(TypeVarSet, varset.init), $module, $pred,
        "TypeVarSet != varset.init"),
    expect(unify(InstVarSet, varset.init), $module, $pred,
        "InstVarSet != varset.init"),
    expect(unify(ExistQVars, []), $module, $pred, "ExistQVars != []"),
    expect(unify(PredOrFunc, pf_predicate), $module, $pred,
        "PredOrFunc != pf_predicate"),
    expect(unify(WithType, no), $module, $pred, "WithType != no"),
    expect(unify(WithInst, no), $module, $pred, "WithInst != no"),
    expect(unify(MaybeDetism, yes(detism_det)), $module, $pred,
        "MaybeDet != yes(detism_det)"),
    expect(unify(Constraints, constraints([], [])), $module, $pred,
        "Constraints != constraints([], [])"),
    marker_list_to_markers([marker_mutable_access_pred], Markers),
    module_add_pred_or_func(PredOrigin, Context, ItemNumber,
        MaybeItemMercuryStatus, PredStatus, NeedQual, PredOrFunc, PredName,
        TypeVarSet, InstVarSet, ExistQVars, TypesAndModes, Constraints,
        MaybeDetism, Purity, Markers, _, !ModuleInfo, !Specs).

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

add_aux_pred_defns_for_mutable_if_local(SectionItem,
        !ModuleInfo, !QualInfo, !Specs) :-
    SectionItem = sec_item(SectionInfo, ItemMutable),
    SectionInfo = sec_info(ItemMercuryStatus, _NeedQual),
    (
        ItemMercuryStatus = item_defined_in_this_module(_),
        item_mercury_status_to_pred_status(ItemMercuryStatus, PredStatus),
        add_aux_pred_defns_for_mutable(ItemMutable, PredStatus, !ModuleInfo,
            !QualInfo, !Specs)
    ;
        ItemMercuryStatus = item_defined_in_other_module(_)
    ).

:- pred add_aux_pred_defns_for_mutable(item_mutable_info::in, pred_status::in,
    module_info::in, module_info::out, qual_info::in, qual_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

add_aux_pred_defns_for_mutable(ItemMutable, PredStatus,
        !ModuleInfo, !QualInfo, !Specs) :-
    % The transformation here is documented in the comments at the
    % beginning of prog_mutable.m.
    ItemMutable = item_mutable_info(MutableName,
        _OrigType, Type, _OrigInst, _Inst,
        _InitTerm, _VarSetMutable, MutAttrs, Context, _SeqNum),
    get_mutable_target_params(!.ModuleInfo, MutAttrs, MaybeTargetParams),
    (
        MaybeTargetParams = no
    ;
        MaybeTargetParams = yes(TargetParams),
        TargetParams = mutable_target_params(ImplLang, Lang, _BoxPolicy,
            _PreInit, _LockUnlock, _UnsafeAccess),
        IsConstant = mutable_var_constant(MutAttrs),
        IsThreadLocal = mutable_var_thread_local(MutAttrs),

        % Work out what name to give the global in the target language.
        module_info_get_name(!.ModuleInfo, ModuleName),
        decide_mutable_target_var_name(!.ModuleInfo, MutAttrs, ModuleName,
            MutableName, Lang, Context, TargetMutableName),

        % We define the global storing the mutable now rather than earlier
        % because the target-language-specific name of the type of the global
        % depends on whether there are any foreign_type declarations for Type.
        (
            ImplLang = mutable_lang_c,
            define_global_var_c(TargetMutableName, Type, IsConstant,
                IsThreadLocal, Context, !ModuleInfo)
        ;
            ImplLang = mutable_lang_csharp,
            define_global_var_csharp(TargetMutableName, Type,
                IsThreadLocal, Context, !ModuleInfo)
        ;
            ImplLang = mutable_lang_java,
            define_global_var_java( TargetMutableName, Type,
                IsThreadLocal, Context, !ModuleInfo)
        ;
            ImplLang = mutable_lang_erlang
            % For the Erlang backend, we don't define any global variables;
            % instead, the values of thread-local mutables are stored
            % in the thread's process dictionary, and the values of
            % non-thread-local mutables are stored in the
            % ML_erlang_global_server process.
        ),
        define_aux_preds(ItemMutable, TargetParams, TargetMutableName,
            PredStatus, !ModuleInfo, !QualInfo, !Specs)
    ).

%---------------------------------------------------------------------------%
%
% Define the global holding the mutable.
%

    % Define the global variable used to hold the mutable on the C backend,
    % and if needed, the mutex controlling access to it.
    %
:- pred define_global_var_c(string::in, mer_type::in,
    mutable_constant::in, mutable_thread_local::in, prog_context::in,
    module_info::in, module_info::out) is det.

define_global_var_c(TargetMutableName, Type, IsConstant, IsThreadLocal,
        Context, !ModuleInfo) :-
    % The declaration we construct will be included in the .mh files. Since
    % these are grade independent, we need to output both the high- and
    % low-level C declarations for the global used to implement the mutable,
    % and make the choice conditional on whether MR_HIGHLEVEL_CODE is defined.
    (
        IsThreadLocal = mutable_not_thread_local,
        % The only difference between the high- and low-level C backends
        % is that in the latter, mutables are *always* boxed, whereas
        % in the former they may not be.
        HighLevelTypeName = global_foreign_type_name(bp_native_if_possible,
            lang_c, !.ModuleInfo, Type),
        LowLevelTypeName = global_foreign_type_name(bp_always_boxed,
            lang_c, !.ModuleInfo, Type),
        module_info_get_globals(!.ModuleInfo, Globals),
        globals.lookup_bool_option(Globals, highlevel_code, HighLevelCode),
        (
            HighLevelCode = no,
            TypeName = LowLevelTypeName
        ;
            HighLevelCode = yes,
            TypeName = HighLevelTypeName
        )
    ;
        IsThreadLocal = mutable_thread_local,
        % For thread-local mutables, the variable holds an index into an
        % array.
        TypeName = "MR_Unsigned",
        HighLevelTypeName = TypeName,
        LowLevelTypeName  = TypeName
    ),

    % Constant mutables do not require mutexes, as their values are never
    % updated. Thread-local mutables do not require mutexes either.
    ( if
        ( IsConstant = mutable_constant
        ; IsThreadLocal = mutable_thread_local
        )
    then
        LockDeclStrs = [],
        LockDefnStrs = []
    else
        MutexVarName = mutable_mutex_var_name(TargetMutableName),
        LockDeclStrs = [
            "#ifdef MR_THREAD_SAFE\n",
            "    extern MercuryLock ", MutexVarName, ";\n",
            "#endif\n"
        ],
        LockDefnStrs = [
            "#ifdef MR_THREAD_SAFE\n",
            "    MercuryLock ", MutexVarName, ";\n",
            "#endif\n"
        ]
    ),

    DeclBody = string.append_list([
        "#ifdef MR_HIGHLEVEL_CODE\n",
        "    extern ", HighLevelTypeName, " ", TargetMutableName, ";\n",
        "#else\n",
        "    extern ", LowLevelTypeName, " ", TargetMutableName, ";\n",
        "#endif\n" | LockDeclStrs]),
    ForeignDeclCode = foreign_decl_code(lang_c, foreign_decl_is_exported,
        floi_literal(DeclBody), Context),
    module_add_foreign_decl_code(ForeignDeclCode, !ModuleInfo),

    DefnBody = string.append_list([
        TypeName, " ", TargetMutableName, ";\n" | LockDefnStrs]),
    ForeignBodyCode = foreign_body_code(lang_c,
        floi_literal(DefnBody), Context),
    module_add_foreign_body_code(ForeignBodyCode, !ModuleInfo).

    % Define the global variable used to hold the mutable on the C# backend.
    %
:- pred define_global_var_csharp(string::in, mer_type::in,
    mutable_thread_local::in, prog_context::in,
    module_info::in, module_info::out) is det.

define_global_var_csharp(TargetMutableName, Type, IsThreadLocal, Context,
        !ModuleInfo) :-
    (
        IsThreadLocal = mutable_not_thread_local,
        ( if Type = int_type then
            TypeStr = "int"
        else
            TypeStr = "object"
        )
    ;
        IsThreadLocal = mutable_thread_local,
        TypeStr = "int"
    ),
    DefnBody = "static " ++ TypeStr ++ " " ++ TargetMutableName ++ ";\n",
    DefnForeignBodyCode =
        foreign_body_code(lang_csharp, floi_literal(DefnBody), Context),
    module_add_foreign_body_code(DefnForeignBodyCode, !ModuleInfo).

    % Define the global variable used to hold the mutable on the Java backend.
    %
:- pred define_global_var_java(string::in, mer_type::in,
    mutable_thread_local::in, prog_context::in,
    module_info::in, module_info::out) is det.

define_global_var_java(TargetMutableName, Type, IsThreadLocal, Context,
        !ModuleInfo) :-
    (
        IsThreadLocal = mutable_not_thread_local,
        % Synchronization is only required for double and long values,
        % which Mercury does not expose. We could also use the volatile
        % keyword. (Java Language Specification, 2nd Ed., 17.4).
        ( if Type = int_type then
            TypeStr = "int"
        else
            TypeStr = "java.lang.Object"
        ),
        DefnBody = "static " ++ TypeStr ++ " " ++ TargetMutableName ++ ";\n"
    ;
        IsThreadLocal = mutable_thread_local,
        ( if Type = int_type then
            TypeStr = "java.lang.Integer"
        else
            TypeStr = "java.lang.Object"
        ),
        DefnBody = string.append_list([
            "static java.lang.ThreadLocal<", TypeStr, "> ",
            TargetMutableName,
            " = new java.lang.InheritableThreadLocal<", TypeStr, ">();\n"
        ])
    ),
    DefnForeignBodyCode =
        foreign_body_code(lang_java, floi_literal(DefnBody), Context),
    module_add_foreign_body_code(DefnForeignBodyCode, !ModuleInfo).

%---------------------------------------------------------------------------%

:- pred define_aux_preds(item_mutable_info::in, mutable_target_params::in,
    string::in, pred_status::in, module_info::in, module_info::out,
    qual_info::in, qual_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

define_aux_preds(ItemMutable, TargetParams, TargetMutableName, PredStatus,
        !ModuleInfo, !QualInfo, !Specs) :-
    TargetParams = mutable_target_params(ImplLang, Lang, BoxPolicy,
        PreInit, LockUnlock, UnsafeAccess),

    % Set up the default attributes for the foreign_procs used for the
    % access predicates.
    Attrs0 = default_attributes(Lang),
    (
        ImplLang = mutable_lang_c,
        set_box_policy(BoxPolicy, Attrs0, Attrs1),
        set_may_call_mercury(proc_will_not_call_mercury, Attrs1, Attrs)
    ;
        ( ImplLang = mutable_lang_csharp
        ; ImplLang = mutable_lang_java
        ),
        % The mutable variable name is not module-qualified, and so
        % it must not be exported to `.opt' files. We could add the
        % qualification but it would be better to move the mutable code
        % generation into the backends first.
        set_may_duplicate(yes(proc_may_not_duplicate), Attrs0, Attrs)
    ;
        ImplLang = mutable_lang_erlang,
        Attrs = Attrs0
    ),

    % The logic of this code should match the logic of
    % add_mutable_aux_pred_decls, though there is one difference of order:
    % we define the init predicate last, though it is declared second
    % just after the pre_init predicate. This is because the definition
    % needs information we gather during the definition of the other
    % predicates.

    (
        PreInit = dont_need_pre_init_pred,
        MaybeCallPreInitExpr = no
    ;
        PreInit = need_pre_init_pred,
        define_pre_init_pred(ItemMutable, TargetParams, TargetMutableName,
            Attrs, CallPreInitExpr, PredStatus,
            !ModuleInfo, !QualInfo, !Specs),
        MaybeCallPreInitExpr = yes(CallPreInitExpr)
    ),
    (
        LockUnlock = dont_need_lock_unlock_preds,
        MaybeLockUnlockExprs = no
    ;
        LockUnlock = need_lock_unlock_preds,
        define_lock_unlock_preds(ItemMutable, TargetParams, TargetMutableName,
            Attrs, LockUnlockExprs, PredStatus,
            !ModuleInfo, !QualInfo, !Specs),
        MaybeLockUnlockExprs = yes(LockUnlockExprs)
    ),
    (
        UnsafeAccess = dont_need_unsafe_get_set_preds,
        MaybeUnsafeGetSetExprs = no
    ;
        UnsafeAccess = need_unsafe_get_set_preds,
        define_unsafe_get_set_preds(ItemMutable, TargetParams,
            TargetMutableName, Attrs, UnsafeGetSetExprs, PredStatus,
            !ModuleInfo, !QualInfo, !Specs),
        MaybeUnsafeGetSetExprs = yes(UnsafeGetSetExprs)
    ),

    % We do this after defining (a) the lock and unlock predicates and
    % (b) the unsafe get and set predicates, since they give us
    % (a) MaybeLockUnlockExprs and (b) MaybeUnsafeGetSetExprs respectively.
    define_main_get_set_preds(ItemMutable, TargetParams, TargetMutableName,
        Attrs, MaybeLockUnlockExprs, MaybeUnsafeGetSetExprs, InitSetPredName,
        PredStatus, !ModuleInfo, !QualInfo, !Specs),

    % We do this after defining (a) the preinit predicate and (b) the main
    % get and set predicates, since they give us (a) MaybeCallPreInitExpr
    % and (b) InitSetPredName respectively.
    define_init_pred(ItemMutable, MaybeCallPreInitExpr, InitSetPredName,
        Lang, PredStatus, !ModuleInfo, !QualInfo, !Specs).

    % Define the pre_init predicates, if needed by the init predicate.
    %
:- pred define_pre_init_pred(item_mutable_info::in, mutable_target_params::in,
    string::in, pragma_foreign_proc_attributes::in, goal::out,
    pred_status::in, module_info::in, module_info::out,
    qual_info::in, qual_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

define_pre_init_pred(ItemMutable, TargetParams, TargetMutableName, Attrs,
        CallPreInitExpr, PredStatus, !ModuleInfo, !QualInfo, !Specs) :-
    module_info_get_name(!.ModuleInfo, ModuleName),
    ItemMutable = item_mutable_info(MutableName,
        _OrigType, _Type, _OrigInst, _Inst,
        _InitTerm, _VarSetMutable, MutAttrs, Context, _SeqNum),
    IsConstant = mutable_var_constant(MutAttrs),
    IsThreadLocal = mutable_var_thread_local(MutAttrs),
    TargetParams = mutable_target_params(ImplLang, _Lang, _BoxPolicy,
        _PreInit, _LockUnlock, _UnsafeAccess),

    expect(unify(IsConstant, mutable_not_constant), $module, $pred,
        "need_pre_init_pred, but IsConstant = mutable_constant"),
    PreInitPredName = mutable_pre_init_pred_sym_name(ModuleName, MutableName),

    (
        ImplLang = mutable_lang_c,
        (
            IsThreadLocal = mutable_not_thread_local,
            PreInitCode = string.append_list([
                "#ifdef MR_THREAD_SAFE\n",
                "   pthread_mutex_init(&",
                        mutable_mutex_var_name(TargetMutableName),
                        ", MR_MUTEX_ATTR);\n",
                "#endif\n"
            ])
        ;
            IsThreadLocal = mutable_thread_local,
            PreInitCode = TargetMutableName ++
                " = MR_new_thread_local_mutable_index();\n"
        )
    ;
        ImplLang = mutable_lang_csharp,
        PreInitCode = TargetMutableName ++
            " = runtime.ThreadLocalMutables.new_index();\n"
    ;
        ImplLang = mutable_lang_java,
        unexpected($module, $pred, "preinit for java")
    ;
        ImplLang = mutable_lang_erlang,
        unexpected($module, $pred, "preinit for erlang")
    ),
    PreInitFCInfo = pragma_info_foreign_proc(Attrs,
        PreInitPredName,
        pf_predicate,
        [],             % Args
        varset.init,    % ProgVarSet
        varset.init,    % InstVarSet
        fp_impl_ordinary(PreInitCode, yes(Context))
    ),
    add_pragma_foreign_proc(PreInitFCInfo, PredStatus, Context, no,
        !ModuleInfo, !Specs),

    CallPreInitExpr = call_expr(Context, PreInitPredName, [], purity_impure).

    % Define the lock and unlock predicates, if needed.
    %
:- pred define_lock_unlock_preds(item_mutable_info::in,
    mutable_target_params::in, string::in, pragma_foreign_proc_attributes::in,
    {goal, goal}::out, pred_status::in,
    module_info::in, module_info::out, qual_info::in, qual_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

define_lock_unlock_preds(ItemMutable, TargetParams, TargetMutableName, Attrs,
        LockUnlockExprs, PredStatus, !ModuleInfo, !QualInfo, !Specs) :-
    module_info_get_name(!.ModuleInfo, ModuleName),
    ItemMutable = item_mutable_info(MutableName,
        _OrigType, _Type, _OrigInst, _Inst,
        _InitTerm, _VarSetMutable, MutAttrs, Context, _SeqNum),
    IsConstant = mutable_var_constant(MutAttrs),
    IsThreadLocal = mutable_var_thread_local(MutAttrs),
    TargetParams = mutable_target_params(ImplLang, _Lang, _BoxPolicy,
        _PreInit, _LockUnlock, _UnsafeAccess),
    expect(unify(IsConstant, mutable_not_constant), $module, $pred,
        "need_lock_unlock_preds, but IsConstant = mutable_constant"),

    (
        ImplLang = mutable_lang_c,
        set_thread_safe(proc_thread_safe, Attrs, LockAndUnlockAttrs),
        MutableMutexVarName = mutable_mutex_var_name(TargetMutableName),

        (
            IsThreadLocal = mutable_not_thread_local,
            % XXX The second argument of both calls should be the name of
            % the Mercury predicate, with chars escaped as appropriate.
            LockForeignProcBody = string.append_list([
                "#ifdef MR_THREAD_SAFE\n",
                "  MR_LOCK(&" ++ MutableMutexVarName ++ ",
                    \"" ++ MutableMutexVarName ++ "\");\n" ++
                "#endif\n"
            ]),
            UnlockForeignProcBody = string.append_list([
                "#ifdef MR_THREAD_SAFE\n",
                "  MR_UNLOCK(&" ++ MutableMutexVarName ++ ",
                    \"" ++ MutableMutexVarName ++ "\");\n" ++
                "#endif\n"
            ])
        ;
            IsThreadLocal = mutable_thread_local,
            LockForeignProcBody = "",
            UnlockForeignProcBody = ""
        ),
        LockPredName =
            mutable_lock_pred_sym_name(ModuleName, MutableName),
        UnlockPredName =
            mutable_unlock_pred_sym_name(ModuleName, MutableName),
        LockFCInfo = pragma_info_foreign_proc(LockAndUnlockAttrs,
            LockPredName,
            pf_predicate,
            [],
            varset.init,    % ProgVarSet
            varset.init,    % InstVarSet
            fp_impl_ordinary(LockForeignProcBody, yes(Context))
        ),
        UnlockFCInfo = pragma_info_foreign_proc(LockAndUnlockAttrs,
            UnlockPredName,
            pf_predicate,
            [],
            varset.init,    % ProgVarSet
            varset.init,    % InstVarSet
            fp_impl_ordinary(UnlockForeignProcBody, yes(Context))
        ),
        add_pragma_foreign_proc(LockFCInfo, PredStatus, Context, no,
            !ModuleInfo, !Specs),
        add_pragma_foreign_proc(UnlockFCInfo, PredStatus, Context, no,
            !ModuleInfo, !Specs),
        CallLockExpr0 =
            call_expr(Context, LockPredName, [], purity_impure),
        CallUnlockExpr0 =
            call_expr(Context, UnlockPredName, [], purity_impure),
        LockUnlockExprs = {CallLockExpr0, CallUnlockExpr0}
    ;
        ImplLang = mutable_lang_csharp,
        unexpected($module, $pred, "lock_unlock for csharp")
    ;
        ImplLang = mutable_lang_java,
        unexpected($module, $pred, "lock_unlock for java")
    ;
        ImplLang = mutable_lang_erlang,
        unexpected($module, $pred, "lock_unlock for erlang")
    ).

    % Define the unsafe get and set predicates, if needed.
    %
:- pred define_unsafe_get_set_preds(item_mutable_info::in,
    mutable_target_params::in, string::in, pragma_foreign_proc_attributes::in,
    {goal, goal}::out, pred_status::in,
    module_info::in, module_info::out, qual_info::in, qual_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

define_unsafe_get_set_preds(ItemMutable, TargetParams, TargetMutableName,
        Attrs, UnsafeGetSetExprs, PredStatus,
        !ModuleInfo, !QualInfo, !Specs) :-
    module_info_get_name(!.ModuleInfo, ModuleName),
    ItemMutable = item_mutable_info(MutableName,
        _OrigType, Type, _OrigInst, Inst,
        _InitTerm, _VarSetMutable, MutAttrs, Context, _SeqNum),
    IsConstant = mutable_var_constant(MutAttrs),
    IsThreadLocal = mutable_var_thread_local(MutAttrs),
    TargetParams = mutable_target_params(ImplLang, Lang, BoxPolicy,
        _PreInit, _LockUnlock, _UnsafeAccess),
    expect(unify(IsConstant, mutable_not_constant), $module, $pred,
        "need_unsafe_get_set_preds, but IsConstant = mutable_constant"),
    varset.new_named_var("X", X, varset.init, VarSetOnlyX),

    set_thread_safe(proc_thread_safe, Attrs, ThreadSafeAttrs),
    set_purity(purity_semipure, ThreadSafeAttrs, UnsafeGetAttrs),
    UnsafeSetAttrs = ThreadSafeAttrs,   % defaults to purity_impure

    TrailedMutable = mutable_var_trailed(MutAttrs),
    (
        ImplLang = mutable_lang_c,
        (
            TrailedMutable = mutable_untrailed,
            TrailCode = ""
        ;
            TrailedMutable = mutable_trailed,
            % We have already checked that we are in a
            % trailing grade.
            TrailCode = "MR_trail_current_value(&" ++
                TargetMutableName ++ ");\n"
        ),
        (
            IsThreadLocal = mutable_not_thread_local,
            UnsafeGetCode = "X = " ++ TargetMutableName ++ ";\n",
            UnsafeSetCode = TargetMutableName ++ " = X;\n"
        ;
            IsThreadLocal = mutable_thread_local,
            TypeName = global_foreign_type_name(BoxPolicy, Lang,
                !.ModuleInfo, Type),
            UnsafeGetCode = "MR_get_thread_local_mutable(" ++
                TypeName ++ ", X, " ++ TargetMutableName ++ ");\n",
            UnsafeSetCode = "MR_set_thread_local_mutable(" ++
                TypeName ++ ", X, " ++ TargetMutableName ++ ");\n"
        )
    ;
        ImplLang = mutable_lang_csharp,
        % We generate an error for trailed mutables in pass 2, but we
        % still continue on to pass 3 even in the presence of such errors.
        TrailCode = "",
        (
            IsThreadLocal = mutable_not_thread_local,
            UnsafeGetCode = "\tX = " ++ TargetMutableName ++ ";\n",
            UnsafeSetCode = "\t" ++ TargetMutableName ++ " = X;\n"
        ;
            IsThreadLocal = mutable_thread_local,
            ( if Type = int_type then
                Cast = "(int) "
            else
                Cast = ""
            ),
            UnsafeGetCode = "\tX = " ++ Cast ++
                "runtime.ThreadLocalMutables.get(" ++
                TargetMutableName ++ ");\n",
            UnsafeSetCode = "\truntime.ThreadLocalMutables.set(" ++
                TargetMutableName ++ ", X);\n"
        )
    ;
        ImplLang = mutable_lang_java,
        % We generate an error for trailed mutables in pass 2, but we
        % still continue on to pass 3 even in the presence of such errors.
        TrailCode = "",
        (
            IsThreadLocal = mutable_not_thread_local,
            UnsafeGetCode = "\tX = " ++ TargetMutableName ++ ";\n",
            UnsafeSetCode = "\t" ++ TargetMutableName ++ " = X;\n"
        ;
            IsThreadLocal = mutable_thread_local,
            UnsafeGetCode = "\tX = " ++ TargetMutableName ++ ".get();\n",
            UnsafeSetCode = "\t" ++ TargetMutableName ++ ".set(X);\n"
        )
    ;
        ImplLang = mutable_lang_erlang,
        unexpected($module, $pred, "unsafe_get_set for erlang")
    ),

    UnsafeGetPredName =
        mutable_unsafe_get_pred_sym_name(ModuleName, MutableName),
    UnsafeSetPredName =
        mutable_unsafe_set_pred_sym_name(ModuleName, MutableName),
    UnsafeGetFCInfo = pragma_info_foreign_proc(UnsafeGetAttrs,
        UnsafeGetPredName,
        pf_predicate,
        [pragma_var(X, "X", out_mode(Inst), BoxPolicy)],
        VarSetOnlyX,    % ProgVarSet
        varset.init,    % InstVarSet
        fp_impl_ordinary(UnsafeGetCode, yes(Context))
    ),
    UnsafeSetFCInfo = pragma_info_foreign_proc(UnsafeSetAttrs,
        UnsafeSetPredName,
        pf_predicate,
        [pragma_var(X, "X", in_mode(Inst), BoxPolicy)],
        VarSetOnlyX,    % ProgVarSet
        varset.init,    % InstVarSet
        fp_impl_ordinary(TrailCode ++ UnsafeSetCode, yes(Context))
    ),
    add_pragma_foreign_proc(UnsafeGetFCInfo, PredStatus, Context, no,
        !ModuleInfo, !Specs),
    add_pragma_foreign_proc(UnsafeSetFCInfo, PredStatus, Context, no,
        !ModuleInfo, !Specs),

    CallUnsafeGetExpr0 = call_expr(Context, UnsafeGetPredName,
        [variable(X, Context)], purity_semipure),
    CallUnsafeSetExpr0 = call_expr(Context, UnsafeSetPredName,
        [variable(X, Context)], purity_impure),
    UnsafeGetSetExprs = {CallUnsafeGetExpr0, CallUnsafeSetExpr0}.

    % Define one of the following sets of predicates:
    %
    % 1: the standard get predicate and the constant set predicate; or
    % 2: the standard get and set predicates; or
    % 3: the standard get and set predicates and the io get and set predicate.
    %
    % We define set 1 if the mutable is constant, and one of 2 or 3
    % if it is not, depending on whether the mutable is attached to
    % the I/O state.
    %
    % We do this *after* creating the lock and unlock predicates
    % and the unsafe get and set predicates, since they give us
    % MaybeLockUnlockExprs and MaybeUnsafeGetSetExprs.
    %
:- pred define_main_get_set_preds(item_mutable_info::in,
    mutable_target_params::in, string::in, pragma_foreign_proc_attributes::in,
    maybe({goal, goal})::in, maybe({goal, goal})::in,
    sym_name::out, pred_status::in,
    module_info::in, module_info::out, qual_info::in, qual_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

define_main_get_set_preds(ItemMutable, TargetParams, TargetMutableName, Attrs,
        MaybeLockUnlockExprs, MaybeUnsafeGetSetExprs, InitSetPredName,
        PredStatus, !ModuleInfo, !QualInfo, !Specs) :-
    module_info_get_name(!.ModuleInfo, ModuleName),
    ItemMutable = item_mutable_info(MutableName,
        _OrigType, _Type, _OrigInst, Inst,
        _InitTerm, _VarSetMutable, MutAttrs, Context, _SeqNum),
    IsConstant = mutable_var_constant(MutAttrs),
    IsThreadLocal = mutable_var_thread_local(MutAttrs),
    AttachToIO = mutable_var_attach_to_io_state(MutAttrs),
    TargetParams = mutable_target_params(ImplLang, _Lang, BoxPolicy,
        _PreInit, _LockUnlock, _UnsafeAccess),
    varset.new_named_var("X", X, varset.init, VarSetOnlyX),

    (
        IsConstant = mutable_constant,
        ConstantGetPredName =
            mutable_get_pred_sym_name(ModuleName, MutableName),
        ConstantSecretSetPredName =
            mutable_secret_set_pred_sym_name(ModuleName, MutableName),
        InitSetPredName = ConstantSecretSetPredName,

        set_purity(purity_pure, Attrs, ConstantGetAttrs0),
        set_thread_safe(proc_thread_safe, ConstantGetAttrs0, ConstantGetAttrs),
        ConstantSetAttrs = Attrs,
        (
            ( ImplLang = mutable_lang_c
            ; ImplLang = mutable_lang_csharp
            ; ImplLang = mutable_lang_java
            ),
            ConstantGetCode = "X = " ++ TargetMutableName ++ ";\n",
            ConstantSetCode = TargetMutableName ++ " = X;\n"
        ;
            ImplLang = mutable_lang_erlang,
            % These Erlang fragments duplicate those for non-thread-local
            % non-constant mutables below.
            ConstantGetCode =
                string.append_list([
                    "'ML_erlang_global_server' ! {get_mutable, ",
                        TargetMutableName, ", self()},\n",
                    "receive\n",
                    "   {get_mutable_ack, Value} ->\n",
                    "       X = Value\n",
                    "end\n"
                ]),
            ConstantSetCode =
                "'ML_erlang_global_server' ! {set_mutable, " ++
                    TargetMutableName ++ ", X}"
        ),
        ConstantGetFCInfo = pragma_info_foreign_proc(ConstantGetAttrs,
            ConstantGetPredName,
            pf_predicate,
            [pragma_var(X, "X", out_mode(Inst), BoxPolicy)],
            VarSetOnlyX,    % ProgVarSet
            varset.init,    % InstVarSet
            fp_impl_ordinary(ConstantGetCode, yes(Context))
        ),
        % NOTE: we don't need to trail the set action, since it is
        % executed only once at initialization time.
        ConstantSetFCInfo = pragma_info_foreign_proc(ConstantSetAttrs,
            ConstantSecretSetPredName,
            pf_predicate,
            [pragma_var(X, "X", in_mode(Inst), BoxPolicy)],
            VarSetOnlyX,    % ProgVarSet
            varset.init,    % InstVarSet
            fp_impl_ordinary(ConstantSetCode, yes(Context))
        ),
        add_pragma_foreign_proc(ConstantGetFCInfo, PredStatus, Context, no,
            !ModuleInfo, !Specs),
        add_pragma_foreign_proc(ConstantSetFCInfo, PredStatus, Context, no,
            !ModuleInfo, !Specs),

        expect(unify(AttachToIO, mutable_dont_attach_to_io_state),
            $module, $pred, "AttachToIO = mutable_attach_to_io_state")
    ;
        IsConstant = mutable_not_constant,
        StdGetPredName = mutable_get_pred_sym_name(ModuleName, MutableName),
        StdSetPredName = mutable_set_pred_sym_name(ModuleName, MutableName),
        InitSetPredName = StdSetPredName,
        (
            ( ImplLang = mutable_lang_c
            ; ImplLang = mutable_lang_csharp
            ; ImplLang = mutable_lang_java
            ),
            (
                MaybeUnsafeGetSetExprs =
                    yes({CallUnsafeGetExpr, CallUnsafeSetExpr})
            ;
                MaybeUnsafeGetSetExprs = no,
                unexpected($module, $pred,
                    "mutable_not_constant but MaybeUnsafeGetSetExprs = no")
            ),
            (
                MaybeLockUnlockExprs = no,
                ImpureGetExpr = CallUnsafeGetExpr,
                ImpureSetExpr = CallUnsafeSetExpr
            ;
                MaybeLockUnlockExprs = yes({CallLockExpr, CallUnlockExpr}),
                ImpureGetExpr = conj_expr(Context, CallLockExpr,
                    conj_expr(Context, CallUnsafeGetExpr, CallUnlockExpr)),
                ImpureSetExpr = conj_expr(Context, CallLockExpr,
                    conj_expr(Context, CallUnsafeSetExpr, CallUnlockExpr))
            ),

            StdPredArgs = [variable(X, Context)],
            StdGetPredExpr = promise_purity_expr(Context, purity_semipure,
                ImpureGetExpr),
            StdSetPredExpr = ImpureSetExpr,
            module_add_clause(VarSetOnlyX, pf_predicate, StdGetPredName,
                StdPredArgs, ok1(StdGetPredExpr), PredStatus, Context, no,
                goal_type_none, !ModuleInfo, !QualInfo, !Specs),
            module_add_clause(VarSetOnlyX, pf_predicate, StdSetPredName,
                StdPredArgs, ok1(StdSetPredExpr), PredStatus, Context, no,
                goal_type_none, !ModuleInfo, !QualInfo, !Specs)
        ;
            ImplLang = mutable_lang_erlang,
            % NOTE We don't call the unsafe get/set predicates, since
            % we don't declare/define them. We don't need them, because
            % in Erlang we can do their job here directly, since (a)
            % we don't need explicit locking, as the message passing
            % system takes care of that, and (b) we don't need to trail
            % the setting of the mutable, even if the mutable is nominally
            % trailed, because the Erlang backend does not implement trailing.
            set_thread_safe(proc_thread_safe, Attrs, ThreadSafeAttrs),
            set_purity(purity_semipure, ThreadSafeAttrs, ErlangGetAttrs),
            set_purity(purity_impure, ThreadSafeAttrs, ErlangSetAttrs),
            (
                IsThreadLocal = mutable_thread_local,
                StdGetCode = "X = get({'MR_thread_local_mutable', " ++
                    TargetMutableName ++ "})",
                StdSetCode = "put({'MR_thread_local_mutable', " ++
                    TargetMutableName ++ "}, X)"
            ;
                IsThreadLocal = mutable_not_thread_local,
                % These Erlang fragments duplicate those for
                % constant mutables above.
                StdGetCode =
                    string.append_list([
                        "'ML_erlang_global_server' ! {get_mutable, ",
                            TargetMutableName, ", self()},\n",
                        "receive\n",
                        "   {get_mutable_ack, Value} ->\n",
                        "       X = Value\n",
                        "end\n"
                    ]),
                StdSetCode =
                    "'ML_erlang_global_server' ! {set_mutable, " ++
                        TargetMutableName ++ ", X}"
            ),
            StdGetFCInfo = pragma_info_foreign_proc(ErlangGetAttrs,
                StdGetPredName,
                pf_predicate,
                [pragma_var(X, "X", out_mode(Inst), BoxPolicy)],
                VarSetOnlyX,    % ProgVarSet
                varset.init,    % InstVarSet
                fp_impl_ordinary(StdGetCode, yes(Context))
            ),
            StdSetFCInfo = pragma_info_foreign_proc(ErlangSetAttrs,
                StdSetPredName,
                pf_predicate,
                [pragma_var(X, "X", in_mode(Inst), BoxPolicy)],
                VarSetOnlyX,    % ProgVarSet
                varset.init,    % InstVarSet
                fp_impl_ordinary(StdSetCode, yes(Context))
            ),
            add_pragma_foreign_proc(StdGetFCInfo, PredStatus, Context, no,
                !ModuleInfo, !Specs),
            add_pragma_foreign_proc(StdSetFCInfo, PredStatus, Context, no,
                !ModuleInfo, !Specs),

            ImpureGetExpr = call_expr(Context, StdGetPredName,
                [variable(X, Context)], purity_semipure),
            ImpureSetExpr = call_expr(Context, StdSetPredName,
                [variable(X, Context)], purity_impure)
        ),
        (
            AttachToIO = mutable_dont_attach_to_io_state
        ;
            AttachToIO = mutable_attach_to_io_state,
            some [!VarSet] (
                !:VarSet = VarSetOnlyX,
                varset.new_named_var("IO0", IO0, !VarSet),
                varset.new_named_var("IO", IO, !VarSet),
                VarSetXandIOs = !.VarSet
            ),
            IOGetPredName = StdGetPredName,
            IOSetPredName = StdSetPredName,
            IOPredArgs = [variable(X, Context),
                variable(IO0, Context), variable(IO, Context)],

            % It is important to have CopyIOExpr *inside* the promise_pure
            % scope for the set predicate. If it were outside, then the
            % scope would not bind any variables, and since it is promised
            % pure, the compiler would be allowed to delete it. The problem
            % does not arise for the get predicate, since ImpureGetExpr
            % binds X.
            CopyIOExpr = unify_expr(Context,
                variable(IO0, Context), variable(IO, Context),
                purity_impure),
            IOGetPredExpr = conj_expr(Context, ImpureGetExpr, CopyIOExpr),
            IOSetPredExpr = conj_expr(Context, ImpureSetExpr, CopyIOExpr),
            PureIOGetPredExpr =
                promise_purity_expr(Context, purity_pure, IOGetPredExpr),
            PureIOSetPredExpr =
                promise_purity_expr(Context, purity_pure, IOSetPredExpr),

            module_add_clause(VarSetXandIOs, pf_predicate, IOGetPredName,
                IOPredArgs, ok1(PureIOGetPredExpr), PredStatus, Context, no,
                goal_type_none, !ModuleInfo, !QualInfo, !Specs),
            module_add_clause(VarSetXandIOs, pf_predicate, IOSetPredName,
                IOPredArgs, ok1(PureIOSetPredExpr), PredStatus, Context, no,
                goal_type_none, !ModuleInfo, !QualInfo, !Specs)
        )
    ).

    % Define the init predicate, and arrange for it to be called
    % at initialization time.
    %
:- pred define_init_pred(item_mutable_info::in, maybe(goal)::in,
    sym_name::in, foreign_language::in, pred_status::in,
    module_info::in, module_info::out, qual_info::in, qual_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

define_init_pred(ItemMutable, MaybeCallPreInitExpr, InitSetPredName,
        Lang, PredStatus, !ModuleInfo, !QualInfo, !Specs) :-
    module_info_get_name(!.ModuleInfo, ModuleName),
    ItemMutable = item_mutable_info(MutableName,
        _OrigType, _Type, _OrigInst, _Inst,
        InitTerm, VarSetMutable, _MutAttrs, Context, _SeqNum),
    varset.new_named_var("X", X, VarSetMutable, VarSetMutableX),
    VarX = variable(X, Context),

    UnifyExpr = unify_expr(Context, VarX, InitTerm, purity_impure),
    CallSetExpr = call_expr(Context, InitSetPredName, [VarX], purity_impure),
    UnifyCallSetExpr = conj_expr(Context, UnifyExpr, CallSetExpr),
    (
        MaybeCallPreInitExpr = no,
        InitPredExpr = UnifyCallSetExpr
    ;
        MaybeCallPreInitExpr = yes(CallPreInitExpr),
        InitPredExpr = conj_expr(Context, CallPreInitExpr, UnifyCallSetExpr)
    ),
    InitPredName = mutable_init_pred_sym_name(ModuleName, MutableName),
    % See the comments for parse_mutable_decl for the reason why we _must_ pass
    % VarSetMutableX here.
    module_add_clause(VarSetMutableX, pf_predicate, InitPredName, [],
        ok1(InitPredExpr), PredStatus, Context, no, goal_type_none,
        !ModuleInfo, !QualInfo, !Specs),

    InitPredArity = 0,
    add_initialise_for_mutable(InitPredName, InitPredArity, Context,
        Lang, !ModuleInfo, !Specs).

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

:- pred add_initialise_for_mutable(sym_name::in, arity::in,
    prog_context::in, foreign_language::in, module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

add_initialise_for_mutable(SymName, Arity, Context, Lang,
        !ModuleInfo, !Specs) :-
    % The compiler introduces initialise declarations that call impure
    % predicates as part of the source-to-source transformation for mutable
    % variables. These predicates *must* be impure in order to prevent the
    % compiler optimizing them away.
    module_info_new_user_init_pred(SymName, Arity, CName, !ModuleInfo),
    PredNameModesPF = pred_name_modes_pf(SymName, [], pf_predicate),
    FPEInfo = pragma_info_foreign_proc_export(Lang, PredNameModesPF, CName),
    Attrs = item_compiler_attributes(do_allow_export, is_mutable),
    Origin = item_origin_compiler(Attrs),
    add_pragma_foreign_proc_export(Origin, FPEInfo, Context,
        !ModuleInfo, !Specs).

%---------------------------------------------------------------------------%

    % Decide what the name of the underlying global used to implement the
    % mutable should be. If there is a foreign_name attribute then use that
    % otherwise construct one based on the Mercury name for the mutable.
    %
:- pred decide_mutable_target_var_name(module_info::in,
    mutable_var_attributes::in, module_name::in, string::in,
    foreign_language::in, prog_context::in, string::out) is det.

decide_mutable_target_var_name(ModuleInfo, MutAttrs, ModuleName, MutableName,
        ForeignLanguage, Context, TargetMutableName) :-
    mutable_var_maybe_foreign_names(MutAttrs) = MaybeForeignNames,
    (
        MaybeForeignNames = no,
        % This works for Erlang as well.
        TargetMutableName = mutable_c_var_name(ModuleName, MutableName)
    ;
        MaybeForeignNames = yes(ForeignNames),
        % We have already any errors during pass 2, so ignore them here.
        get_global_name_from_foreign_names(ModuleInfo, Context,
            ModuleName, MutableName, ForeignLanguage, ForeignNames,
            TargetMutableName, [], _Specs)
    ).

    % Check to see if there is a valid foreign_name attribute for this backend.
    % If so, use it as the name of the global variable in the target code,
    % otherwise take the Mercury name for the mutable and mangle it into
    % an appropriate variable name.
    %
 :- pred get_global_name_from_foreign_names(module_info::in,
    prog_context::in, module_name::in, string::in, foreign_language::in,
    list(foreign_name)::in, string::out,
    list(error_spec)::in, list(error_spec)::out) is det.

get_global_name_from_foreign_names(ModuleInfo, Context,
        ModuleName, MutableName, ForeignLanguage, ForeignNames,
        TargetMutableName, !Specs) :-
    get_matching_foreign_names(ForeignNames, ForeignLanguage,
        TargetMutableNames),
    (
        TargetMutableNames = [],
        % This works for Erlang as well.
        TargetMutableName = mutable_c_var_name(ModuleName, MutableName)
    ;
        TargetMutableNames = [foreign_name(_, TargetMutableName)]
        % XXX We should really check that this is a valid identifier
        % in the target language here.
    ;
        TargetMutableNames = [_, _ | _],
        module_info_get_globals(ModuleInfo, Globals),
        globals.get_target(Globals, CompilationTarget),
        Pieces = [words("Error: multiple foreign_name attributes"),
            words("specified for the"),
            fixed(compilation_target_string(CompilationTarget)),
            words("backend."), nl],
        Msg = simple_msg(Context, [always(Pieces)]),
        Spec = error_spec(severity_error, phase_parse_tree_to_hlds, [Msg]),
        !:Specs = [Spec | !.Specs],

        % This works for Erlang as well.
        TargetMutableName = mutable_c_var_name(ModuleName, MutableName)
    ).

:- pred get_matching_foreign_names(list(foreign_name)::in,
    foreign_language::in, list(foreign_name)::out) is det.

get_matching_foreign_names([], _TargetForeignLanguage, []).
get_matching_foreign_names([ForeignName | ForeignNames], TargetForeignLanguage,
        MatchingForeignNames) :-
    get_matching_foreign_names(ForeignNames, TargetForeignLanguage,
        TailMatchingForeignNames),
    ForeignName = foreign_name(ForeignLanguage, _),
    ( if ForeignLanguage = TargetForeignLanguage then
        MatchingForeignNames = [ForeignName | TailMatchingForeignNames]
    else
        MatchingForeignNames = TailMatchingForeignNames
    ).

    % The first argument global_foreign_type_name says whether the mutable
    % should always be boxed or not. The only difference between the high- and
    % low-level C backends is that in the latter mutables are *always* boxed,
    % whereas in the former they may not be. The other backends that support
    % mutables are all native_if_possible.
    % XXX is that true for erlang?
    %
:- func global_foreign_type_name(box_policy, foreign_language, module_info,
    mer_type) = string.

global_foreign_type_name(bp_always_boxed, _, _, _) = "MR_Word".
global_foreign_type_name(bp_native_if_possible, Lang, ModuleInfo, Type) =
    mercury_exported_type_to_string(ModuleInfo, Lang, Type).

%---------------------------------------------------------------------------%

:- type mutable_impl_lang
    --->    mutable_lang_c
    ;       mutable_lang_csharp
    ;       mutable_lang_java
    ;       mutable_lang_erlang.

:- type need_pre_init_pred
    --->    dont_need_pre_init_pred
    ;       need_pre_init_pred.

:- type need_lock_unlock_preds
    --->    dont_need_lock_unlock_preds
    ;       need_lock_unlock_preds.

:- type need_unsafe_get_set_preds
    --->    dont_need_unsafe_get_set_preds
    ;       need_unsafe_get_set_preds.

:- type mutable_target_params
    --->    mutable_target_params(
                mutable_impl_lang,
                foreign_language,
                box_policy,
                need_pre_init_pred,
                need_lock_unlock_preds,
                need_unsafe_get_set_preds
            ).

    % This predicate decides which auxiliary predicates we need
    % to implement a mutable. The rest of this module just implements
    % the decisions made here, which are recorded in the mutable_target_params.
    %
:- pred get_mutable_target_params(module_info::in, mutable_var_attributes::in,
    maybe(mutable_target_params)::out) is det.

get_mutable_target_params(ModuleInfo, MutAttrs, MaybeTargetParams) :-
    % The set of predicates we need depends on the compilation target,
    % since we use different implementations of mutables on different backends,
    % and on the properties of the mutable itself.
    module_info_get_globals(ModuleInfo, Globals),
    globals.get_target(Globals, CompilationTarget),
    (
        (
            CompilationTarget = target_c,
            ImplLang = mutable_lang_c,
            Lang = lang_c,
            PreInit0 = need_pre_init_pred,
            LockUnlock0 = need_lock_unlock_preds,
            UnsafeAccess0 = need_unsafe_get_set_preds,
            globals.lookup_bool_option(Globals, highlevel_code, HighLevelCode),
            (
                HighLevelCode = no,
                BoxPolicy = bp_always_boxed
            ;
                HighLevelCode = yes,
                BoxPolicy = bp_native_if_possible
            )
        ;
            CompilationTarget = target_csharp,
            ImplLang = mutable_lang_csharp,
            Lang = lang_csharp,
            IsThreadLocal = mutable_var_thread_local(MutAttrs),
            (
                IsThreadLocal = mutable_thread_local,
                PreInit0 = need_pre_init_pred
            ;
                IsThreadLocal = mutable_not_thread_local,
                PreInit0 = dont_need_pre_init_pred
            ),
            LockUnlock0 = dont_need_lock_unlock_preds,
            UnsafeAccess0 = need_unsafe_get_set_preds,
            BoxPolicy = bp_native_if_possible
        ;
            CompilationTarget = target_java,
            ImplLang = mutable_lang_java,
            Lang = lang_java,
            PreInit0 = dont_need_pre_init_pred,
            LockUnlock0 = dont_need_lock_unlock_preds,
            UnsafeAccess0 = need_unsafe_get_set_preds,
            BoxPolicy = bp_native_if_possible
        ;
            CompilationTarget = target_erlang,
            ImplLang = mutable_lang_erlang,
            Lang = lang_erlang,
            PreInit0 = dont_need_pre_init_pred,
            LockUnlock0 = dont_need_lock_unlock_preds,
            UnsafeAccess0 = dont_need_unsafe_get_set_preds,
            BoxPolicy = bp_native_if_possible
        ),
        IsConstant = mutable_var_constant(MutAttrs),
        (
            IsConstant = mutable_not_constant,
            PreInit = PreInit0,
            LockUnlock = LockUnlock0,
            UnsafeAccess = UnsafeAccess0
        ;
            IsConstant = mutable_constant,
            PreInit = dont_need_pre_init_pred,
            LockUnlock = dont_need_lock_unlock_preds,
            UnsafeAccess = dont_need_unsafe_get_set_preds
        ),
        TargetParams = mutable_target_params(ImplLang, Lang, BoxPolicy,
            PreInit, LockUnlock, UnsafeAccess),
        MaybeTargetParams = yes(TargetParams)
    ).

%---------------------------------------------------------------------------%
:- end_module hlds.make_hlds.add_mutable_aux_preds.
%---------------------------------------------------------------------------%
