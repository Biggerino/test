# PoolAdmin — macOS build script (run on a Mac with Xcode).
# Produces: build/libPoolAdmin.dylib (arm64, iOS 12.0+, install_name set so it
# can directly replace Frameworks/libloader.framework/libloader like the
# working payload does).
#
# Usage:
#   cd PoolAdmin
#   chmod +x build.sh
#   ./build.sh
#
# Requirements: Xcode command line tools (xcrun, clang). No Theos needed.
set -euo pipefail
cd "$(dirname "$0")"

OUT_DIR="build"
OUT_DYLIB="$OUT_DIR/libPoolAdmin.dylib"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
MIN_IOS="12.0"

mkdir -p "$OUT_DIR"

SOURCES=(
  Sources/PATweakEntry.mm
  Sources/PAImageHider.mm
  Sources/PAAdminPanel.mm
  Sources/PAOverlayView.mm
  Sources/PARuntimeBridge.mm
  Sources/PAGrantService.mm
  Sources/PAIntegrityBypass.mm
  Sources/PAStoreInterceptor.mm
  Sources/PATrajectoryEngine.mm
)

echo "[*] SDK: $SDK"
echo "[*] Building ${#SOURCES[@]} sources -> $OUT_DYLIB"

xcrun clang++ -arch arm64 \
  -isysroot "$SDK" \
  -mios-version-min="$MIN_IOS" \
  -fobjc-arc -fobjc-abi-version=2 -fmodules \
  -O2 -DNDEBUG \
  -std=c++17 -stdlib=libc++ \
  -dynamiclib \
  -install_name "@rpath/libloader.framework/libloader" \
  -compatibility_version 1 -current_version 1 \
  -framework Foundation -framework UIKit -framework CoreGraphics \
  -framework QuartzCore -framework StoreKit -framework Security \
  -o "$OUT_DYLIB" \
  "${SOURCES[@]}" \
  -Wl,-dead_strip

echo "[*] Built: $OUT_DYLIB"
xcrun vtool -show-build "$OUT_DYLIB" 2>/dev/null || true
lipo -info "$OUT_DYLIB" || true
echo "[*] Done. Next: copy libPoolAdmin.dylib to Windows and run inject_pooladmin.py"
