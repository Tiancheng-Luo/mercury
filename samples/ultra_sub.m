%------------------------------------------------------------------------------%
%
% file: ultra_sub.m
% author: conway.
%
% 'ultra_sub' is an extended version of zs' 'sub' command. The idea is that
% it takes a pattern, a template and some strings, and matches the strings
% against the patter, binding some variables in the process. Then it
% substitutes the variables in the template for the bindings from the pattern.
%
% usage: ultra_sub <pattern> <template> [strings...]
%
% Variables in the pattern and template are represented by capital letters
% (unfortunately limiting the number of variables to 26 ). Real capital letters
% should be preceeded by a \.
% Variables in the template that do not occur in the pattern are treated as
% real capital letters.
%
% eg
% $ ultra_sub 1X2Y3Z 7Z8Y9X 1a2b3c 1foo2bar3baz
% 7c8b9a
% 7baz8bar9foo
%
% Strings that do not match the pattern are ignored.
%------------------------------------------------------------------------------%
:- module ultra_sub.

:- interface.

:- import_module io.

:- pred main(io__state::di, io__state::uo) is det.

%------------------------------------------------------------------------------%
:- implementation.

:- import_module list, string, char, map.

main -->
	% I really should add some options for switching whether
	% capitals or backslashed things are variables.
	io__command_line_arguments(Args),
	(
		{ Args = [Pattern0, Template0 | Rest] }
	->
		{ string__to_char_list(Pattern0, Pattern) },
		{ string__to_char_list(Template0, Template) },
		process_args(Rest, Pattern, Template)
	;
		io__write_string("usage: ultra_sub template pattern [strings]\n")
	).

%------------------------------------------------------------------------------%

:- pred process_args(list(string), list(char), list(char),
					io__state, io__state).
:- mode process_args(in, in, in, di, uo) is det.

process_args([], _Pattern, _Template) --> [].
process_args([Str|Strs], Pattern, Template) -->
	(
		{ string__to_char_list(Str, Chars) },
		{ map__init(Match0) },
		{ match(Pattern, Chars, Match0, Match) }
	->
			% If the string matches, then apply the substitution
		{ sub(Template, Match, ResultChars) },
		{ string__from_char_list(ResultChars, Result) },
		io__write_string(Result),
		io__write_string("\n")
	;
		[]
	),
	process_args(Strs, Pattern, Template).

%------------------------------------------------------------------------------%

:- pred match(list(char), list(char),
			map(char, list(char)), map(char, list(char))).
:- mode match(in, in, in, out) is semidet.

match([], [], Match, Match).
match([T|Ts], Chars, Match0, Match) :-
	(
		char__is_upper(T)
	->
			% Match against a variable.
		match_2(T, Chars, [], Ts, Match0, Match)
	;
		T = ('\\') % don't you love ISO compiant syntax :-(
	->
		Ts = [T1|Ts1],
		Chars = [T1|Chars1],
		match(Ts1, Chars1, Match0, Match)
	;
		Chars = [T|Chars1],
		match(Ts, Chars1, Match0, Match)
	).

:- pred match_2(char, list(char), list(char), list(char), map(char, list(char)), map(char, list(char))).
:- mode match_2(in, in, in, in, in, out) is semidet.

match_2(X, Chars, Tail, Ts, Match0, Match) :-
	(
			% Have we bound X? Does it match
			% an earlier binding?
		map__search(Match0, X, Chars)
	->
		Match1 = Match0
	;
		map__set(Match0, X, Chars, Match1)
	),
	(
			% Try and match the remainder of the pattern
		match(Ts, Tail, Match1, Match2)
	->
		Match = Match2
	;
			% If the match failed, then try
			% binding less of the string to X.
		remove_last(Chars, Chars1, C),
		match_2(X, Chars1, [C|Tail], Ts, Match0, Match)
	).

%------------------------------------------------------------------------------%

:- pred remove_last(list(char), list(char), char).
:- mode remove_last(in, out, out) is semidet.

remove_last([X|Xs], Ys, Z) :-
	remove_last_2(X, Xs, Ys, Z).

:- pred remove_last_2(char, list(char), list(char), char).
:- mode remove_last_2(in, in, out, out) is det.

remove_last_2(X, [], [], X).
remove_last_2(X, [Y|Ys], [X|Zs], W) :-
	remove_last_2(Y, Ys, Zs, W).


%------------------------------------------------------------------------------%

:- pred sub(list(char), map(char, list(char)), list(char)).
:- mode sub(in, in, out) is det.

sub([], _Match, []).
sub([C|Cs], Match, Result) :-
	(
		char__is_upper(C),
		map__search(Match, C, Chars)
	->
		sub(Cs, Match, Result0),
		list__append(Chars, Result0, Result)
	;
		C = ('\\')
	->
		(
			Cs = [C1|Cs1]
		->
			sub(Cs1, Match, Result0),
			Result = [C1|Result0]
		;
			sub(Cs, Match, Result0),
			Result = Result0
		)
	;
		sub(Cs, Match, Result0),
		Result = [C|Result0]
	).

%------------------------------------------------------------------------------%
%------------------------------------------------------------------------------%
