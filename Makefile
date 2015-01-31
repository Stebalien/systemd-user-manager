SRC = $(wildcard *.vala)
PKGS = --pkg=gio-unix-2.0 --pkg=gio-2.0 --pkg=gee-0.8
VARGS = --target-glib=2.36
PREFIX ?= /usr/local

BINARY = systemd-user-manager

VALAC = valac

all: $(BINARY) $(BINARY).service

install: all
	install -Dm755 $(BINARY) $(PREFIX)/bin/$(BINARY)
	install -Dm644 $(BINARY).service $(PREFIX)/lib/systemd/user/$(BINARY).service

$(BINARY):
	@$(VALAC) $(VARGS) $(PKGS) -o $(BINARY) $(SRC)

$(BINARY).service: $(BINARY).service.in
	@sed -e 's#{PREFIX}#$(PREFIX)#g' $< > $@

clean:
	@rm -f $(BINARY) $(wildcard *.c)

