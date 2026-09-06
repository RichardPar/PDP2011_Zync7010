# Makefile for pdp11-netd.
#
# Works both standalone on a host (`make`) and under Yocto/PetaLinux, where
# bitbake's oe_runmake passes CC / CFLAGS / LDFLAGS for the ARM target.
# -pthread is added on the rule itself so it survives an oe_runmake CFLAGS
# override (the irq-handling thread needs it).

CC      ?= cc
CFLAGS  ?= -O2 -Wall
LDFLAGS ?=

PROG     = pdp11-netd
DESTDIR ?=
bindir  ?= /usr/bin

all: $(PROG)

$(PROG): pdp11-netd.c
	$(CC) $(CFLAGS) $(LDFLAGS) -pthread -o $@ $<

install: $(PROG)
	install -d $(DESTDIR)$(bindir)
	install -m 0755 $(PROG) $(DESTDIR)$(bindir)/$(PROG)

clean:
	rm -f $(PROG)

.PHONY: all install clean
