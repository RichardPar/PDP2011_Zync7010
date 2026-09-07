# Makefile for pdp11-hostd.
#
# Works both standalone on a host (`make`) and under Yocto/PetaLinux, where
# bitbake's oe_runmake passes CC / CFLAGS / LDFLAGS for the ARM target. The
# `?=` assignments let those override these defaults; -pthread is added on
# the rule itself so it survives an oe_runmake CFLAGS override (the REST API
# and network rx threads both need it).

CC      ?= cc
CFLAGS  ?= -O2 -Wall
LDFLAGS ?=

PROG     = pdp11-hostd
DESTDIR ?=
bindir  ?= /usr/bin

all: $(PROG)

$(PROG): pdp11-hostd.c
	$(CC) $(CFLAGS) $(LDFLAGS) -pthread -o $@ $<

install: $(PROG)
	install -d $(DESTDIR)$(bindir)
	install -m 0755 $(PROG) $(DESTDIR)$(bindir)/$(PROG)

clean:
	rm -f $(PROG)

.PHONY: all install clean
