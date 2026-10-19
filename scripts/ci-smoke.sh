#!/usr/bin/env bash
set -u
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/tests/smoke"

failed=""

log_failed() {
  grep -qE '(^|[[:space:]])error:| failure$' "$1"
}

run_target() {
  local name="$1"
  shift
  echo ""
  echo "===== $name ====="
  rm -rf zig-out
  local logfile="${ROOT}/smoke-${name}.log"
  local status=0
  zig build "$@" 2>&1 | tee "$logfile" || status=1
  if [ "$status" -ne 0 ] || log_failed "$logfile"; then
    echo "FAILED: $name"
    failed="$failed $name"
  else
    echo "OK: $name"
  fi
}

for t in \
  aarch64-linux-android.35 \
  arm-linux-androideabi.35 \
  x86_64-linux-android.35 \
  x86-linux-android.35 \
  riscv64-linux-android.37 \
; do
  run_target "$t" "-Dtarget=$t"
done

for t in \
  aarch64-linux-musl \
  arm-linux-musleabihf \
  x86_64-linux-musl \
; do
  run_target "ohos-$t" "-Dtarget=$t" -Dohos=true
done

for t in wasm32-emscripten wasm64-emscripten; do
  run_target "$t" "-Dtarget=$t"
done

echo ""
echo "===== cross-working-directory ====="
cd "$ROOT"
rm -rf tests/smoke/zig-out
logfile="${ROOT}/smoke-cross-working-directory.log"
status=0
zig build --build-file tests/smoke/build.zig -Dtarget=aarch64-linux-android.35 \
  2>&1 | tee "$logfile" || status=1
if [ "$status" -ne 0 ] || log_failed "$logfile"; then
  echo "FAILED: cross-working-directory"
  failed="$failed cross-working-directory"
else
  echo "OK: cross-working-directory"
fi

echo ""
echo "===== cache-dir ====="
cd "$ROOT/tests/smoke"
rm -rf .zig-cache smoke-cache zig-out
logfile="${ROOT}/smoke-cache-dir.log"
status=0
zig build -Dtarget=aarch64-linux-android.35 --cache-dir smoke-cache \
  2>&1 | tee "$logfile" || status=1
if [ "$status" -ne 0 ] || log_failed "$logfile"; then
  echo "FAILED: cache-dir"
  failed="$failed cache-dir"
elif [ -d .zig-cache ]; then
  echo "FAILED: cache-dir (default .zig-cache was created; the configure phase must not write there)"
  failed="$failed cache-dir-stray-cache"
elif [ ! -d smoke-cache/o ]; then
  echo "FAILED: cache-dir (smoke-cache/o is missing)"
  failed="$failed cache-dir-missing-output"
else
  echo "OK: cache-dir"
fi

if [ -n "$failed" ]; then
  echo ""
  echo "FAILED targets:"
  for t in $failed; do
    echo "  - $t"
    echo "    --- last output of smoke-${t}.log ---"
    tail -n 20 "${ROOT}/smoke-${t}.log" 2>/dev/null | sed 's/^/    /'
  done
  exit 1
fi

echo ""
echo "ALL TARGETS OK"
