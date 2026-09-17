#!/usr/bin/env python3
"""Embed a Metal source file in a C header; no offline Metal toolchain needed."""
import json
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
target = pathlib.Path(sys.argv[2])
target.parent.mkdir(parents=True, exist_ok=True)
body = "/* Generated from kernels.metal. */\nstatic const char pg_metal_kernel_source[] =\n"
body += "\n".join(json.dumps(line) for line in source.splitlines(keepends=True))
body += ";\n"
target.write_text(body)
