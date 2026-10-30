#!/usr/bin/env bash
# Builds (1) the sanitized libFuzzer harnesses + run-once standalone reproducers and
# (2) the upstream acutest suites with NORMAL flags, for mayhem/test.sh to run.
# No network access; re-runnable on an already-built tree.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
B="$SRC/build/mayhem"
T="$SRC/build/tests"
mkdir -p "$B" "$T"

# ---- 1) fuzz harnesses ------------------------------------------------------
# Every TU (project sources included) gets sanitizers + DWARF<=3; the fuzz variant also gets
# fuzzer-no-link so the project code carries SanCov instrumentation. The standalone variant
# is built without it (it links no libFuzzer runtime).
FUZZ_CF="$SANITIZER_FLAGS $DEBUG_FLAGS -O1 -fsanitize=fuzzer-no-link"
STAND_CF="$SANITIZER_FLAGS $DEBUG_FLAGS -O1"

# Compile one source into $B/<variant>/<name>.o ; $1=variant(fuzz|stand) $2=src $3=cc $4..=extra flags
obj() {
  local variant="$1" src="$2" cc="$3"; shift 3
  local cf="$FUZZ_CF"; [ "$variant" = stand ] && cf="$STAND_CF"
  mkdir -p "$B/$variant"
  local out="$B/$variant/$(echo "${src#$SRC/}" | tr '/' '_').o"
  # shellcheck disable=SC2086
  $cc $cf "$@" -c "$src" -o "$out"
  echo "$out"
}

# link <name> <ccflags-for-link...> -- objs... : emits /mayhem/<name> and /mayhem/<name>-standalone
build_harness() {
  local name="$1" lang="$2"; shift 2
  local -a extra=("$@")
  local cc="$CC" std="-std=c11"
  [ "$lang" = cxx ] && { cc="$CXX"; std="-std=c++11"; }
  local -a fo=() so=()
  local s
  for s in "${SRCS[@]}"; do
    local c="$CC" sd="-std=c11"
    case "$s" in *.cc) c="$CXX"; sd="-std=c++11";; esac
    fo+=("$(obj fuzz "$SRC/$s" "$c" $sd "${extra[@]}")")
    so+=("$(obj stand "$SRC/$s" "$c" $sd "${extra[@]}")")
  done
  fo+=("$(obj fuzz "$SRC/mayhem/lsan_off.cc" "$CXX" -std=c++11)")
  so+=("$(obj stand "$SRC/mayhem/lsan_off.cc" "$CXX" -std=c++11)")
  # shellcheck disable=SC2086
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "${fo[@]}" $LIB_FUZZING_ENGINE -pthread -lm -o "$SRC/$name"
  # shellcheck disable=SC2086
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "${so[@]}" "$B/standalone_main.o" -pthread -lm -o "$SRC/$name-standalone"
}

# STANDALONE_FUZZ_MAIN is C: build it as C once so LLVMFuzzerTestOneInput keeps C linkage.
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c -x c "$STANDALONE_FUZZ_MAIN" -o "$B/standalone_main.o"

SRCS=(fuzzer/fuzz_ParseFromString.cc)
build_harness fuzz_ParseFromString cxx -I"$SRC"

SRCS=(fuzzer/fuzz_tobj_c.c tiny_obj_c.c tobj_tess.c)
build_harness fuzz_tobj_c c -DTOBJ_ENABLE_FILE_IO -I"$SRC"

SRCS=(tests/llvm-fuzz/fuzz_loaders.cc tiny_obj_loader.cc experimental/stream/stream_obj_loader.cc)
build_harness fuzz_loaders cxx -DTINYOBJLOADER_USE_MULTITHREADING -pthread -I"$SRC" -I"$SRC/tests"

# ---- 2) upstream test suites, project's normal flags (no sanitizers, no DWARF pin) ----
cd "$SRC/tests"
# shellcheck disable=SC2086
{
  $CXX -O1 -std=c++11 $COVERAGE_FLAGS -pthread -I.. -o "$T/tester" tester.cc ../experimental/stream/stream_obj_loader.cc
  $CXX -O1 -std=c++11 $COVERAGE_FLAGS -DTINYOBJLOADER_USE_MULTITHREADING -DTINYOBJLOADER_USE_SIMD \
       -DTINYOBJLOADER_ENABLE_EXCEPTION -pthread -I.. -o "$T/tester_features" tester.cc ../experimental/stream/stream_obj_loader.cc
  $CC -O1 -std=c11 $COVERAGE_FLAGS -DTOBJ_ENABLE_FILE_IO -DTOBJ_ENABLE_MMAP -I.. \
      -o "$T/tester_c" tester_c.c ../tiny_obj_c.c ../tobj_tess.c -lm
  $CC -O1 -std=c11 $COVERAGE_FLAGS -I.. -o "$T/tess_tester" tess_tester.c ../tobj_tess.c -lm
}
