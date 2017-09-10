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

.PHONY: all clean

all: $(OUTDIR)/subproc_sup_drv.so

clean:
	$(gen_verbose) rm -f *.o
	$(gen_verbose) rm -f $(OUTDIR)/subproc_sup_drv.so

#-----------------------------------------------------------------------------
# main compilation

SOURCES = int_pack.c proto_command.c proto_event.c signal_names.c subproc_sup.c supervisor.c
HEADERS = int_pack.h proto_command.h proto_event.h signal_names.h supervisor.h

SUBPROC_SUP_OBJS = subproc_sup.o signal_names.o supervisor.o proto_command.o proto_event.o int_pack.o

$(OUTDIR)/subproc_sup_drv.so: $(SUBPROC_SUP_OBJS)
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

$(OUTDIR)/subproc_sup_drv.so: | $(OUTDIR)

#-----------------------------------------------------------------------------
# vim:ft=make
