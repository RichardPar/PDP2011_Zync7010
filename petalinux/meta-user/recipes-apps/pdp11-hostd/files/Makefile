# Makefile for pdp11-hostd.
#
# Works both standalone on a host (`make`) and under Yocto/PetaLinux, where
# bitbake's oe_runmake passes CC / CFLAGS / LDFLAGS for the ARM target. The
# `?=` assignments let those override these defaults; -pthread is added on
# the rules themselves so it survives an oe_runmake CFLAGS override (the web
# server, the panel push and the network rx/tx paths all need it).
#
# Two build products:
#   libhttpd.a    the embedded HTTP/1.1 + WebSocket server (httpd.c) - no
#                 external dependencies, so nothing new enters the rootfs
#   pdp11-hostd   the daemon, which links it
#
# www_data.h is generated from www/ by mkwww.sh, so the front panel travels
# inside the binary: scripts/deploy_pdp11_hostd.sh installs the daemon by
# copying one ARM ELF to the board, and a UI served from /usr/share would go
# stale behind it. (-W still serves from a directory when iterating.)

CC      ?= cc
AR      ?= ar
CFLAGS  ?= -O2 -Wall
LDFLAGS ?=

PROG     = pdp11-hostd
LIB      = libhttpd.a
DESTDIR ?=
bindir  ?= /usr/bin

WWW      = www/index.html www/panel.css www/panel.js www/favicon.svg

all: $(PROG)

www_data.h: mkwww.sh $(WWW)
	sh ./mkwww.sh $@ $(WWW)

httpd.o: httpd.c httpd.h
	$(CC) $(CFLAGS) -pthread -c -o $@ $<

$(LIB): httpd.o
	$(AR) rcs $@ $^

$(PROG): pdp11-hostd.c www_data.h httpd.h $(LIB)
	$(CC) $(CFLAGS) $(LDFLAGS) -pthread -o $@ pdp11-hostd.c $(LIB)

install: $(PROG)
	install -d $(DESTDIR)$(bindir)
	install -m 0755 $(PROG) $(DESTDIR)$(bindir)/$(PROG)

clean:
	rm -f $(PROG) $(LIB) httpd.o www_data.h

.PHONY: all install clean
