#!/usr/bin/make -f

.PHONY: all build install clean

all: build

build:
	python setup.py $@

install:
	python setup.py $@ $(if $(DESTDIR),--root=$(DESTDIR))

clean:
	python setup.py $@ --all
	rm -rf pylib/*.egg-info
