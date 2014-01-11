SRC = $(wildcard *.vala)
PKGS = --pkg=gio-unix-2.0 --pkg=gio-2.0 --pkg=gee-0.8
VARGS = --target-glib=2.36

BINARY = systemd-user-manager

VALAC = valac

$(BINARY):
	@$(VALAC) $(VARGS) $(PKGS) -o $(BINARY) $(SRC)

all: $(BINARY)

clean:
	@rm -f $(BINARY) $(wildcard *.c)

