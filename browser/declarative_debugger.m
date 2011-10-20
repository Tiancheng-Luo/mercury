%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 1999-2007, 2011 The University of Melbourne.
% This file may only be copied under the terms of the GNU Library General
% Public License - see the file COPYING.LIB in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: declarative_debugger.m.
% Author: Mark Brown.
%
% This module has two main purposes:
%   - to define the interface between the front and back ends of
%     a Mercury declarative debugger, and
%   - to implement a front end.
%
% The interface is defined by a procedure that can be called from
% the back end to perform diagnosis, and a typeclass which represents
% a declarative view of execution used by the front end.
%
% The front end implemented in this module analyses the EDT it is
% passed to diagnose a bug.
%
% Because Mercury modules are able to be compiled with different levels
% of tracing, the trace sequences generated by the back end, and passed
% to the front end as "annotated traces", can include or exclude certain
% types of events.  This front end is able to cope with some variation in
% the trace events produced, but there are some basic requirements on
% trace sequences which the back end must meet:
%
%   1) if there are any events from a certain class (e.g. interface
%      events, negation events, disj events) then we require all events
%      of that class;
%
%   2) if there are any disj events, we require all negation events
%      and if-then-else events.
%
%   3) the sub-term dependency tracking algorithm requires the proc
%      representation and all the internal events for any call through
%      which it must track a sub-term.  Child interface events however
%      may be omitted (as long as each CALL which is present has all its
%      corresponding REDOs, EXIT, FAIL or EXCP event(s) and vica versa).
%
% The backend will only build a portion of the annotated trace at a time
% (down to a specified depth limit).  The front end can request that more
% of the annotated trace be built so it can be analysed.  The front end can
% either request that the subtree rooted at a particular node whose children
% haven't been materialized be built (down to a certain depth limit), or that
% nodes above the topmost materialized node be materialized.  In the first case
% the require_subtree response is sent to the backend and in the latter case
% the require_supertree response is sent to the backend.  We use the term
% "supertree" to mean a tree which strictly contains the currently materialized
% portion of the annotated trace, although the backend will not materialize
% nodes which already exist in the current annotated trace when materializing
% a supertree.
%
%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- module mdb.declarative_debugger.
:- interface.

:- import_module mdb.browser_info.
:- import_module mdb.declarative_analyser.
:- import_module mdb.declarative_execution.
:- import_module mdb.declarative_tree.
:- import_module mdb.help.
:- import_module mdb.io_action.
:- import_module mdb.term_rep.
:- import_module mdbcomp.program_representation.

:- import_module io.
:- import_module list.
:- import_module maybe.
:- import_module unit.

%-----------------------------------------------------------------------------%

    % This type represents the possible truth values for nodes
    % in the EDT.
    %
:- type decl_truth
    --->    truth_correct
    ;       truth_erroneous
    ;       truth_inadmissible.

    % This type represents the possible responses to being
    % asked to confirm that a node is a bug.
    %
:- type decl_confirmation
    --->    confirm_bug
    ;       overrule_bug
    ;       abort_diagnosis.

    % This type represents the bugs which can be diagnosed.
    % The parameter of the constructor is the type of EDT nodes.
    %
:- type decl_bug
    --->    e_bug(decl_e_bug)
            % An EDT whose root node is incorrect,
            % but whose children are all correct.

    ;       i_bug(decl_i_bug).
            % An EDT whose root node is incorrect, and which has no incorrect
            % children but at least one inadmissible one.

:- type decl_e_bug
    --->    incorrect_contour(
                init_decl_atom, % The head of the clause, in its
                                % inital state of instantiation.
                final_decl_atom,% The head of the clause, in its
                                % final state of instantiation.
                decl_contour,   % The path taken through the body.
                event_number    % The exit event.
            )
    ;       partially_uncovered_atom(
                init_decl_atom, % The called atom, in its initial state.
                event_number    % The fail event.
            )
    ;       unhandled_exception(
                init_decl_atom, % The called atom, in its initial state.
                decl_exception, % The exception thrown.
                event_number    % The excp event.
            ).

:- type decl_i_bug
    --->    inadmissible_call(
                init_decl_atom, % The parent atom, in its initial state.
                decl_position,  % The location of the call in the parent body.
                init_decl_atom, % The inadmissible child, in its initial state.
                event_number    % The call event.
            ).

:- type decl_contour == list(final_decl_atom).

    % XXX not yet implemented.
    %
:- type decl_position == unit.

    % Values of the following two types represent questions from the
    % analyser to the oracle about some aspect of program behaviour,
    % and responses from the oracle, respectively.  In both cases the
    % type parameter is for the type of EDT nodes -- each question and
    % answer keeps a reference to the node which generated it, so that
    % the analyser is able to figure out what to do when the answer
    % arrives back from the oracle.
    %
:- type decl_question(T)
    --->    wrong_answer(T, init_decl_atom, final_decl_atom)
            % The node is a suspected wrong answer. The first argument
            % is the EDT node the question came from. The second argument
            % is the atom in its final state of instantiatedness (i.e.
            % at the EXIT event).

    ;       missing_answer(T, init_decl_atom, list(final_decl_atom))
            % The node is a suspected missing answer. The first argument
            % is the EDT node the question came from. The second argument
            % is the atom in its initial state of instantiatedness (i.e.
            % at the CALL event), and the third argument is the list
            % of solutions.

    ;       unexpected_exception(T, init_decl_atom, decl_exception).
            % The node is a possibly unexpected exception. The first argument
            % is the EDT node the question came from. The second argument
            % is the atom in its initial state of instantiation, and the third
            % argument is the exception thrown.

:- type decl_answer(T)
    --->    truth_value(T, decl_truth)
            % The oracle knows the truth value of this node.

    ;       suspicious_subterm(T, arg_pos, term_path, how_track_subterm,
                should_assert_invalid)
            % The oracle does not say anything about the truth value,
            % but is suspicious of the subterm at the given term_path
            % and arg_pos.

    ;       ignore(T)
            % This node should be ignored. It cannot contain a bug
            % but its children may or may not contain a bug.

    ;       skip(T).
            % The oracle has deferred answering this question.

    % Answers that are known by the oracle without having to consult the
    % user, such as answers stored in the knowledge base or answers about
    % trusted predicates.  mdb.declarative_oracle.answer_known/3 returns
    % answers of this subtype.
    %
:- inst known_answer
    --->    truth_value(ground, ground)
    ;       ignore(ground).

    % The evidence that a certain node is a bug.  This consists of the
    % smallest set of questions whose answers are sufficient to
    % diagnose that bug.
    %
:- type decl_evidence(T) == list(decl_question(T)).

    % Extract the EDT node from a question.
    %
:- func get_decl_question_node(decl_question(T)) = T.

    % Get the atom the question relates to.
    %
:- func get_decl_question_atom(decl_question(_)) = trace_atom.

:- type some_decl_atom
    --->    init(init_decl_atom)
    ;       final(final_decl_atom).

:- type init_decl_atom
    --->    init_decl_atom(
                init_atom           :: trace_atom
            ).

:- type final_decl_atom
    --->    final_decl_atom(
                final_atom          :: trace_atom,
                final_io_actions    :: maybe(io_action_range)
            ).

:- type decl_exception == term_rep.

    % The diagnoser eventually responds with a value of this type
    % after it is called.
    %
:- type diagnoser_response(R)
    --->    bug_found(event_number)
            % There was a bug found and confirmed. The event number
            % is for a call port (inadmissible call), an exit port
            % (incorrect contour), a fail port (partially uncovered atom),
            % or an exception port (unhandled exception).

    ;       symptom_found(event_number)
            % There was another symptom of incorrect behaviour found;
            % this symptom will be closer, in a sense, to the location of
            % a bug.

    ;       no_bug_found
            % There was no symptom found, or the diagnoser aborted
            % before finding a bug.

    ;       require_subtree(
                % The analyser requires the back end to reproduce part
                % of the annotated trace, with a greater depth bound.

                % The event number and sequence number are for the final event
                % required (the first event required is the call event with
                % the same sequence number).
                require_subtree_final_event         :: event_number,
                require_subtree_seqno               :: sequence_number,

                % The node preceding the call node. This is needed so the
                % root of the new tree has the correct preceding node.
                require_subtree_call_preceding_node :: R,

                % The maximum depth to build the new subtree to.
                require_subtree_max_depth           :: int
            )

    ;       require_supertree(event_number, sequence_number).
            % The analyser requires events before and after the current set
            % of materialized events to be generated. The given event should be
            % the topmost final event of the currently materialized portion
            % of the EDT.

:- type diagnoser_state(R).

    % diagnoser_state_init(InputStream, OutputStream, Browser,
    %   HelpSystem, Diagnoser):
    %
    % Initialise a new diagnoser with the given properties.
    %
:- pred diagnoser_state_init(io.input_stream::in,
    io.output_stream::in, browser_info.browser_persistent_state::in,
    help.system::in, diagnoser_state(R)::out) is det.

:- pred diagnosis(S::in, analysis_type(edt_node(R))::in,
    diagnoser_response(R)::out,
    diagnoser_state(R)::in, diagnoser_state(R)::out,
    browser_info.browser_persistent_state::in,
    browser_info.browser_persistent_state::out,
    io::di, io::uo) is cc_multi <= annotated_trace(S, R).

:- pred unravel_decl_atom(some_decl_atom::in, trace_atom::out,
    maybe(io_action_range)::out) is det.

%-----------------------------------------------------------------------------%

    % The diagnoser generates exceptions of the following type.
    %
:- type diagnoser_exception
    --->    internal_error(
                string,         % predicate/function name
                string          % error message
            )
    ;       io_error(
                string,         % predicate/function name
                string          % error message
            )
    ;       unimplemented_feature(
                string          % feature that is NYI
            ).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module mdb.declarative_edt.
:- import_module mdb.declarative_oracle.
:- import_module mdb.util.
:- import_module mdbcomp.prim_data.
:- import_module mdbcomp.rtti_access.

:- import_module bool.
:- import_module exception.
:- import_module int.
:- import_module string.
:- import_module univ.

%-----------------------------------------------------------------------------%

unravel_decl_atom(DeclAtom, TraceAtom, MaybeIoActions) :-
    (
        DeclAtom = init(init_decl_atom(TraceAtom)),
        MaybeIoActions = no
    ;
        DeclAtom = final(final_decl_atom(TraceAtom, MaybeIoActions))
    ).

get_decl_question_node(wrong_answer(Node, _, _)) = Node.
get_decl_question_node(missing_answer(Node, _, _)) = Node.
get_decl_question_node(unexpected_exception(Node, _, _)) = Node.

get_decl_question_atom(wrong_answer(_, _, final_decl_atom(Atom, _))) = Atom.
get_decl_question_atom(missing_answer(_, init_decl_atom(Atom), _)) = Atom.
get_decl_question_atom(unexpected_exception(_, init_decl_atom(Atom), _)) =
    Atom.

%-----------------------------------------------------------------------------%

:- type diagnoser_state(R)
    --->    diagnoser(
                analyser_state          :: analyser_state(edt_node(R)),
                oracle_state            :: oracle_state,

                warn_if_searching_supertree :: bool,
                    % This field keeps track of whether we should warn the
                    % user when a supertree is requested.
                    % We issue a warning when there have been no interactions
                    % with the user and a supertree has been requested.
                    % This can happen when all the nodes under the starting
                    % node are trusted.  This behaviour can be confusing, so
                    % we print a message to explain what is going on.

                previous_diagnoser      :: maybe(diagnoser_state(R))
                    % The diagnoser state before the previous oracle answer
                    % (if the oracle has given any answers yet).
            ).

diagnoser_state_init(InStr, OutStr, Browser, HelpSystem, Diagnoser) :-
    analyser_state_init(Analyser),
    oracle_state_init(InStr, OutStr, Browser, HelpSystem, Oracle),
    Diagnoser = diagnoser(Analyser, Oracle, yes, no).

:- pred push_diagnoser(diagnoser_state(R)::in, diagnoser_state(R)::out) is det.

push_diagnoser(!Diagnoser) :-
    !Diagnoser ^ previous_diagnoser := yes(!.Diagnoser).

:- pred pop_diagnoser(diagnoser_state(R)::in, diagnoser_state(R)::out)
    is semidet.

pop_diagnoser(!Diagnoser) :-
    LatestOracle = !.Diagnoser ^ oracle_state,
    !.Diagnoser ^ previous_diagnoser = yes(!:Diagnoser),
    LastPushedOracle = !.Diagnoser ^ oracle_state,
    update_revised_knowledge_base(LastPushedOracle, LatestOracle, Oracle),
    !Diagnoser ^ oracle_state := Oracle.

diagnosis(Store, AnalysisType, Response, !Diagnoser, !Browser, !IO) :-
    mdb.declarative_oracle.set_browser_state(!.Browser, !.Diagnoser ^
        oracle_state, Oracle),
    !Diagnoser ^ oracle_state := Oracle,
    try_io(diagnosis_2(Store, AnalysisType, !.Diagnoser), Result, !IO),
    (
        Result = succeeded({Response, !:Diagnoser})
    ;
        Result = exception(UnivException),
        ( univ_to_type(UnivException, DiagnoserException) ->
            handle_diagnoser_exception(DiagnoserException, Response,
                !Diagnoser, !IO)
        ;
            rethrow(Result)
        )
    ),
    !:Browser = mdb.declarative_oracle.get_browser_state(
        !.Diagnoser ^ oracle_state).

:- pred diagnosis_2(S::in, analysis_type(edt_node(R))::in,
    diagnoser_state(R)::in,
    {diagnoser_response(R), diagnoser_state(R)}::out,
    io::di, io::uo) is cc_multi <= annotated_trace(S, R).

diagnosis_2(Store, AnalysisType, Diagnoser0, {Response, Diagnoser}, !IO) :-
    Analyser0 = Diagnoser0 ^ analyser_state,
    start_or_resume_analysis(wrap(Store), Diagnoser0 ^ oracle_state,
        AnalysisType, AnalyserResponse, Analyser0, Analyser),
    Diagnoser1 = Diagnoser0 ^ analyser_state := Analyser,
    debug_analyser_state(Analyser, MaybeOrigin),
    handle_analyser_response(Store, AnalyserResponse, MaybeOrigin,
        Response, Diagnoser1, Diagnoser, !IO).

:- pred handle_analyser_response(S::in, analyser_response(edt_node(R))::in,
    maybe(subterm_origin(edt_node(R)))::in, diagnoser_response(R)::out,
    diagnoser_state(R)::in, diagnoser_state(R)::out,
    io::di, io::uo) is cc_multi <= annotated_trace(S, R).

handle_analyser_response(Store, AnalyserResponse, MaybeOrigin,
        DiagnoserResponse, !Diagnoser, !IO) :-
    (
        AnalyserResponse = analyser_response_no_suspects,
        DiagnoserResponse = no_bug_found,
        io.write_string("No bug found.\n", !IO)
    ;
        AnalyserResponse = analyser_response_bug_found(Bug, Evidence),
        confirm_bug(Store, Bug, Evidence, DiagnoserResponse, !Diagnoser, !IO)
    ;
        AnalyserResponse = analyser_response_oracle_question(Question),
        Oracle0 = !.Diagnoser ^ oracle_state,
        debug_origin(Flag, !IO),
        (
            MaybeOrigin = yes(Origin),
            Flag > 0
        ->
            io.write_string("Origin: ", !IO),
            write_origin(wrap(Store), Origin, !IO),
            io.nl(!IO)
        ;
            true
        ),
        query_oracle(Question, OracleResponse, FromUser, Oracle0, Oracle, !IO),
        (
            FromUser = yes,
            !Diagnoser ^ warn_if_searching_supertree := no,
            (
                oracle_response_undoable(OracleResponse)
            ->
                push_diagnoser(!Diagnoser)
            ;
                true
            )
        ;
            FromUser = no
        ),
        !Diagnoser ^ oracle_state := Oracle,
        handle_oracle_response(Store, OracleResponse, DiagnoserResponse,
            !Diagnoser, !IO)
    ;
        AnalyserResponse = analyser_response_require_explicit_subtree(Node),
        edt_subtree_details(Store, Node, Event, Seqno, CallPreceding),
        ( trace_implicit_tree_info(wrap(Store), Node, ImplicitTreeInfo) ->
            ImplicitTreeInfo = implicit_tree_info(IdealDepth)
        ;
            throw(internal_error("handle_analyser_response",
                "subtree requested for node which is not an implicit root"))
        ),
        DiagnoserResponse = require_subtree(Event, Seqno, CallPreceding,
            IdealDepth)
    ;
        AnalyserResponse = analyser_response_require_explicit_supertree(Node),
        edt_subtree_details(Store, Node, Event, Seqno, _),
        ( !.Diagnoser ^ warn_if_searching_supertree = no,
            DiagnoserResponse = require_supertree(Event, Seqno)
        ; !.Diagnoser ^ warn_if_searching_supertree = yes,
            Out = get_user_output_stream(!.Diagnoser ^ oracle_state),
            io.write_string(Out, "All descendent calls are trusted.\n" ++
                "Shall I continue searching in ancestor calls?\n", !IO),
            read_search_supertree_response(!.Diagnoser, Response, !IO),
            ( Response = yes,
                DiagnoserResponse = require_supertree(Event, Seqno)
            ; Response = no,
                io.write_string(Out, "Diagnosis aborted.\n", !IO),
                DiagnoserResponse = no_bug_found
            ),
            % We only want to issue the warning once, so set the flag to no.
            !Diagnoser ^ warn_if_searching_supertree := no
        )
    ;
        AnalyserResponse = analyser_response_revise(Question),
        Oracle0 = !.Diagnoser ^ oracle_state,
        revise_oracle(Question, Oracle0, Oracle),
        !Diagnoser ^ oracle_state := Oracle,
        handle_analyser_response(Store,
            analyser_response_oracle_question(Question), no, DiagnoserResponse,
            !Diagnoser, !IO)
    ).

:- pred read_search_supertree_response(diagnoser_state(R)::in,
    bool::out, io::di, io::uo) is det.

read_search_supertree_response(Diagnoser, Response, !IO) :-
    In = get_user_input_stream(Diagnoser ^ oracle_state),
    Out = get_user_output_stream(Diagnoser ^ oracle_state),
    Prompt = "> ",
    util.trace_getline(Prompt, Result, In, Out, !IO),
    ( Result = ok(Line),
        UpperLine = string.to_upper(Line),
        ( (UpperLine = "YES" ; UpperLine = "Y") ->
            Response = yes
        ; (UpperLine = "NO" ; UpperLine = "N") ->
            Response = no
        ;
            io.write_string(Out, "Please answer yes or no.\n", !IO),
            read_search_supertree_response(Diagnoser, Response, !IO)
        )
    ; Result = error(ErrNo),
        io.write_string(Out, "Error reading input: " ++
            io.error_message(ErrNo) ++ ". Aborting.\n", !IO),
        Response = no
    ; Result = eof,
        io.write_string(Out, "Unexpected EOF. Aborting.\n", !IO),
        Response = no
    ).

:- pred handle_oracle_response(S::in, oracle_response(edt_node(R))::in,
    diagnoser_response(R)::out, diagnoser_state(R)::in,
    diagnoser_state(R)::out, io::di, io::uo) is cc_multi
    <= annotated_trace(S, R).

handle_oracle_response(Store, OracleResponse, DiagnoserResponse, !Diagnoser,
        !IO) :-
    (
        OracleResponse = oracle_response_answer(Answer),
        Analyser0 = !.Diagnoser ^ analyser_state,
        continue_analysis(wrap(Store), !.Diagnoser ^ oracle_state, Answer,
            AnalyserResponse, Analyser0, Analyser),
        !Diagnoser ^ analyser_state := Analyser,
        debug_analyser_state(Analyser, MaybeOrigin),
        handle_analyser_response(Store, AnalyserResponse, MaybeOrigin,
            DiagnoserResponse, !Diagnoser, !IO)
    ;
        OracleResponse = oracle_response_show_info(OutStream),
        Analyser = !.Diagnoser ^ analyser_state,
        show_info(wrap(Store), OutStream, Analyser, !IO),
        ( reask_last_question(wrap(Store), Analyser, AnalyserResponse0) ->
            AnalyserResponse = AnalyserResponse0
        ;
            throw(internal_error("handle_oracle_response",
                "no last question when got show_info request"))
        ),
        debug_analyser_state(Analyser, MaybeOrigin),
        handle_analyser_response(Store, AnalyserResponse, MaybeOrigin,
            DiagnoserResponse, !Diagnoser, !IO)
    ;
        OracleResponse = oracle_response_change_search(Mode),
        Analyser0 = !.Diagnoser ^ analyser_state,
        Oracle = !.Diagnoser ^ oracle_state,
        change_search_mode(wrap(Store), Oracle, Mode, Analyser0, Analyser,
            AnalyserResponse),
        !Diagnoser ^ analyser_state := Analyser,
        debug_analyser_state(Analyser, MaybeOrigin),
        handle_analyser_response(Store, AnalyserResponse, MaybeOrigin,
            DiagnoserResponse, !Diagnoser, !IO)
    ;
        OracleResponse = oracle_response_undo,
        ( pop_diagnoser(!.Diagnoser, PoppedDiagnoser) ->
            !:Diagnoser = PoppedDiagnoser
        ;
            OutStream = mdb.declarative_oracle.get_user_output_stream(
                !.Diagnoser ^ oracle_state),
            io.write_string(OutStream, "Undo stack empty.\n", !IO)
        ),
        (
            reask_last_question(wrap(Store), !.Diagnoser ^ analyser_state,
                AnalyserResponse0)
        ->
            AnalyserResponse = AnalyserResponse0
        ;
            throw(internal_error("handle_oracle_response",
                "no last question when got undo request"))
        ),
        debug_analyser_state(!.Diagnoser ^ analyser_state, MaybeOrigin),
        handle_analyser_response(Store, AnalyserResponse, MaybeOrigin,
            DiagnoserResponse, !Diagnoser, !IO)
    ;
        OracleResponse = oracle_response_exit_diagnosis(Node),
        edt_subtree_details(Store, Node, Event, _, _),
        DiagnoserResponse = symptom_found(Event)
    ;
        OracleResponse = oracle_response_abort_diagnosis,
        DiagnoserResponse = no_bug_found,
        io.write_string("Diagnosis aborted.\n", !IO)
    ).

:- pred confirm_bug(S::in, decl_bug::in, decl_evidence(T)::in,
    diagnoser_response(R)::out, diagnoser_state(R)::in,
    diagnoser_state(R)::out, io::di, io::uo) is cc_multi
    <= annotated_trace(S, R).

confirm_bug(Store, Bug, Evidence, Response, !Diagnoser, !IO) :-
    Oracle0 = !.Diagnoser ^ oracle_state,
    oracle_confirm_bug(Bug, Evidence, Confirmation, Oracle0, Oracle, !IO),
    !Diagnoser ^ oracle_state := Oracle,
    (
        Confirmation = confirm_bug,
        decl_bug_get_event_number(Bug, Event),
        Response = bug_found(Event)
    ;
        Confirmation = overrule_bug,
        overrule_bug(Store, Response, !Diagnoser, !IO)
    ;
        Confirmation = abort_diagnosis,
        Response = no_bug_found
    ).

:- pred overrule_bug(S::in, diagnoser_response(R)::out, diagnoser_state(R)::in,
    diagnoser_state(R)::out, io::di, io::uo) is cc_multi
    <= annotated_trace(S, R).

overrule_bug(Store, Response, Diagnoser0, Diagnoser, !IO) :-
    Analyser0 = Diagnoser0 ^ analyser_state,
    revise_analysis(wrap(Store), AnalyserResponse, Analyser0, Analyser),
    Diagnoser1 = Diagnoser0 ^ analyser_state := Analyser,
    debug_analyser_state(Analyser, MaybeOrigin),
    handle_analyser_response(Store, AnalyserResponse, MaybeOrigin,
        Response, Diagnoser1, Diagnoser, !IO).

%-----------------------------------------------------------------------------%

    % Export a monomorphic version of diagnosis_state_init/4, to
    % make it easier to call from C code.
    %
:- pred diagnoser_state_init_store(io.input_stream::in, io.output_stream::in,
    browser_info.browser_persistent_state::in, help.system::in,
    diagnoser_state(trace_node_id)::out) is det.

:- pragma foreign_export("C", diagnoser_state_init_store(in, in, in, in, out),
    "MR_DD_decl_diagnosis_state_init").

diagnoser_state_init_store(InStr, OutStr, Browser, HelpSystem, Diagnoser) :-
    diagnoser_state_init(InStr, OutStr, Browser, HelpSystem, Diagnoser).

    % This is called when the user starts a new declarative
    % debugging session with the dd command (and the --resume option
    % wasn't given).
    %
:- pred diagnoser_session_init(diagnoser_state(trace_node_id)::in,
    diagnoser_state(trace_node_id)::out) is det.

diagnoser_session_init(!Diagnoser) :-
    !Diagnoser ^ warn_if_searching_supertree := yes.

:- pragma foreign_export("C", diagnoser_session_init(in, out),
    "MR_DD_decl_session_init").

    % Set the testing flag of the user_state in the given diagnoser.
    %
:- pred set_diagnoser_testing_flag(bool::in,
    diagnoser_state(trace_node_id)::in,
    diagnoser_state(trace_node_id)::out) is det.

:- pragma foreign_export("C", set_diagnoser_testing_flag(in, in, out),
    "MR_DD_decl_set_diagnoser_testing_flag").

set_diagnoser_testing_flag(Testing, !Diagnoser) :-
    Oracle0 = !.Diagnoser ^ oracle_state,
    set_oracle_testing_flag(Testing, Oracle0, Oracle),
    !Diagnoser ^ oracle_state := Oracle.

:- pred set_fallback_search_mode(trace_node_store::in,
    mdb.declarative_analyser.search_mode::in,
    diagnoser_state(trace_node_id)::in,
    diagnoser_state(trace_node_id)::out) is det.

:- pragma foreign_export("C",
    mdb.declarative_debugger.set_fallback_search_mode(in, in, in, out),
    "MR_DD_decl_set_fallback_search_mode").

set_fallback_search_mode(Store, SearchMode, !Diagnoser) :-
    Analyser0 = !.Diagnoser ^ analyser_state,
    mdb.declarative_analyser.set_fallback_search_mode(wrap(Store),
        SearchMode, Analyser0, Analyser),
    !Diagnoser ^ analyser_state := Analyser.

:- pred reset_knowledge_base(
    diagnoser_state(trace_node_id)::in,
    diagnoser_state(trace_node_id)::out) is det.

:- pragma foreign_export("C",
    mdb.declarative_debugger.reset_knowledge_base(in, out),
    "MR_DD_decl_reset_knowledge_base").

reset_knowledge_base(!Diagnoser) :-
    Oracle0 = !.Diagnoser ^ oracle_state,
    reset_oracle_knowledge_base(Oracle0, Oracle),
    !Diagnoser ^ oracle_state := Oracle.

:- func top_down_search_mode = mdb.declarative_analyser.search_mode.

top_down_search_mode = mdb.declarative_analyser.top_down_search_mode.

:- pragma foreign_export("C",
    mdb.declarative_debugger.top_down_search_mode = out,
    "MR_DD_decl_top_down_search_mode").

:- func divide_and_query_search_mode = mdb.declarative_analyser.search_mode.

divide_and_query_search_mode =
    mdb.declarative_analyser.divide_and_query_search_mode.

:- pragma foreign_export("C",
    mdb.declarative_debugger.divide_and_query_search_mode = out,
    "MR_DD_decl_divide_and_query_search_mode").

:- func suspicion_divide_and_query_search_mode =
    mdb.declarative_analyser.search_mode.

suspicion_divide_and_query_search_mode =
    mdb.declarative_analyser.suspicion_divide_and_query_search_mode.

:- pragma foreign_export("C",
    mdb.declarative_debugger.suspicion_divide_and_query_search_mode = out,
    "MR_DD_decl_suspicion_divide_and_query_search_mode").

    % Export a monomorphic version of diagnosis/10 that passes a newly
    % materialized tree for use with the C backend code.
    %
:- pred diagnosis_new_tree(trace_node_store::in, trace_node_id::in,
    diagnoser_response(trace_node_id)::out,
    diagnoser_state(trace_node_id)::in, diagnoser_state(trace_node_id)::out,
    browser_info.browser_persistent_state::in,
    browser_info.browser_persistent_state::out, io::di, io::uo) is cc_multi.

:- pragma foreign_export("C",
    diagnosis_new_tree(in, in, out, in, out, in, out, di, uo),
    "MR_DD_decl_diagnosis_new_tree").

diagnosis_new_tree(Store, Node, Response, !State, !Browser, !IO) :-
    diagnosis(Store, new_tree(dynamic(Node)), Response, !State, !Browser, !IO).

    % Export a monomorphic version of diagnosis/10 that requests the
    % continuation of a previously suspended declarative debugging session.
    %
:- pred diagnosis_resume_previous(trace_node_store::in,
    diagnoser_response(trace_node_id)::out,
    diagnoser_state(trace_node_id)::in, diagnoser_state(trace_node_id)::out,
    browser_info.browser_persistent_state::in,
    browser_info.browser_persistent_state::out, io::di, io::uo) is cc_multi.

:- pragma foreign_export("C",
    diagnosis_resume_previous(in, out, in, out, in, out, di, uo),
    "MR_DD_decl_diagnosis_resume_previous").

diagnosis_resume_previous(Store, Response, !State, !Browser, !IO) :-
    diagnosis(Store, resume_previous, Response, !State, !Browser, !IO).

    % Export some predicates so that C code can interpret the
    % diagnoser response.
    %
:- pred diagnoser_bug_found(diagnoser_response(trace_node_id)::in,
    event_number::out) is semidet.

:- pragma foreign_export("C", diagnoser_bug_found(in, out),
    "MR_DD_diagnoser_bug_found").

diagnoser_bug_found(bug_found(Event), Event).

:- pred diagnoser_symptom_found(diagnoser_response(trace_node_id)::in,
    event_number::out) is semidet.

:- pragma foreign_export("C", diagnoser_symptom_found(in, out),
    "MR_DD_diagnoser_symptom_found").

diagnoser_symptom_found(symptom_found(Event), Event).

:- pred diagnoser_no_bug_found(diagnoser_response(trace_node_id)::in)
    is semidet.

:- pragma foreign_export("C", diagnoser_no_bug_found(in),
    "MR_DD_diagnoser_no_bug_found").

diagnoser_no_bug_found(no_bug_found).

:- pred diagnoser_require_subtree(diagnoser_response(trace_node_id)::in,
    event_number::out, sequence_number::out, trace_node_id::out, int::out)
    is semidet.

:- pragma foreign_export("C",
    diagnoser_require_subtree(in, out, out, out, out),
    "MR_DD_diagnoser_require_subtree").

diagnoser_require_subtree(require_subtree(Event, SeqNo, CallPreceding,
    MaxDepth), Event, SeqNo, CallPreceding, MaxDepth).

:- pred diagnoser_require_supertree(diagnoser_response(trace_node_id)::in,
    event_number::out, sequence_number::out) is semidet.

:- pragma foreign_export("C",
    diagnoser_require_supertree(in, out, out),
    "MR_DD_diagnoser_require_supertree").

diagnoser_require_supertree(require_supertree(Event, SeqNo), Event, SeqNo).

%-----------------------------------------------------------------------------%

    % Adds a trusted module to the given diagnoser.
    %
:- pred add_trusted_module(string::in, diagnoser_state(trace_node_id)::in,
    diagnoser_state(trace_node_id)::out) is det.

:- pragma foreign_export("C",
    mdb.declarative_debugger.add_trusted_module(in, in, out),
    "MR_DD_decl_add_trusted_module").

add_trusted_module(ModuleName, Diagnoser0, Diagnoser) :-
    SymModuleName = string_to_sym_name(ModuleName),
    add_trusted_module(SymModuleName, Diagnoser0 ^ oracle_state, Oracle),
    Diagnoser = Diagnoser0 ^ oracle_state := Oracle.

    % Adds a trusted predicate/function to the given diagnoser.
    %
:- pred add_trusted_pred_or_func(proc_layout::in,
    diagnoser_state(trace_node_id)::in,
    diagnoser_state(trace_node_id)::out) is det.

:- pragma foreign_export("C",
    mdb.declarative_debugger.add_trusted_pred_or_func(in, in, out),
    "MR_DD_decl_add_trusted_pred_or_func").

add_trusted_pred_or_func(ProcLayout, !Diagnoser) :-
    add_trusted_pred_or_func(ProcLayout, !.Diagnoser ^ oracle_state, Oracle),
    !Diagnoser ^ oracle_state := Oracle.

:- pred trust_standard_library(diagnoser_state(trace_node_id)::in,
    diagnoser_state(trace_node_id)::out) is det.

:- pragma foreign_export("C",
    mdb.declarative_debugger.trust_standard_library(in, out),
    "MR_DD_decl_trust_standard_library").

trust_standard_library(!Diagnoser) :-
    declarative_oracle.trust_standard_library(!.Diagnoser ^ oracle_state,
        Oracle),
    !Diagnoser ^ oracle_state := Oracle.

:- pred remove_trusted(int::in, diagnoser_state(trace_node_id)::in,
    diagnoser_state(trace_node_id)::out) is semidet.

:- pragma foreign_export("C",
    mdb.declarative_debugger.remove_trusted(in, in, out),
    "MR_DD_decl_remove_trusted").

remove_trusted(N, !Diagnoser) :-
    remove_trusted(N, !.Diagnoser ^ oracle_state, Oracle),
    !Diagnoser ^ oracle_state := Oracle.

    % get_trusted_list(Diagnoser, MDBCommandFormat, String).
    % Return a string listing the trusted objects for Diagnoser.
    % If MDBCommandFormat is true then returns the list so that it can be
    % run as a series of mdb `trust' commands.  Otherwise returns them
    % in a format suitable for display only.
    %
:- pred get_trusted_list(diagnoser_state(trace_node_id)::in, bool::in,
    string::out) is det.

:- pragma foreign_export("C",
    mdb.declarative_debugger.get_trusted_list(in, in, out),
    "MR_DD_decl_get_trusted_list").

get_trusted_list(Diagnoser, MDBCommandFormat, List) :-
    get_trusted_list(Diagnoser ^ oracle_state, MDBCommandFormat, List).

%-----------------------------------------------------------------------------%

:- pred handle_diagnoser_exception(diagnoser_exception::in,
    diagnoser_response(R)::out, diagnoser_state(R)::in,
    diagnoser_state(R)::out, io::di, io::uo) is det.

handle_diagnoser_exception(internal_error(Loc, Msg), Response, !Diagnoser,
        !IO) :-
    io.stderr_stream(StdErr, !IO),
    io.write_string(StdErr, "An internal error has occurred; " ++
        "diagnosis will be aborted.  Debugging\n" ++
        "message follows:\n" ++ Loc ++ ": " ++ Msg ++ "\n" ++
        "Please report bugs to mercury-bugs@cs.mu.oz.au.\n", !IO),
    % Reset the analyser, in case it was left in an inconsistent state.
    reset_analyser(!.Diagnoser ^ analyser_state, Analyser),
    !Diagnoser ^ analyser_state := Analyser,
    Response = no_bug_found.

handle_diagnoser_exception(io_error(Loc, Msg), Response, !Diagnoser, !IO) :-
    io.stderr_stream(StdErr, !IO),
    io.write_string(StdErr, "I/O error: " ++ Loc ++ ": " ++ Msg ++ ".\n" ++
        "Diagnosis will be aborted.\n", !IO),
    % Reset the analyser, in case it was left in an inconsistent state.
    reset_analyser(!.Diagnoser ^ analyser_state, Analyser),
    !Diagnoser ^ analyser_state := Analyser,
    Response = no_bug_found.

handle_diagnoser_exception(unimplemented_feature(Feature), Response,
        !Diagnoser, !IO) :-
    io.write_string("Sorry, the diagnosis cannot continue because " ++
        "it requires support for\n" ++
        "the following: " ++ Feature ++ ".\n" ++
        "The debugger is a work in progress, and this is not " ++
        "supported in the\ncurrent version.\n", !IO),
    % Reset the analyser, in case it was left in an inconsistent state.
    reset_analyser(!.Diagnoser ^ analyser_state, Analyser),
    !Diagnoser ^ analyser_state := Analyser,
    Response = no_bug_found.

%-----------------------------------------------------------------------------%

:- pred decl_bug_get_event_number(decl_bug::in, event_number::out) is det.

decl_bug_get_event_number(e_bug(EBug), Event) :-
    (
        EBug = incorrect_contour(_, _, _, Event)
    ;
        EBug = partially_uncovered_atom(_, Event)
    ;
        EBug = unhandled_exception(_, _, Event)
    ).
decl_bug_get_event_number(i_bug(IBug), Event) :-
    IBug = inadmissible_call(_, _, _, Event).

%-----------------------------------------------------------------------------%

:- pred write_origin(wrap(S)::in, subterm_origin(edt_node(R))::in,
    io::di, io::uo) is det <= annotated_trace(S, R).

write_origin(wrap(Store), Origin, !IO) :-
    ( Origin = origin_output(dynamic(NodeId), ArgPos, TermPath) ->
        exit_node_from_id(Store, NodeId, ExitNode),
        ProcLayout = get_proc_layout_from_label_layout(ExitNode ^ exit_label),
        ProcLabel = get_proc_label_from_layout(ProcLayout),
        ProcName = get_proc_name(ProcLabel),
        io.write_string("output(", !IO),
        io.write_string(ProcName, !IO),
        io.write_string(", ", !IO),
        io.write(ArgPos, !IO),
        io.write_string(", ", !IO),
        io.write(TermPath, !IO),
        io.write_string(")", !IO)
    ;
        io.write(Origin, !IO)
    ).

:- pragma foreign_code("C",
"

/*
** The declarative debugger will print diagnostic information about the origins
** computed by dependency tracking if this flag has a positive value.
*/

int MR_DD_debug_origin = 0;

").

:- pragma foreign_decl("C",
"
extern  int MR_DD_debug_origin;
").

:- pred debug_origin(int::out, io::di, io::uo) is det.

:- pragma foreign_proc("C",
    debug_origin(Flag::out, _IO0::di, _IO::uo),
    [will_not_call_mercury, promise_pure, tabled_for_io],
"
    Flag = MR_DD_debug_origin;
").
debug_origin(_, !IO) :-
    private_builtin.sorry("declarative_debugger.debug_origin").
