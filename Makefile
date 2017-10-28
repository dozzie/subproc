#!/usr/bin/make -f

#-----------------------------------------------------------------------------

ifeq ($(wildcard .*.plt),)
#DIALYZER_PLT = ~/.dialyzer_plt
else
DIALYZER_PLT = ~/.dialyzer_plt $(wildcard .*.plt)
endif
DIALYZER_OPTS = --no_check_plt $(if $(DIALYZER_PLT),--plts $(DIALYZER_PLT))

DIAGRAMS = $(basename $(notdir $(wildcard diagrams/*.diag)))
DIAGRAMS_SVG = $(foreach D,$(DIAGRAMS),doc/images/$D.svg)

#-----------------------------------------------------------------------------

PROJECT = subproc
APP_VERSION = $(call app-version,ebin/$(PROJECT).app)
ERL_INSTALL_LIB_DIR = $(ERL_LIB_DIR)/$(PROJECT)-$(APP_VERSION)
DOCDIR = /usr/share/doc/erlang-$(PROJECT)
#MANDIR = /usr/share/man

ERLC_OPTS = +debug_info
EDOC_OPTS := {overview, "src/overview.edoc"}, \
             {source_path, ["src", "examples"]}, \
             todo
ifneq ($(devel),)
EDOC_OPTS := $(EDOC_OPTS), private
endif

include erlang.mk
include erlang.install.mk

# NOTE: appending an empty string is a way make a no-op assignment, as
# target-specific export needs an assignment
app-c_src: export CC +=
app-c_src: export CPPFLAGS +=
ifneq ($(devel),)
app-c_src: export CFLAGS := $(filter-out -O%,-g $(CFLAGS))
app-c_src: export LDFLAGS := $(filter-out -O%,-g $(LDFLAGS))
else
app-c_src: export CFLAGS +=
app-c_src: export LDFLAGS +=
endif
app-c_src: export LDLIBS +=
app-c_src: export OUTDIR = $(CURDIR)/priv
ifeq ($(PLATFORM),linux)
app-c_src: export CPPFLAGS += -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700
endif
# pass down `-I' options for generating $(C_SRC_DIR)/deps.mk
clean: export CFLAGS +=
clean: export CPPFLAGS +=

#-----------------------------------------------------------------------------

.PHONY: dialyzer
YECC_ERL_FILES = $(subst .yrl,.erl,$(subst .xrl,.erl,$(wildcard src/*.[xy]rl)))
ERL_SOURCE_FILES = $(filter-out $(YECC_ERL_FILES),$(wildcard src/*.erl))
dialyzer:
	@echo "dialyzer $(strip $(DIALYZER_OPTS)) --src src/*.erl"
	@dialyzer $(strip $(DIALYZER_OPTS)) --src $(ERL_SOURCE_FILES)

#-----------------------------------------------------------------------------

.PHONY: doc
doc: diagrams edoc

.PHONY: diagrams
diagrams: $(DIAGRAMS_SVG)

doc/images/%.svg: diagrams/%.diag
	blockdiag -o $@ -T svg $<

#-----------------------------------------------------------------------------

.PHONY: install install-erlang install-doc

install: install-erlang install-doc

install-erlang: app
	$(call install-wildcard,644,ebin/*,$(DESTDIR)$(ERL_INSTALL_LIB_DIR)/ebin)
	$(call install-wildcard,755,priv/*.so,$(DESTDIR)$(ERL_INSTALL_LIB_DIR)/priv)
	$(call install,755,priv/subproc_unix_supervisor,$(DESTDIR)$(ERL_INSTALL_LIB_DIR)/priv)

install-doc: edoc
	$(call install-wildcard,644,doc/*.html doc/*.png doc/*.css,$(DESTDIR)$(DOCDIR)/html)

#-----------------------------------------------------------------------------
# vim:ft=make
