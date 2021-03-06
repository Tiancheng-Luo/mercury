%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 1999-2000, 2004, 2007 The University of Melbourne.
% This file may only be copied under the terms of the GNU Library General
% Public License - see the file COPYING.LIB in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% Module: posix.select.
% Main author: conway@cs.mu.oz.au
%
%-----------------------------------------------------------------------------%

:- module posix.select.
:- interface.

:- import_module bool.

%-----------------------------------------------------------------------------%

:- type fdset_ptr.

:- pred select(int::in, fdset_ptr::in, fdset_ptr::in, fdset_ptr::in,
    timeval::in, posix.result(int)::out, io::di, io::uo) is det.

:- pred new_fdset_ptr(fdset_ptr::out, io::di, io::uo) is det. 

:- pred fd_clr(fd::in, fdset_ptr::in, io::di, io::uo) is det.

:- pred fd_isset(fd::in, fdset_ptr::in, bool::out, io::di, io::uo) is det.

:- pred fd_set(fd::in, fdset_ptr::in, io::di, io::uo) is det.

:- pred fd_zero(fdset_ptr::in, io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- pragma foreign_decl("C", "
    #include <sys/time.h>
    #include <sys/types.h>
    #include <unistd.h>

    #include ""posix_workarounds.h""
").

:- type fdset_ptr.
:- pragma foreign_type("C", fdset_ptr, "fd_set *", [can_pass_as_mercury_type]).

%-----------------------------------------------------------------------------%

select(Fd, R, W, E, Timeout, Result, !IO) :-
    Timeout = timeval(TS, TM),
    select0(Fd, R, W, E, TS, TM, Res, !IO),
    ( Res < 0 ->
        errno(Err, !IO),
        Result = error(Err)
    ;
        Result = ok(Res)
    ).

:- pred select0(int::in, fdset_ptr::in, fdset_ptr::in, fdset_ptr::in, int::in,
    int::in, int::out, io::di, io::uo) is det.
:- pragma foreign_proc("C",
    select0(N::in, R::in, W::in, E::in, TS::in, TM::in, Res::out,
        IO0::di, IO::uo),
    [promise_pure, will_not_call_mercury, thread_safe, tabled_for_io],
"
    struct timeval tv;

    do {
        tv.tv_sec = TS;
        tv.tv_usec = TM;
        Res = select(N, R, W, E, &tv);
    } while (Res == -1 && MR_is_eintr(errno));
    IO = IO0;
").

%-----------------------------------------------------------------------------%

:- pragma foreign_proc("C",
    new_fdset_ptr(Fds::out, IO0::di, IO::uo),
    [promise_pure, will_not_call_mercury, thread_safe, tabled_for_io],
"
    MR_Word Fds0;

    MR_incr_hp(Fds0, 1+sizeof(fd_set)/sizeof(MR_Word));
    Fds = (fd_set *) Fds0;
    ME_fd_zero(Fds);
    IO = IO0;
").

%-----------------------------------------------------------------------------%

:- pragma foreign_proc("C",
    fd_clr(Fd::in, Fds::in, IO0::di, IO::uo),
    [promise_pure, will_not_call_mercury, thread_safe, tabled_for_io],
"
    ME_fd_clr(Fd, Fds);
    IO = IO0;
").

%-----------------------------------------------------------------------------%

:- pragma foreign_proc("C",
    fd_zero(Fds::in, IO0::di, IO::uo),
    [promise_pure, will_not_call_mercury, thread_safe, tabled_for_io],
"
    ME_fd_zero(Fds);
    IO = IO0;
").

%-----------------------------------------------------------------------------%

:- pragma foreign_proc("C",
    fd_isset(Fd::in, Fds::in, Res::out, IO0::di, IO::uo),
    [promise_pure, will_not_call_mercury, thread_safe, tabled_for_io],
"
    Res = (ME_fd_isset(Fd, Fds) ? MR_YES : MR_NO );
    IO = IO0;
").

%-----------------------------------------------------------------------------%

:- pragma foreign_proc("C",
    fd_set(Fd::in, Fds::in, IO0::di, IO::uo),
    [promise_pure, will_not_call_mercury, thread_safe, tabled_for_io],
"
    ME_fd_set(Fd, Fds);
    IO = IO0;
").

%-----------------------------------------------------------------------------%
:- end_module posix.select.
%-----------------------------------------------------------------------------%
