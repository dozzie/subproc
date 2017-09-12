#!/usr/bin/make -f

#-----------------------------------------------------------------------------
# erlang.mk setup

include env.mk

V ?= 0

verbose_0 = @
verbose_2 = set -x;
verbose = $(verbose_$(V))

gen_verbose_0 = @echo " GEN   " $@;
gen_verbose_2 = set -x;
gen_verbose = $(gen_verbose_$(V))

c_verbose_0 = @echo " C     " $(?F);
c_verbose = $(c_verbose_$(V))

link_verbose_0 = @echo " LD    " $(@F);
link_verbose = $(link_verbose_$(V))

#-----------------------------------------------------------------------------
# entry points for erlang.mk

OUTDIR ?= ../priv
TARGETS = $(OUTDIR)/subproc_unix_supervisor \
          $(OUTDIR)/subproc_sup_drv.so \
          $(OUTDIR)/subproc_unix.so

.PHONY: all clean

all: $(TARGETS)

clean:
	$(gen_verbose) rm -f *.o $(TARGETS)

#-----------------------------------------------------------------------------
# main compilation

SOURCES = int_pack.c proto_command.c proto_event.c signal_names.c \
          subproc_sup.c supervisor.c \
          subproc_unix.c
HEADERS = int_pack.h proto_command.h proto_event.h signal_names.h \
          supervisor.h

SUBPROC_EXE_OBJS = supervisor_exe.o supervisor_loop.o proto_command.o proto_event.o int_pack.o
SUBPROC_SUP_OBJS = subproc_sup.o supervisor.o int_pack.o
SUBPROC_UNIX_OBJS = subproc_unix.o signal_names.o

$(OUTDIR)/subproc_unix_supervisor: $(SUBPROC_EXE_OBJS)
	$(link_verbose) $(CC) -fPIC $(LDFLAGS) -o $@ $^ $(LDLIBS)

$(OUTDIR)/subproc_sup_drv.so: $(SUBPROC_SUP_OBJS)
	$(link_verbose) $(CC) -fPIC -shared $(LDFLAGS) -o $@ $^ $(LDLIBS)

$(OUTDIR)/subproc_unix.so: $(SUBPROC_UNIX_OBJS)
	$(link_verbose) $(CC) -fPIC -shared $(LDFLAGS) -o $@ $^ $(LDLIBS)

%.o: %.c
	$(c_verbose) $(CC) -fPIC $(CFLAGS) $(CPPFLAGS) -c $<

-include deps.mk
deps.mk: $(SOURCES) $(HEADERS)
	$(verbose) gcc -MM $(SOURCES) > $@

#-----------------------------------------------------------------------------
# auxiliary rules

$(OUTDIR):
	$(verbose) mkdir $@

$(TARGETS): | $(OUTDIR)

#-----------------------------------------------------------------------------
# vim:ft=make
