EXTENSION = pg_metal
MODULE_big = pg_metal
DATA = sql/pg_metal--0.1.0.sql
PG_CONFIG ?= pg_config
PG_CPPFLAGS = -Isrc -Ibuild
override with_llvm = no

ifeq ($(shell uname -s),Darwin)
OBJS = src/pg_metal.o src/cpu_backend.o src/metal_backend.o
METAL_LIBS = -framework Foundation -framework Metal
SHLIB_LINK = $(METAL_LIBS)
else
OBJS = src/pg_metal.o src/cpu_backend.o src/metal_stub.o
endif

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

src/metal_backend.o: src/metal_backend.m src/pg_metal_backend.h build/pg_metal_kernels.h
	$(CC) -O3 -Wall -Wextra -fPIC -fobjc-arc -Isrc -Ibuild -c $< -o $@

build/pg_metal_kernels.h: src/kernels.metal src/embed_kernel.py
	mkdir -p build
	python3 src/embed_kernel.py $< $@

src/pg_metal.o src/cpu_backend.o src/metal_stub.o: src/pg_metal_backend.h

.PHONY: test cpu-test demo bench benchmark backend-bench
test: all
	./scripts/run-local.sh test
demo: all
	./scripts/run-local.sh demo
benchmark: all
	./scripts/run-local.sh benchmark
bench: benchmark

build/backend_bench: bench/backend_bench.c src/cpu_backend.o $(filter src/metal_backend.o src/metal_stub.o,$(OBJS))
	mkdir -p build
	$(CC) -O3 -Wall -Wextra -Isrc $^ $(METAL_LIBS) -o $@

backend-bench: build/backend_bench
	./build/backend_bench

ifeq ($(shell uname -s),Darwin)
build/pg_metal_cpu_only.so: src/pg_metal.o src/cpu_backend.o src/metal_stub.o
	mkdir -p build
	$(CC) -bundle -undefined dynamic_lookup -o $@ $^
cpu-test: build/pg_metal_cpu_only.so
	PG_METAL_LIBRARY="$(CURDIR)/build/pg_metal_cpu_only" ./scripts/run-local.sh test
else
cpu-test: test
endif
