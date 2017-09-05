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

$(OUTDIR)/subproc_sup_drv.so: subproc_sup.o
	$(link_verbose) $(CC) -fPIC -shared $(LDFLAGS) -o $@ $^ $(LDLIBS)

%.o: %.c
	$(c_verbose) $(CC) $(CFLAGS) $(CPPFLAGS) -c $<

#-----------------------------------------------------------------------------
# auxiliary rules

$(OUTDIR):
	$(verbose) mkdir $@

$(OUTDIR)/subproc_sup_drv.so: | $(OUTDIR)

#-----------------------------------------------------------------------------
# vim:ft=make
