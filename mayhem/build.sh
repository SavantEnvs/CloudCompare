#!/usr/bin/env bash
# mayhem/build.sh — CloudCompare commit-image build.
#  1. CCCoreLib + QCC_DB_LIB + QCC_IO_LIB (shared libs, as upstream builds them) with
#     $SANITIZER_FLAGS + SanCov + DWARF-3 in mayhem/build-fuzz.
#  2. One libFuzzer harness (+ -standalone reproducer) per loader in mayhem/targets.txt,
#     from mayhem/fuzz/fuzz_loader.cpp; qCoreIO plugin loaders are compiled into the harness
#     the way upstream's plugins/core/IO/qCoreIO/test does (the plugin exports nothing).
#  3. Upstream's QtTest suites (libs/qCC_io/test, qCoreIO/test) with normal flags in
#     mayhem/build-test, run by mayhem/test.sh.
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export CC CXX
cd "$SRC"

# Coverage instrumentation for the project libraries only when a sanitizer runtime (which
# carries the SanCov callbacks for the standalone reproducers) is linked.
COV_FLAGS=""
[ -n "$SANITIZER_FLAGS" ] && COV_FLAGS="-fsanitize=fuzzer-no-link"
# UBSan's vptr check needs the typeinfo of every polymorphic class it sees, but the qCC_db
# shared library does not export some of it (e.g. NormsIndexesTableType), so the harness
# link fails with "undefined reference to typeinfo". Only that one check is relaxed; ASan and
# the rest of UBSan stay on and halting.
case "$SANITIZER_FLAGS" in *undefined*|*vptr*) COV_FLAGS="$COV_FLAGS -fno-sanitize=vptr" ;; esac

COMMON_CMAKE=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON
  -DOPTION_BUILD_CCVIEWER=OFF -DCMAKE_EXPORT_COMPILE_COMMANDS=ON)
TEST_TARGETS=(TestPlyFilter TestAsciiFilter TestAsciiOpenDlg TestFileRoundTrip
  TestDepthMapFilter TestShpFilter TestCoreIOFilters)

# 1) sanitized project libraries
FB="$SRC/mayhem/build-fuzz"
# Release, but -O1 and without -DNDEBUG so upstream's asserts stay live in the fuzzed code.
cmake -S "$SRC" -B "$FB" "${COMMON_CMAKE[@]}" -DCMAKE_C_FLAGS_RELEASE=-O1 -DCMAKE_CXX_FLAGS_RELEASE=-O1 \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $COV_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $COV_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS $COV_FLAGS" -DCMAKE_SHARED_LINKER_FLAGS="$SANITIZER_FLAGS $COV_FLAGS"
cmake --build "$FB" -j"$MAYHEM_JOBS" --target QCC_IO_LIB QCC_DB_LIB

# 2) harnesses
HFLAGS=$(python3 "$SRC/mayhem/flags_from_cdb.py" "$FB/compile_commands.json" qCoreIO/test/TestCoreIOFilters.cpp)
LIBS=()
for l in QCC_IO_LIB QCC_DB_LIB CCCoreLib; do
  LIBS+=("$(find "$FB" -name "lib${l}.so" -print -quit)")
done
RPATH=""
for l in "${LIBS[@]}"; do RPATH="$RPATH -Wl,-rpath,$(dirname "$l")"; done
QTLIBS=$(pkg-config --libs Qt6Widgets Qt6Gui Qt6Core Qt6Concurrent Qt6OpenGL Qt6OpenGLWidgets Qt6PrintSupport)
OBJ="$FB/fuzz-obj"
OUT="$SRC/mayhem/bin"
mkdir -p "$OUT"
mkdir -p "$OBJ"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"
while read -r name header cls ext extra; do
  case "$name" in ''|'#'*) continue ;; esac
  objs=()
  eval "$CXX $HFLAGS $COV_FLAGS $DEBUG_FLAGS -I$SRC/plugins/core/IO/qCoreIO/include/PDMS \
    -DFUZZ_FILTER_HEADER='<$header>' -DFUZZ_FILTER_CLASS=$cls -DFUZZ_EXT='\"$ext\"' \
    -c $SRC/mayhem/fuzz/fuzz_loader.cpp -o $OBJ/fuzz_$name.o"
  if [ "$extra" != "-" ]; then
    IFS=';' read -ra srcs <<<"$extra"
    for s in "${srcs[@]}"; do
      o="$OBJ/$(basename "$s" .cpp).o"
      [ -f "$o" ] && [ "$o" -nt "$SRC/$s" ] || \
        eval "$CXX $HFLAGS $COV_FLAGS $DEBUG_FLAGS -I$SRC/plugins/core/IO/qCoreIO/include/PDMS -c $SRC/$s -o $o"
      objs+=("$o")
    done
  fi
  $CXX $SANITIZER_FLAGS $COV_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$OBJ/fuzz_$name.o" "${objs[@]}" "$OBJ/lsan_off.o" \
    "${LIBS[@]}" $QTLIBS $RPATH -o "$OUT/fuzz_$name"
  $CXX $SANITIZER_FLAGS $COV_FLAGS $DEBUG_FLAGS "$OBJ/standalone_main.o" "$OBJ/fuzz_$name.o" "${objs[@]}" "$OBJ/lsan_off.o" \
    "${LIBS[@]}" $QTLIBS $RPATH -o "$OUT/fuzz_$name-standalone"
done < "$SRC/mayhem/targets.txt"

# 3) upstream's loader tests, normal flags
TB="$SRC/mayhem/build-test"
cmake -S "$SRC" -B "$TB" "${COMMON_CMAKE[@]}" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS" -DCMAKE_SHARED_LINKER_FLAGS="$COVERAGE_FLAGS"
cmake --build "$TB" -j"$MAYHEM_JOBS" --target "${TEST_TARGETS[@]}"
