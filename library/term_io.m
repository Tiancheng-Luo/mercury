%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
%
% File: term_io.nl.
% Main author: fjh.
%
% This file encapsulates all the term I/O.
% This exports predicates to read and write terms in the
% nice ground representation provided in term.nl.
% Some of the predicates here are actually implemented in non-logical
% NU-Prolog in term_io.nu.nl.
%
% This library is still pretty yucko because it's based on
% the old dec-10 Prolog I/O (see, seeing, seen, tell, telling, told)
% instead of the stream-based I/O. 
% TODO: fix this.
%
% XXX:  The prefixes in this module should be changed from io__ to term_io__.
%
%-----------------------------------------------------------------------------%

:- module term_io.
:- import_module io, int, float, string, list, varset, term, require.
:- interface.

% External interface: imported predicate

:- type op_type ---> fx; fy; xf; yf; xfx; xfy; yfx; fxx; fxy; fyx; fyy.
:- pred io__op(int, op_type, string, io__state, io__state).
:- mode io__op(input, input, input, di, uo).
%	io__op(Prec, Type, OpName, IOState0, IOState1).
%		Define an operator as per Prolog op/3 for future calls to
%		io__read_term.

:- type op_details ---> op(int, op_type, string).
:- pred io__current_ops(list(op_details), io__state, io__state).
:- mode io__current_ops(output, di, uo).
%		Return a list containing all the current operator definitions.
%		Does not modify the io__state.

:- type read_term ---> eof ; error(string) ; term(varset, term).
:- pred io__read_term(read_term, io__state, io__state).
:- mode io__read_term(output, di, uo).

%	io__read_term(Result, IO0, IO1).
%		Read a term from standard input. Similar to NU-Prolog
%		read_term/2, except that resulting term is in the ground
%		representation. Binds Result to either 'eof' or
%		'term(VarSet, Term)'.

:- pred io__write_term(varset, term, io__state, io__state).
:- mode io__write_term(input, input, di, uo).
%		Writes a term to standard output.

:- pred io__write_term_nl(varset, term, io__state, io__state).
:- mode io__write_term_nl(input, input, di, uo).
%		As above, except it appends a period and new-line.

:- pred io__write_constant(const, io__state, io__state).
:- mode io__write_constant(input, di, uo).
%		Writes a constant (integer, float, or atom) to stdout.

:- pred io__write_variable(var, varset, io__state, io__state).
:- mode io__write_variable(input, input, di, uo).
%		Writes a variable to stdout.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

/*
:- extern("NU-Prolog", io__op/4).
:- extern("NU-Prolog", io__current_ops/3).
:- extern("NU-Prolog", io__read_term/3).
:- extern("NU-Prolog", io__write_term/4).
:- extern("NU-Prolog", io__write_constant/3).
*/

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

	% write a variable to standard output.
	% use the variable names specified by varset and write _N
	% for all unnamed variables with N starting at 0.

io__write_variable(Variable, VarSet) -->
	io__write_variable_2(Variable, VarSet, 0, _, _).

:- pred io__write_variable_2(var, varset, int, varset, int,
				io__state, io__state).
:- mode io__write_variable_2(input, input, input, output, output, di, uo).

io__write_variable_2(Id, VarSet0, N0, VarSet, N) -->
	( { varset__lookup_name(VarSet0, Id, Name) } ->
		{ N = N0 },
		{ VarSet = VarSet0 },
		io__write_string(Name)
	;
		% XXX problems with name clashes

		{ string__int_to_string(N0, Num) },
		{ string__append("_", Num, VarName) },
		{ varset__name_var(VarSet0, Id, VarName, VarSet) },
		{ N is N0 + 1 },
		io__write_string(VarName)
	).

%-----------------------------------------------------------------------------%

	% write a term to standard output.
	% use the variable names specified by varset and write _N
	% for all unnamed variables with N starting at 0.

io__write_term(VarSet, Term) -->
	io__write_term_2(Term, VarSet, 0, _, _).

:- pred io__write_term_2(term, varset, int, varset, int, io__state, io__state).
:- mode io__write_term_2(input, input, input, output, output, di, uo).

io__write_term_2(term_variable(Id), VarSet0, N0, VarSet, N) -->
	io__write_variable_2(Id, VarSet0, N0, VarSet, N).
io__write_term_2(term_functor(Functor, Args, _), VarSet0, N0, VarSet, N) -->
	(
		{ Args = [PrefixArg] },
		io__unary_prefix_op(Functor)
	->
		io__write_char('('),
		io__write_constant(Functor),
		io__write_char(' '),
		io__write_term_2(PrefixArg, VarSet0, N0, VarSet, N),
		io__write_char(')')
	;
		{ Args = [PostfixArg] },
		io__unary_postfix_op(Functor)
	->
		io__write_char('('),
		io__write_term_2(PostfixArg, VarSet0, N0, VarSet, N),
		io__write_char(' '),
		io__write_constant(Functor),
		io__write_char(')')
	;
		{ Args = [Arg1, Arg2] },
		io__infix_op(Functor)
	->
		io__write_char('('),
		io__write_term_2(Arg1, VarSet0, N0, VarSet1, N1),
		io__write_char(' '),
		io__write_constant(Functor),
		io__write_char(' '),
		io__write_term_2(Arg2, VarSet1, N1, VarSet, N),
		io__write_char(')')
	;
		io__write_constant(Functor),
		(
			{ Args = [X|Xs] }
		->
			io__write_char('('),
			io__write_term_2(X, VarSet0, N0, VarSet1, N1),
			io__write_term_args(Xs, VarSet1, N1, VarSet, N),
			io__write_char(')')
		;
			{ N = N0,
			  VarSet = VarSet0 }
		)
	).

:- pred io__infix_op(const, io__state, io__state).
:- mode io__infix_op(input, di, uo).

:- pred io__unary_prefix_op(const, io__state, io__state).
:- mode io__unary_prefix_op(input, di, uo).

:- pred io__unary_postfix_op(const, io__state, io__state).
:- mode io__unary_postfix_op(input, di, uo).

/*
:- external("NU-Prolog", io__infix_op/3).
:- external("NU-Prolog", io__unary_prefix_op/3).
:- external("NU-Prolog", io__unary_postfix_op/3).
*/

%-----------------------------------------------------------------------------%

:- pred io__write_term_args(list(term), varset, int, varset, int,
				io__state, io__state).
:- mode io__write_term_args(input, input, input, output, output, di, uo).

	% write the remaining arguments
io__write_term_args([], VarSet, N, VarSet, N) --> [].
io__write_term_args(X.Xs, VarSet0, N0, VarSet, N) -->
	io__write_string(", "),
	io__write_term_2(X, VarSet0, N0, VarSet1, N1),
	io__write_term_args(Xs, VarSet1, N1, VarSet, N).

%-----------------------------------------------------------------------------%

	% write the functor
io__write_constant(term_integer(I)) -->
	io__write_int(I).
io__write_constant(term_float(F)) -->
	io__write_float(F).
io__write_constant(term_atom(A))  -->
	io__write_string(A).
io__write_constant(term_string(S)) -->
	io__write_char('"'),
	mercury_quote_string(S),
	io__write_char('"').

%-----------------------------------------------------------------------------%

:- pred mercury_quote_string(string, io__state, io__state).
:- mode mercury_quote_string(input, di, uo).

mercury_quote_string(S0) -->
	( { string__first_char(S0, Char, S1) } ->
		( { mercury_quote_char(Char, QuoteChar) } ->
			io__write_char('\\'),
			io__write_char(QuoteChar)
		;
			io__write_char(Char)
		),
		mercury_quote_string(S1)
	;
		[]
	).

%-----------------------------------------------------------------------------%

:- pred mercury_quote_char(character, character).
:- mode mercury_quote_char(input, output).

mercury_quote_char('\"', '"').
mercury_quote_char('\\', '\\').
mercury_quote_char('\n', 'n').
mercury_quote_char('\t', 't').
mercury_quote_char('\b', 'b').

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

io__write_term_nl(VarSet, Term) -->
	io__write_term(VarSet, Term),
	io__write_string(".\n").

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
