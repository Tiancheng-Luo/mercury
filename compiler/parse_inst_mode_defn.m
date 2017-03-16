%-----------------------------------------------------------------------------e
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------e
% Copyright (C) 2008-2009, 2011 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%---------------------------------------------------------------------------%
%
% File: parse_inst_mode_defn.m.
%
% This module parses inst and mode definitions.
%
%---------------------------------------------------------------------------%

:- module parse_tree.parse_inst_mode_defn.

:- interface.

:- import_module mdbcomp.sym_name.
:- import_module parse_tree.maybe_error.
:- import_module parse_tree.parse_types.
:- import_module parse_tree.prog_data.

:- import_module list.
:- import_module term.
:- import_module varset.

    % Parse a `:- inst <InstDefn>.' declaration.
    %
:- pred parse_inst_defn_item(module_name::in, varset::in, list(term)::in,
    prog_context::in, int::in, maybe1(item_or_marker)::out) is det.

    % Parse a `:- mode <ModeDefn>.' declaration.
    %
:- pred parse_mode_defn(module_name::in, varset::in, term::in, term::in,
    prog_context::in, int::in, maybe1(item_or_marker)::out) is det.

%-----------------------------------------------------------------------------e

:- implementation.

:- import_module parse_tree.error_util.
:- import_module parse_tree.parse_inst_mode_name.
:- import_module parse_tree.parse_sym_name.
:- import_module parse_tree.parse_tree_out_term.
:- import_module parse_tree.parse_util.
:- import_module parse_tree.prog_item.

:- import_module bag.
:- import_module cord.
:- import_module maybe.
:- import_module set.

parse_inst_defn_item(ModuleName, VarSet, ArgTerms, Context, SeqNum,
        MaybeIOM) :-
    ( if ArgTerms = [InstDefnTerm] then
        % XXX Some of the tests here could be factored out.
        ( if
            InstDefnTerm =
                term.functor(term.atom("=="), [HeadTerm, BodyTerm], _)
        then
            parse_inst_defn_eqv(ModuleName, VarSet, HeadTerm, BodyTerm,
                Context, SeqNum, MaybeIOM)
        else if
            InstDefnTerm =
                term.functor(term.atom("--->"), [HeadTerm, BodyTerm], _)
        then
            BoundBodyTerm =
                term.functor(term.atom("bound"), [BodyTerm], Context),
            parse_inst_defn_eqv(ModuleName, VarSet, HeadTerm, BoundBodyTerm,
                Context, SeqNum, MaybeIOM)
        else if
            % XXX This is for `abstract inst' declarations,
            % which are not really supported.
            InstDefnTerm = term.functor(term.atom("is"), Args, _),
            Args = [HeadTerm, term.functor(term.atom("private"), [], _)]
        then
            parse_abstract_inst_defn(ModuleName, VarSet, HeadTerm,
                Context, SeqNum, MaybeIOM)
        else
            Pieces = [words("Error:"), quote("=="), words("expected in"),
                decl("inst"), words("definition."), nl],
            Spec = error_spec(severity_error, phase_term_to_parse_tree,
                [simple_msg(get_term_context(InstDefnTerm),
                    [always(Pieces)])]),
            MaybeIOM = error1([Spec])
        )
    else
        Pieces = [words("Error: an"), decl("inst"), words("declaration"),
            words("should have just one argument,"),
            words("which should be the definition of an inst."), nl],
        Spec = error_spec(severity_error, phase_term_to_parse_tree,
            [simple_msg(Context, [always(Pieces)])]),
        MaybeIOM = error1([Spec])
    ).

:- pred parse_inst_defn_eqv(module_name::in, varset::in, term::in, term::in,
    prog_context::in, int::in, maybe1(item_or_marker)::out) is det.

parse_inst_defn_eqv(ModuleName, VarSet, HeadTerm, BodyTerm, Context, SeqNum,
        MaybeIOM) :-
    ContextPieces = cord.singleton(words("In inst definition:")),
    ( if
        HeadTerm = term.functor(term.atom("for"),
            [NameTermPrime, ForTypeTerm], _)
    then
        NameTerm = NameTermPrime,
        ( if
            parse_name_and_arity_unqualified(ForTypeTerm,
                TypeSymName, TypeArity)
        then
            MaybeForType = yes(type_ctor(TypeSymName, TypeArity)),
            ForTypeSpecs = []
        else
            MaybeForType = no,
            ForTypeTermStr = describe_error_term(VarSet, ForTypeTerm),
            ForTypePieces = [words("Error: expected"),
                words("type constructor name/arity, not"),
                quote(ForTypeTermStr), suffix("."), nl],
            ForTypeSpec = error_spec(severity_error, phase_term_to_parse_tree,
                [simple_msg(get_term_context(ForTypeTerm),
                    [always(ForTypePieces)])]),
            ForTypeSpecs = [ForTypeSpec]
        )
    else
        NameTerm = HeadTerm,
        MaybeForType = no,
        ForTypeSpecs = []
    ),
    parse_implicitly_qualified_sym_name_and_args(ModuleName, NameTerm,
        VarSet, ContextPieces, MaybeSymNameAndArgs),
    (
        MaybeSymNameAndArgs = error2(SymNameAndArgSpecs),
        Specs = SymNameAndArgSpecs ++ ForTypeSpecs,
        MaybeIOM = error1(Specs)
    ;
        MaybeSymNameAndArgs = ok2(SymName, ArgTerms),

        HeadTermContext = get_term_context(HeadTerm),
        check_user_inst_name(SymName, HeadTermContext, NameSpecs),
        check_inst_mode_defn_args("inst definition", VarSet, HeadTermContext,
            ArgTerms, yes(BodyTerm), MaybeInstArgVars),
        NamedContextPieces = cord.from_list(
            [words("In the definition of the inst"),
            sym_name(SymName), suffix(":")]),
        parse_inst(no_allow_constrained_inst_var(wnciv_eqv_inst_defn_rhs),
            VarSet, NamedContextPieces, BodyTerm, MaybeInst),
        ( if
            NameSpecs = [],
            ForTypeSpecs = [],
            MaybeInstArgVars = ok1(InstArgVars),
            MaybeInst = ok1(Inst)
        then
            varset.coerce(VarSet, InstVarSet),
            InstDefn = eqv_inst(Inst),
            ItemInstDefn = item_inst_defn_info(SymName, InstArgVars,
                MaybeForType, InstDefn, InstVarSet, Context, SeqNum),
            Item = item_inst_defn(ItemInstDefn),
            MaybeIOM = ok1(iom_item(Item))
        else
            Specs = NameSpecs
                ++ ForTypeSpecs
                ++ get_any_errors1(MaybeInstArgVars)
                ++ get_any_errors1(MaybeInst),
            MaybeIOM = error1(Specs)
        )
    ).

:- pred parse_abstract_inst_defn(module_name::in, varset::in, term::in,
    prog_context::in, int::in, maybe1(item_or_marker)::out) is det.

parse_abstract_inst_defn(ModuleName, VarSet, HeadTerm, Context, SeqNum,
        MaybeIOM) :-
    ContextPieces = cord.singleton(words("In inst definition:")),
    parse_implicitly_qualified_sym_name_and_args(ModuleName, HeadTerm,
        VarSet, ContextPieces, MaybeNameAndArgs),
    (
        MaybeNameAndArgs = error2(Specs),
        MaybeIOM = error1(Specs)
    ;
        MaybeNameAndArgs = ok2(SymName, ArgTerms),

        HeadTermContext = get_term_context(HeadTerm),
        check_user_inst_name(SymName, HeadTermContext, NameSpecs),
        check_inst_mode_defn_args("inst definition", VarSet, HeadTermContext,
            ArgTerms, no, MaybeInstArgVars),

        ( if
            NameSpecs = [],
            MaybeInstArgVars = ok1(InstArgVars)
        then
            varset.coerce(VarSet, InstVarSet),
            MaybeForType = no,
            InstDefn = abstract_inst,
            ItemInstDefn = item_inst_defn_info(SymName, InstArgVars,
                MaybeForType, InstDefn, InstVarSet, Context, SeqNum),
            Item = item_inst_defn(ItemInstDefn),
            MaybeIOM = ok1(iom_item(Item))
        else
            Specs = NameSpecs ++ get_any_errors1(MaybeInstArgVars),
            MaybeIOM = error1(Specs)
        )
    ).

%---------------------------------------------------------------------------%

:- type processed_mode_body
    --->    processed_mode_body(
                sym_name,
                list(inst_var),
                mode_defn
            ).

parse_mode_defn(ModuleName, VarSet, HeadTerm, BodyTerm, Context, SeqNum,
        MaybeIOM) :-
    ContextPieces = cord.singleton(words("In mode definition:")),
    parse_implicitly_qualified_sym_name_and_args(ModuleName, HeadTerm,
        VarSet, ContextPieces, MaybeSymNameAndArgs),
    (
        MaybeSymNameAndArgs = error2(Specs),
        MaybeIOM = error1(Specs)
    ;
        MaybeSymNameAndArgs = ok2(SymName, ArgTerms),

        HeadTermContext = get_term_context(HeadTerm),
        check_user_mode_name(SymName, HeadTermContext, NameSpecs),
        check_inst_mode_defn_args("mode definition", VarSet, HeadTermContext,
            ArgTerms, yes(BodyTerm), MaybeInstArgVars),
        NamedContextPieces = cord.from_list(
            [words("In the definition of the mode"),
            sym_name(SymName), suffix(":")]),
        parse_mode(no_allow_constrained_inst_var(wnciv_mode_defn_rhs), VarSet,
            NamedContextPieces, BodyTerm, MaybeMode),
        ( if
            NameSpecs = [],
            MaybeInstArgVars = ok1(InstArgVars),
            MaybeMode = ok1(Mode)
        then
            varset.coerce(VarSet, InstVarSet),
            ModeDefn = eqv_mode(Mode),
            ItemModeDefn = item_mode_defn_info(SymName, InstArgVars,
                ModeDefn, InstVarSet, Context, SeqNum),
            Item = item_mode_defn(ItemModeDefn),
            MaybeIOM = ok1(iom_item(Item))
        else
            Specs = NameSpecs ++
                get_any_errors1(MaybeInstArgVars) ++
                get_any_errors1(MaybeMode),
            MaybeIOM = error1(Specs)
        )
    ).

%-----------------------------------------------------------------------------e

    % Check that the inst name is available to users.
    %
:- pred check_user_inst_name(sym_name::in, term.context::in,
    list(error_spec)::out) is det.

check_user_inst_name(SymName, Context, NameSpecs) :-
    Name = unqualify_name(SymName),
    ( if is_known_inst_name(Name) then
        NamePieces = [words("Error: the inst name"), quote(Name),
            words("is reserved for the Mercury implementation."), nl],
        NameSpec = error_spec(severity_error, phase_term_to_parse_tree,
            [simple_msg(Context, [always(NamePieces)])]),
        NameSpecs = [NameSpec]
    else
        NameSpecs = []
    ).

    % Check that the mode name is available to users.
    %
:- pred check_user_mode_name(sym_name::in, term.context::in,
    list(error_spec)::out) is det.

check_user_mode_name(SymName, Context, NameSpecs) :-
    % Check that the mode name is available to users.
    Name = unqualify_name(SymName),
    ( if is_known_mode_name(Name) then
        NamePieces = [words("Error: the mode name"), quote(Name),
            words("is reserved for the Mercury implementation."), nl],
        NameSpec = error_spec(severity_error, phase_term_to_parse_tree,
            [simple_msg(Context, [always(NamePieces)])]),
        NameSpecs = [NameSpec]
    else
        NameSpecs = []
    ).

:- pred check_inst_mode_defn_args(string::in, varset::in, term.context::in,
    list(term)::in, maybe(term)::in, maybe1(list(inst_var))::out) is det.

check_inst_mode_defn_args(DefnKind, VarSet, HeadTermContext,
        ArgTerms, MaybeBodyTerm, MaybeArgVars) :-
    % Check that all the head arguments are variables.
    ( if term.term_list_to_var_list(ArgTerms, ArgVars) then
        some [!Specs] (
            !:Specs = [],

            % Check that all the head variables are distinct.
            % The common cases are zero variable and one variable;
            % fail fast in those cases.
            ( if
                ArgVars = [_, _ | _], % Optimize the common case.
                bag.from_list(ArgVars, ArgVarsBag),
                bag.to_list_only_duplicates(ArgVarsBag, DupArgVars),
                DupArgVars = [_ | _]
            then
                ParamWord = choose_number(DupArgVars,
                    "parameter", "parameters"),
                IsAreWord = choose_number(DupArgVars,
                    "is", "are"),
                DupVarNames =
                    list.map(mercury_var_to_name_only(VarSet), DupArgVars),
                RepeatPieces = [words("Error: inst"), words(ParamWord)] ++
                    list_to_quoted_pieces(DupVarNames) ++
                    [words(IsAreWord), words("repeated on left hand side of"),
                    words(DefnKind), suffix("."), nl],
                RepeatSpec = error_spec(severity_error,
                    phase_term_to_parse_tree,
                    [simple_msg(HeadTermContext, [always(RepeatPieces)])]),
                !:Specs = [RepeatSpec | !.Specs]
            else
                true
            ),

            % Check that all the variables in the body occur in the head.
            % The common case is BodyVars = []; fail fast in that case.
            ( if
                MaybeBodyTerm = yes(BodyTerm),
                term.vars(BodyTerm, BodyVars),
                BodyVars = [_ | _],
                set.list_to_set(BodyVars, BodyVarsSet),
                set.list_to_set(ArgVars, ArgVarsSet),
                set.difference(BodyVarsSet, ArgVarsSet, FreeVarsSet),
                set.to_sorted_list(FreeVarsSet, FreeVars),
                FreeVars = [_ | _]
            then
                FreeVarNames =
                    list.map(mercury_var_to_name_only(VarSet), FreeVars),
                FreePieces = [words("Error: free inst"),
                    words(choose_number(FreeVars,
                        "parameter", "parameters"))] ++
                    list_to_quoted_pieces(FreeVarNames) ++
                    [words("on right hand side of"),
                    words(DefnKind), suffix("."), nl],
                FreeSpec = error_spec(severity_error,
                    phase_term_to_parse_tree,
                    [simple_msg(get_term_context(BodyTerm),
                        [always(FreePieces)])]),
                !:Specs = [FreeSpec | !.Specs]
            else
                true
            ),

            (
                !.Specs = [],
                list.map(term.coerce_var, ArgVars, InstArgVars),
                MaybeArgVars = ok1(InstArgVars)
            ;
                !.Specs = [_ | _],
                MaybeArgVars = error1(!.Specs)
            )
        )
    else
        % XXX If term_list_to_var_list returned the non-var's term
        % or context, we could use it here.
        VarPieces = [words("Error: inst parameters must be variables."), nl],
        VarSpec = error_spec(severity_error, phase_term_to_parse_tree,
            [simple_msg(HeadTermContext, [always(VarPieces)])]),
        MaybeArgVars = error1([VarSpec])
    ).

%-----------------------------------------------------------------------------e
:- end_module parse_tree.parse_inst_mode_defn.
%-----------------------------------------------------------------------------e
