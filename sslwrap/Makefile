# sslwrap — TLS wrapper for tcpserver services (see sslwrap.c)

CC = gcc
CFLAGS = -O2 -Wall -std=gnu89 -Wno-error -fcommon
LDLIBS = -lssl -lcrypto
PREFIX = /usr/local
BINDIR = $(PREFIX)/bin

all: sslwrap

sslwrap: sslwrap.c
	$(CC) $(CFLAGS) -o sslwrap sslwrap.c $(LDLIBS)

clean:
	rm -f sslwrap sslwrap.o

install: sslwrap
	install -d $(DESTDIR)$(BINDIR)
	install -m 755 sslwrap $(DESTDIR)$(BINDIR)/sslwrap

.PHONY: all clean install
