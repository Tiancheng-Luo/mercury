:- module type_spec.

:- interface.

:- import_module io.
:- import_module int, list.

:- pred main(io__state::di, io__state::uo) is det.

:- typeclass comparable_t(T) where [
		pred compare_t(comparison_result::out, T::in, T::in) is det
].

:- instance comparable_t(int) where [
		pred(compare_t/3) is compare_int
].
:- pred compare_int(comparison_result::out, int::in, int::in) is det.

:- pred type_spec(list(T)::in, list(T)::in, list(T)::out) is det.
:- pragma type_spec(type_spec/3, T = int).

:- pred typeclass_spec(list(T)::in, list(T)::in,
		list(T)::out) is det <= comparable_t(T).
:- pragma type_spec(typeclass_spec/3, T = int).

:- typeclass all_zero(T) where [
		pred all_zero(T::in) is semidet
	].

:- instance all_zero(list(T)) <= all_zero(T) where [
		pred(all_zero/1) is list_all_zero
	].

:- instance all_zero(int) where [
		pred(all_zero/1) is is_zero
	].

:- pred is_zero(int::in) is semidet.

	% This tests the case where higher_order.m must extract
	% the typeclass_infos for the constraints on an instance
	% declaration when specializing a class method call.
:- pred list_all_zero(list(T)::in) is semidet <= all_zero(T). 
:- pragma type_spec(list_all_zero/1, T = int).

:- implementation.

main -->
	{ type_spec([1,2,3], [3,4,5], Result1) },
	io__write(Result1),
	io__nl,
	{ typeclass_spec([1,2,3], [3,4,5], Result2) },
	io__write(Result2),
	io__nl,
	( { all_zero([0,1,2,3]) } ->
		io__write_string("Failed\n")
	;
		io__write_string("Succeeded\n")
	),
	( { all_zero([0,0,0]) } ->
		io__write_string("Succeeded\n")
	;
		io__write_string("Failed\n")
	).

type_spec([], [], []).
type_spec([_ | _], [], []).
type_spec([], [_ | _], []).
type_spec([A | As], [B | Bs], Cs) :-
	compare(Result, A, B),
	( Result = (<) ->
		type_spec(As, [B | Bs], Cs)
	; Result = (=) ->
		type_spec(As, Bs, Cs1),
		Cs = [A | Cs1]
	;
		type_spec([A | As], Bs, Cs)
	).

typeclass_spec([], [], []).
typeclass_spec([_ | _], [], []).
typeclass_spec([], [_ | _], []).
typeclass_spec([A | As], [B | Bs], Cs) :-
	compare_t(Result, A, B),
	( Result = (<) ->
		typeclass_spec(As, [B | Bs], Cs)
	; Result = (=) ->
		typeclass_spec(As, Bs, Cs1),
		Cs = [A | Cs1]
	;
		typeclass_spec([A | As], Bs, Cs)
	).

compare_int(Result, Int1, Int2) :-
	( Int1 < Int2 ->
		Result = (<)
	; Int1 = Int2 ->
		Result = (=)
	;
		Result = (>)
	).

list_all_zero([]).
list_all_zero([H | T]) :-
	all_zero(H),
	list_all_zero(T).

is_zero(0).
