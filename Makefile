# Top-level driver for bootstrapping, building and installing dictd.
#
# The autoconf-generated Makefile lives in $(BUILDDIR) (out-of-tree/VPATH
# build), so this file is never overwritten by configure.  Do NOT run
# ./configure in the source tree: it would replace this file.
#
# Quick start:  make bootstrap && make && make test && sudo make install
# Run `make help` for all targets and tunables.

ifneq (,)
This makefile requires GNU Make.
endif

SHELL          := /bin/sh
.DEFAULT_GOAL  := build
.SUFFIXES:

# ---- tunables (override on the command line) --------------------------------
BUILDDIR       ?= BUILD
PREFIX         ?= /usr/local
DESTDIR        ?=
CONFIGURE_FLAGS ?=
# 1 = apply debian/patches (as the Debian package does); 0 = pristine upstream
PATCHES        ?= 1
# Plugins: judy/dbi are opt-in upstream; set to 1 to request them.
WITH_JUDY      ?= 0
WITH_DBI       ?= 0

SRCDIR         := $(CURDIR)
SERIES         := $(SRCDIR)/debian/patches/series
PATCH_LIST     := $(SRCDIR)/.applied-patches
PATCH_STAMP    := $(SRCDIR)/patches-stamp
CONFIG_ARGS    := $(BUILDDIR)/.configure-args
CONFIG_STATUS  := $(BUILDDIR)/config.status

UNAME_S        := $(shell uname -s)
SUDO           := $(shell [ "`id -u`" = 0 ] || echo sudo)

# ---- platform specifics -----------------------------------------------------
ifeq ($(UNAME_S),Darwin)
  # /usr/bin/libtool on macOS is Apple's archiver, not GNU libtool.
  BREW         := $(shell command -v brew 2>/dev/null)
  BREW_PREFIX  := $(if $(BREW),$(shell $(BREW) --prefix 2>/dev/null))
  LIBTOOL      ?= glibtool
  DEP_CPPFLAGS := $(if $(BREW_PREFIX),-I$(BREW_PREFIX)/include)
  DEP_LDFLAGS  := $(if $(BREW_PREFIX),-L$(BREW_PREFIX)/lib)
  BREW_PKGS    := libmaa libtool bison flex autoconf
else
  LIBTOOL      ?= libtool
  DEP_CPPFLAGS :=
  DEP_LDFLAGS  :=
endif
APT_PKGS       := build-essential bison flex autoconf libtool-bin libltdl-dev \
                  libmaa-dev zlib1g-dev
DNF_PKGS       := gcc gcc-c++ make bison flex autoconf libtool libtool-ltdl-devel \
                  libmaa-devel zlib-devel
PACMAN_PKGS    := base-devel bison flex autoconf libtool libmaa zlib

CONFIGURE_CMD  := LIBTOOL='$(LIBTOOL)' \
                  CPPFLAGS='$(CPPFLAGS) $(DEP_CPPFLAGS)' \
                  LDFLAGS='$(LDFLAGS) $(DEP_LDFLAGS)' \
                  $(if $(CFLAGS),CFLAGS='$(CFLAGS)') \
                  $(if $(filter-out default,$(origin CC)),CC='$(CC)') \
                  '$(SRCDIR)/configure' --prefix='$(PREFIX)' \
                  $(if $(filter 1,$(WITH_JUDY)),--with-plugin-judy) \
                  $(if $(filter 1,$(WITH_DBI)),--with-plugin-dbi) \
                  $(CONFIGURE_FLAGS)

INNER          := $(MAKE) -C '$(BUILDDIR)'

.PHONY: help bootstrap deps check-deps patch unpatch regen configure \
        reconfigure build all test check install install-strip uninstall \
        clean distclean maintainer-clean rebuild tags deb FORCE

help:
	@echo 'Targets:'
	@echo '  bootstrap         deps + patch + configure (one-shot setup)'
	@echo '  deps              install build dependencies (brew/apt/dnf/pacman)'
	@echo '  check-deps        verify required tools and libraries are present'
	@echo '  patch / unpatch   apply / revert debian/patches (quilt series)'
	@echo '  regen             regenerate configure + config.h.in via autoconf'
	@echo '  configure         configure out-of-tree in $$(BUILDDIR)'
	@echo '  reconfigure       force a fresh configure'
	@echo '  build (default)   compile everything'
	@echo '  test | check      run the upstream test suite'
	@echo '  install           install into $$(DESTDIR)$$(PREFIX)'
	@echo '  install-strip     install with stripped binaries'
	@echo '  uninstall         remove installed files'
	@echo '  clean             remove objects/binaries, keep configuration'
	@echo '  distclean         remove $$(BUILDDIR) entirely'
	@echo '  maintainer-clean  distclean + unpatch (pristine git tree)'
	@echo '  rebuild           distclean + build'
	@echo '  tags              generate etags TAGS'
	@echo '  deb               build Debian binary packages (Debian/Ubuntu only)'
	@echo 'Variables: BUILDDIR=$(BUILDDIR) PREFIX=$(PREFIX) DESTDIR=$(DESTDIR)'
	@echo '           PATCHES=$(PATCHES) WITH_JUDY=$(WITH_JUDY) WITH_DBI=$(WITH_DBI)'
	@echo '           LIBTOOL=$(LIBTOOL) CONFIGURE_FLAGS="$(CONFIGURE_FLAGS)"'

bootstrap: deps configure

all: build

# ---- dependencies -----------------------------------------------------------
deps:
ifeq ($(UNAME_S),Darwin)
	@test -n '$(BREW)' || { echo 'error: Homebrew not found; install it from https://brew.sh' >&2; exit 1; }
	$(BREW) install $(BREW_PKGS)
else
	@if command -v apt-get >/dev/null 2>&1; then \
	    $(SUDO) apt-get update && $(SUDO) apt-get install -y $(APT_PKGS); \
	elif command -v dnf >/dev/null 2>&1; then \
	    $(SUDO) dnf install -y $(DNF_PKGS); \
	elif command -v pacman >/dev/null 2>&1; then \
	    $(SUDO) pacman -S --needed --noconfirm $(PACMAN_PKGS); \
	else \
	    echo 'error: unsupported package manager; install manually:' >&2; \
	    echo '  C compiler, GNU make, bison/yacc, flex/lex, GNU libtool, libmaa, zlib' >&2; \
	    exit 1; \
	fi
endif
	@$(MAKE) --no-print-directory check-deps

check-deps:
	@rc=0; \
	for t in '$(CC)' '$(LIBTOOL)' patch; do \
	    command -v $$t >/dev/null 2>&1 || { echo "missing tool: $$t" >&2; rc=1; }; \
	done; \
	command -v bison >/dev/null 2>&1 || command -v yacc >/dev/null 2>&1 || { echo 'missing tool: bison/yacc' >&2; rc=1; }; \
	command -v flex  >/dev/null 2>&1 || command -v lex  >/dev/null 2>&1 || { echo 'missing tool: flex/lex' >&2; rc=1; }; \
	'$(LIBTOOL)' --version 2>/dev/null | grep -q 'GNU libtool' || { echo 'LIBTOOL=$(LIBTOOL) is not GNU libtool' >&2; rc=1; }; \
	tmp=`mktemp -d 2>/dev/null || mktemp -d -t dictd`; \
	trap 'rm -rf "$$tmp"' EXIT INT TERM; \
	printf '#include <maa.h>\n#include <zlib.h>\nint main(void){maa_shutdown();return zlibVersion()==0;}\n' > "$$tmp/t.c"; \
	'$(CC)' $(CPPFLAGS) $(DEP_CPPFLAGS) "$$tmp/t.c" -o "$$tmp/t" $(LDFLAGS) $(DEP_LDFLAGS) -lmaa -lz >/dev/null 2>&1 \
	    || { echo 'missing library/headers: libmaa and/or zlib' >&2; rc=1; }; \
	[ $$rc = 0 ] && echo 'all build dependencies present'; exit $$rc

# ---- Debian patch series ----------------------------------------------------
# Idempotent and resumable: each applied patch is recorded in $(PATCH_LIST);
# patches already present in the tree (e.g. applied by quilt) are detected.
patch: $(PATCH_STAMP)

$(PATCH_STAMP): $(SERIES)
	@set -e; touch '$(PATCH_LIST)'; \
	for p in `sed -e 's/#.*//' -e '/^[[:space:]]*$$/d' '$(SERIES)'`; do \
	    grep -qxF "$$p" '$(PATCH_LIST)' && continue; \
	    f='debian/patches/'"$$p"; \
	    if patch -p1 -N -s -f --dry-run < "$$f" >/dev/null 2>&1; then \
	        echo "applying $$p"; patch -p1 -N -s -f < "$$f"; \
	    elif patch -p1 -R -s -f --dry-run < "$$f" >/dev/null 2>&1; then \
	        echo "already applied: $$p"; \
	    else \
	        echo "error: $$p does not apply; fix it or run 'make unpatch'" >&2; exit 1; \
	    fi; \
	    echo "$$p" >> '$(PATCH_LIST)'; \
	done
	@touch '$@'

unpatch:
	@set -e; [ -f '$(PATCH_LIST)' ] || { echo 'no patches applied'; exit 0; }; \
	for p in `sed '1!G;h;$$!d' '$(PATCH_LIST)'`; do \
	    echo "reverting $$p"; \
	    patch -p1 -R -s -f < 'debian/patches/'"$$p"; \
	    grep -vxF "$$p" '$(PATCH_LIST)' > '$(PATCH_LIST).tmp' || true; \
	    mv '$(PATCH_LIST).tmp' '$(PATCH_LIST)'; \
	done; \
	rm -f '$(PATCH_LIST)' '$(PATCH_STAMP)'

ifeq ($(PATCHES),1)
PATCH_DEP := $(PATCH_STAMP)
else
PATCH_DEP :=
endif

# ---- configure --------------------------------------------------------------
regen: $(PATCH_DEP)
	autoheader
	autoconf
	rm -rf autom4te.cache

# Rewritten only when the effective configure command changes, so changing
# PREFIX/flags triggers a reconfigure while no-op runs stay incremental.
$(CONFIG_ARGS): FORCE
	@mkdir -p '$(BUILDDIR)'
	@printf '%s\n' "$(subst ",\",$(CONFIGURE_CMD))" > '$@.tmp'
	@if cmp -s '$@.tmp' '$@'; then rm -f '$@.tmp'; else mv -f '$@.tmp' '$@'; fi

$(CONFIG_STATUS): $(CONFIG_ARGS) $(SRCDIR)/configure $(SRCDIR)/Makefile.in $(SRCDIR)/config.h.in $(PATCH_DEP)
	@if [ -f '$(SRCDIR)/config.status' ]; then \
	    echo 'error: source tree was configured in-place; remove config.status, config.h and generated files first' >&2; \
	    exit 1; \
	fi
	@# Objects built under the previous configuration would otherwise be
	@# considered up to date and linked with stale flags/libraries.
	@if [ -f '$(BUILDDIR)/Makefile' ]; then $(INNER) clean >/dev/null; fi
	cd '$(BUILDDIR)' && $(CONFIGURE_CMD)
	@touch '$@'

configure: $(CONFIG_STATUS)

reconfigure:
	rm -f '$(CONFIG_STATUS)'
	@$(MAKE) --no-print-directory configure

# ---- build / test / install -------------------------------------------------
build: $(CONFIG_STATUS)
	$(INNER) all

test check: build
	$(INNER) test

install: build
	$(INNER) install DESTDIR='$(DESTDIR)'

install-strip: build
	$(INNER) install DESTDIR='$(DESTDIR)' INSTALL_PROGRAM='$(SRCDIR)/install-sh -c -s'

uninstall:
	@test -f '$(BUILDDIR)/Makefile' || { echo 'error: not configured; run make configure with the same PREFIX' >&2; exit 1; }
	$(INNER) uninstall DESTDIR='$(DESTDIR)'

tags:
	etags *.[ch] *.cpp *.y *.l

deb:
	@command -v dpkg-buildpackage >/dev/null 2>&1 || { echo 'error: dpkg-buildpackage not found (Debian/Ubuntu only)' >&2; exit 1; }
	dpkg-buildpackage -us -uc -b

# ---- cleaning ---------------------------------------------------------------
clean:
	@if [ -f '$(BUILDDIR)/Makefile' ]; then $(INNER) clean; fi

distclean:
	rm -rf '$(BUILDDIR)'
	rm -f config.log TAGS

maintainer-clean: distclean unpatch

rebuild: distclean
	@$(MAKE) --no-print-directory build

FORCE:
