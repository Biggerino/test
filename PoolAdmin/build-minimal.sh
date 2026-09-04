# Minimal load-test dylib (macOS + Xcode only). Compiles ONLY
# PAMinimalTest.mm — no overlay, no hooks, no StoreKit. Used to prove
# whether the libloader slot itself loads on-device.
set -euo pipefail
cd "$(dirname "$0")"
OUT_DIR="build"
OUT_DYLIB="$OUT_DIR/libPoolAdmin-minimal.dylib"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
mkdir -p "$OUT_DIR"
xcrun clang++ -arch arm64 \
  -isysroot "$SDK" \
  -mios-version-min=12.0 \
  -fobjc-arc -fmodules \
  -O2 -DNDEBUG \
  -dynamiclib \
  -install_name "@rpath/libloader.framework/libloader" \
  -compatibility_version 1 -current_version 1 \
  -framework Foundation -framework UIKit \
  -o "$OUT_DYLIB" \
  Sources/PAMinimalTest.mm \
  -Wl,-dead_strip
echo "[*] Built: $OUT_DYLIB"
lipo -info "$OUT_DYLIB" || true
