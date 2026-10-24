# Copyright (c) 2026 Renan Lucas Vieira Hilário
# Copyright (c) 2026 The Renux Project
#
# Renux: renux_tr.c, the dialogs in the user's language; Renux's changes
# to this file are under the MPL 2.0: https://mozilla.org/MPL/2.0/.
BSDDIALOG=	${SRCTOP}/contrib/bsddialog

.PATH:	${BSDDIALOG}/lib

LIB=	bsddialog
PRIVATELIB=	yes
SHLIB_MAJOR=	0
SRCS=	barbox.c \
	datebox.c \
	formbox.c \
	lib_util.c \
	lib_util.h \
	libbsddialog.c \
	menubox.c \
	messagebox.c \
	renux_tr.c \
	textbox.c \
	theme.c \
	timebox.c
INCS=	bsddialog.h \
	bsddialog_theme.h \
	bsddialog_progressview.h
MAN=	bsddialog.3

LIBADD=	ncursesw tinfow
CFLAGS+=	-D_XOPEN_SOURCE_EXTENDED

.include <bsd.lib.mk>
