
/*
** Copyright (C) 1997 University of Melbourne.
** This file may only be copied under the terms of the GNU Library General
** Public License - see the file COPYING.LIB in the Mercury distribution.
**
** $Id: util.h,v 1.8 1997-04-26 03:16:18 fjh Exp $
*/


#ifndef UTIL_H
#define	UTIL_H

typedef int
	Bool;

typedef unsigned char
	uchar;

typedef unsigned short
	ushort;

typedef unsigned long
	ulong;

typedef unsigned int
	uint;

/* 
 * XXX: For some bizzare reason TRUE and FALSE are often defined by the C
 * libraries! Are they defined in pure POSIX or pure ANSI?
 */
#ifndef TRUE
#define	TRUE	1
#endif

#ifndef FALSE
#define	FALSE	0
#endif

#define	INT_SIZE	(sizeof(int))
#define	FLOAT_SIZE	(sizeof(float))
#define	DOUBLE_SIZE	(sizeof(double))

/*
 *	For debugging. E.g. XXXdebug("Bad integer value", d, some_var).
 *	XXX: We should implement some smarter tracing stuff that allows
 *	us to select a specific module or procedure to trace, or even
 *	a specific trace statement.
 */
#if	defined(DEBUGGING)
#define	XXXdebug(msg, fmt, val) \
	do { \
		fprintf(stderr, "%s: %s = %" #fmt "\n", msg, #val, val); \
	} while(0)
#else
#define	XXXdebug(msg, fmt, val)	do {} while(0)
#endif	/* DEBUGGING */

void
util_init(void);

void
util_error(const char *fmt, ...);

void
fatal(const char* message);

/*
 * Don't use strdup. See comment in util.c
 */
#if	0
char*
strdup(char *str);
#endif	/* 0 */


#endif	/* UTIL_H */
