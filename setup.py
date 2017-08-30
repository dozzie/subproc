#!/usr/bin/python

from setuptools import setup, find_packages, Extension

setup(
    name = "subproc",
    version = "0.0.0",
    description = "unix subprocess supervisor",
    packages = [ "subproc" ],
    package_dir = { "": "pylib" },
    ext_modules = [
        Extension(
            "subproc._unix",
            sources = [
                "c_lib/python.c",
                "c_lib/supervisor.c",
                "c_lib/proto_command.c",
            ],
        ),
    ],
)
