%---------------------------------------------------------------------------%
% vim: ts=4 sw=4 et ft=mercury
%---------------------------------------------------------------------------%
%
% Test the memoization of model_non predicates.

:- module memo_non.

:- interface.
:- import_module io.

:- pred main(io::di, io::uo) is det.

:- implementation.
:- import_module int.
:- import_module solutions.

:- pragma require_feature_set([memo]).

main(!IO) :-
    solutions(test_non(1, 2), NonSoln1),
    io__write(NonSoln1, !IO),
    io__nl(!IO),
    solutions(test_non(1, 2), NonSoln2),
    io__write(NonSoln2, !IO),
    io__nl(!IO),
    solutions(test_non(2, 2), NonSoln3),
    io__write(NonSoln3, !IO),
    io__nl(!IO),
    solutions(test_non(2, 2), NonSoln4),
    io__write(NonSoln4, !IO),
    io__nl(!IO),

    solutions(test_multi(1, 2), MultiSoln1),
    io__write(MultiSoln1, !IO),
    io__nl(!IO),
    solutions(test_multi(1, 2), MultiSoln2),
    io__write(MultiSoln2, !IO),
    io__nl(!IO),
    % This tests the duplicate detection machinery.
    solutions(test_multi(2, 2), MultiSoln3),
    io__write(MultiSoln3, !IO),
    io__nl(!IO),
    solutions(test_multi(2, 2), MultiSoln4),
    io__write(MultiSoln4, !IO),
    io__nl(!IO).

:- pred test_non(int::in, int::in, int::out) is nondet.
:- pragma memo(test_non/3).
:- pragma promise_pure(test_non/3).
test_non(A, B, C) :-
    impure marker("non", A, B, Zero),
    ( A = 1 ->
        (
            C = Zero + (A * 100) + (B * 10)
        ;
            C = Zero + (B * 100) + (A * 10)
        )
    ;
        fail
    ).

:- pred test_multi(int::in, int::in, int::out) is multi.
:- pragma memo(test_multi/3).
:- pragma promise_pure(test_multi/3).
test_multi(A, B, C) :-
    impure marker("multi", A, B, Zero),
    (
        C = Zero + (A * 100) + (B * 10)
    ;
        C = Zero + (B * 100) + (A * 10)
    ).

:- impure pred marker(string::in, int::in, int::in, int::out) is det.
:- pragma foreign_proc("C",
    marker(S::in, A::in, B::in, X::out),
    [will_not_call_mercury],
"
    printf(""marker executed: %s %d %d\\n"", S, A, B);
    X = 0;
").
