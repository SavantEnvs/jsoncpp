#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

LPM=/opt/toolchains/lpm
FUZZ_BUILD="$SRC/build-fuzz"      # sanitized library for the fuzz harnesses (gitignored: /build-*/)
TEST_BUILD="$SRC/build-tests"     # normal-flags library + test binaries (gitignored: /build-*/)
COV_FLAGS="-fsanitize=fuzzer-no-link"   # SanCov instrumentation of the library, even when SANITIZER_FLAGS is empty
CMAKE_COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX"
              -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_OBJECT_LIBS=OFF
              -DJSONCPP_WITH_POST_BUILD_UNITTEST=OFF -DJSONCPP_WITH_PKGCONFIG_SUPPORT=OFF
              -DJSONCPP_WITH_CMAKE_PACKAGE=OFF -DJSONCPP_WITH_INSTALL=OFF)

# 1) The project itself (static library), sanitized + instrumented, DWARF 3.
cmake -S "$SRC" -B "$FUZZ_BUILD" "${CMAKE_COMMON[@]}" -DJSONCPP_WITH_TESTS=OFF \
      -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $COV_FLAGS" \
      -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $COV_FLAGS"
cmake --build "$FUZZ_BUILD" -j"$MAYHEM_JOBS" --target jsoncpp_static
JSONCPP_A="$FUZZ_BUILD/lib/libjsoncpp.a"
[ -f "$JSONCPP_A" ] || { echo "build.sh: $JSONCPP_A missing" >&2; exit 1; }

# 2) Harnesses: libFuzzer binary + run-once -standalone reproducer each. Leak detection is off at
#    build time via lsan_off.o. The standalone driver is C, compiled once as a C object.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZ_BUILD/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FUZZ_BUILD/standalone_main.o"
HCXX="$SANITIZER_FLAGS $DEBUG_FLAGS $COV_FLAGS"

# jsoncpp_fuzzer: upstream's own harness (src/test_lib_json/fuzz.cpp), also OSS-Fuzz's jsoncpp_fuzzer.
$CXX $HCXX $LIB_FUZZING_ENGINE -I"$SRC/include" -I"$SRC/src/test_lib_json" \
    "$SRC/src/test_lib_json/fuzz.cpp" "$FUZZ_BUILD/lsan_off.o" "$JSONCPP_A" -o /mayhem/jsoncpp_fuzzer
$CXX $HCXX -I"$SRC/include" -I"$SRC/src/test_lib_json" \
    "$SRC/src/test_lib_json/fuzz.cpp" "$FUZZ_BUILD/standalone_main.o" "$FUZZ_BUILD/lsan_off.o" "$JSONCPP_A" \
    -o /mayhem/jsoncpp_fuzzer-standalone

# jsoncpp_proto_fuzzer: OSS-Fuzz's structure-aware (libprotobuf-mutator) harness; protobuf from apt,
# LPM pinned into /opt/toolchains/lpm by the Dockerfile — nothing is fetched here.
PD="$SRC/mayhem/jsoncpp_proto_fuzzer"
GEN="$FUZZ_BUILD/genfiles"
mkdir -p "$GEN"
protoc --proto_path="$PD" --cpp_out="$GEN" "$PD/json.proto"
PROTO_SRCS=("$PD/jsoncpp_fuzz_proto.cc" "$GEN/json.pb.cc" "$PD/json_proto_converter.cc")
PROTO_INC=(-DNDEBUG -I"$GEN" -I"$PD" -I"$LPM/include" -I"$LPM/include/libprotobuf-mutator" -I"$SRC/include")
PROTO_LIBS=("$LPM/lib/libprotobuf-mutator-libfuzzer.a" "$LPM/lib/libprotobuf-mutator.a" /usr/lib/x86_64-linux-gnu/libprotobuf.a -lz -lpthread)
$CXX $HCXX $LIB_FUZZING_ENGINE "${PROTO_INC[@]}" "${PROTO_SRCS[@]}" "$FUZZ_BUILD/lsan_off.o" \
    "$JSONCPP_A" "${PROTO_LIBS[@]}" -o /mayhem/jsoncpp_proto_fuzzer
$CXX $HCXX "${PROTO_INC[@]}" "${PROTO_SRCS[@]}" "$FUZZ_BUILD/standalone_main.o" "$FUZZ_BUILD/lsan_off.o" \
    "$JSONCPP_A" "${PROTO_LIBS[@]}" -o /mayhem/jsoncpp_proto_fuzzer-standalone

# 3) The test suite with the project's NORMAL flags (no sanitizers, no DWARF pin): the unit-test
#    runner and the jsontestrunner that test/runjsontests.py drives. test.sh only RUNS them.
cmake -S "$SRC" -B "$TEST_BUILD" "${CMAKE_COMMON[@]}" -DJSONCPP_WITH_TESTS=ON \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build "$TEST_BUILD" -j"$MAYHEM_JOBS" --target jsoncpp_test jsontestrunner_exe
