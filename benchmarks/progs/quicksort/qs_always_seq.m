
:- module qs_always_seq.

:- interface.

:- import_module io.

:- pred main(io::di, io::uo) is det.

:- implementation.

:- import_module benchmarking.
:- import_module list.
:- import_module int.
:- import_module string.

:- import_module qs_utils.

main(!IO) :-
    read_input(Input, !IO),
    quicksort(Input, Sorted),
    sink_output(Sorted, !IO).

:- pred quicksort(list(string)::in, list(string)::out) is det.

quicksort([], []).
quicksort([P | Xs], Sorted) :-
    partition(P, Xs, Bigs, Littles),
    quicksort(Bigs, SortedBigs),
    quicksort(Littles, SortedLittles),
    my_append(SortedLittles, [P | SortedBigs], Sorted).

