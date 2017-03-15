SRC = $(wildcard *.vala)
PKGS = --pkg=gio-unix-2.0 --pkg=gio-2.0 --pkg=gee-0.8
PREFIX ?= /usr/local
DESTDIR ?= /
CPPFLAGS ?= -D_FORTIFY_SOURCE=2
CFLAGS ?= -O2 -pipe -fstack-protector-strong --param=ssp-buffer-size=4
LDFLAGS ?= -Wl,-O1,--sort-common,--as-needed,-z,relro,-z,noexecstack,--hash-style=gnu
VALAFLAGS :=$(foreach w,$(CPPFLAGS) $(CFLAGS) $(LDFLAGS),-X $(w))

BINARY = systemd-user-manager

VALAC = valac

all: $(BINARY) $(BINARY).service

install: all
	install -Dm755 $(BINARY) $(DESTDIR)/$(PREFIX)/lib/systemd/$(BINARY)
	install -Dm644 $(BINARY).service $(DESTDIR)/$(PREFIX)/lib/systemd/user/$(BINARY).service
	install -Dm644 sleep.target $(DESTDIR)/$(PREFIX)/lib/systemd/user/sleep.target
	install -Dm644 session@.target $(DESTDIR)/$(PREFIX)/lib/systemd/user/session@.target
	install -Dm644 session-mkdir@.service $(DESTDIR)/$(PREFIX)/lib/systemd/user/session-mkdir@.service

$(BINARY):
	@$(VALAC) $(VARGS) $(PKGS) $(VALAFLAGS) -o $(BINARY) $(SRC)

$(BINARY).service: $(BINARY).service.in
	@sed -e 's#{PREFIX}#$(PREFIX)#g' $< > $@

clean:
	@rm -f $(BINARY) $(wildcard *.c) $(BINARY).service

