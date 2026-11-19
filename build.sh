#!/bin/bash
#
# Builds UMMPerfusion (Apple silicon + Intel) for IsiX DICOM Viewer (GitHub build; the
# App Store build loads no plugins) or for Horos, and optionally installs it.
#
#   ./build.sh                       IsiX build  -> build/UMMPerfusion.osirixplugin
#   ./build.sh install               ... and install in ~/Library/Application Support/IsiX/Plugins
#   TARGET=horos ./build.sh [install] Horos build -> build-horos/..., ~/Library/Application Support/Horos/Plugins
#
# Needs Xcode (clang, ibtool, codesign).
#
set -euo pipefail
cd "$(dirname "$0")"

TARGET="${TARGET:-isix}"
if [ "$TARGET" = "horos" ]; then
  # Horos 4.0.1 runs on macOS 11+; its headers (Horos + DCM frameworks) are in ./third_party/Horos-headers
  APP="${HOROS_APP:-/Applications/Horos.app}"
  if [ -n "${HOROS_HEADERS:-}" ]; then HEADERS="$HOROS_HEADERS"
  elif [ -f third_party/Horos-headers/PluginFilter.h ]; then HEADERS="$(pwd)/third_party/Horos-headers"
  else HEADERS="$APP/Contents/Frameworks/Horos.framework/Headers"; fi
  MIN_OS=11.0
  BUILD=build-horos
  PLUGIN_DIR="$HOME/Library/Application Support/Horos/Plugins"
  HOST="Horos"
else
APP="${ISIX_APP:-/Applications/IsiX DICOM Viewer.app}"
# Plugin headers: an explicit ISIX_HEADERS, else the copy in ./third_party/IsiX-headers,
# else the ones inside the app (the App Store build ships them, the GitHub build does not).
if [ -n "${ISIX_HEADERS:-}" ]; then
  HEADERS="$ISIX_HEADERS"
elif [ -f third_party/IsiX-headers/PluginFilter.h ]; then
  HEADERS="$(pwd)/third_party/IsiX-headers"
else
  HEADERS="$APP/Contents/Frameworks/Horos.framework/Headers"
fi
  MIN_OS=15.0
  BUILD=build
  PLUGIN_DIR="$HOME/Library/Application Support/IsiX/Plugins"
  HOST="IsiX"
fi
# Universal by default: Apple silicon and Intel (IsiX ships a separate package for each).
ARCHS="${ARCHS:-arm64 x86_64}"
ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=(-arch "$a"); done
NAME=UMMPerfusion
BUNDLE="$BUILD/$NAME.osirixplugin"
LOG="$BUILD/build.log"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$HEADERS/PluginFilter.h" ] || die "$HOST plugin headers not found at: $HEADERS
  They are normally in ./third_party; or set ISIX_HEADERS=... / HOROS_HEADERS=..."
xcrun --find clang >/dev/null 2>&1 || die "Xcode command line tools not found. Run: sudo xcode-select -s /Applications/Xcode.app"
xcrun --find ibtool >/dev/null 2>&1 || die "ibtool not found: full Xcode is required. Run: sudo xcode-select -s /Applications/Xcode.app"

rm -rf "$BUILD"
mkdir -p "$BUILD/include" "$BUILD/obj" "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources/English.lproj"
ln -s "$HEADERS" "$BUILD/include/OsiriXAPI"
: > "$LOG"

SOURCES=(
  Sources/MPCurveFit.c
  Sources/MPFit.c
  Sources/SVDcmp.m
  Sources/UMMP2C2InletRoiBasedController.m
  Sources/UMMP2C2InletUptakePixelBasedMapController.m
  Sources/UMMPAFAllMapsController.m
  Sources/UMMPAFOneAlgorithmController.m
  Sources/UMMPAFOneROIController.m
  Sources/UMMPAlgorithmController.m
  Sources/UMMPBinding.m
  Sources/UMMPCMPanelController.m
  Sources/UMMPChart.m
  Sources/UMMPFastDeconvolution.m
  Sources/UMMPFastDeconvolutionController.m
  Sources/UMMPMapSelectionPanelController.m
  Sources/UMMPPanelController.m
  Sources/UMMPPixelBasedMapController.m
  Sources/UMMPPrefController.m
  Sources/UMMPPreset.m
  Sources/UMMPReport.m
  Sources/UMMPReportChart.m
  Sources/UMMPRoiBasedController.m
  Sources/UMMPRoiList.m
  Sources/UMMPUserDefaults.m
  Sources/UMMPViewerList.m
  Sources/UMMPDSCEngine.m
  Sources/UMMPDSCToolsController.m
  Sources/UMMPCurvesController.m
  Sources/UMMPerfusionFilter.m
  GraphKitShim/GraphKitShim.m
)

COMMON_FLAGS=(
  "${ARCH_FLAGS[@]}" -mmacosx-version-min=$MIN_OS
  -O2 -g
  -fno-objc-arc -fobjc-exceptions
  -fvisibility=default
  -I Sources -I GraphKitShim -I "$BUILD/include" -I "$HEADERS"
  -Wno-deprecated-declarations -Wno-deprecated-implementations
  -Wno-unused-variable -Wno-unused-but-set-variable -Wno-unknown-pragmas
  -Wno-four-char-constants -Wno-objc-method-access -Wno-nullability-completeness
  -Wno-error=int-conversion -Wno-error=implicit-function-declaration
  -Wno-error=incompatible-pointer-types -Wno-error=implicit-int
  -Wno-error=incompatible-function-pointer-types
  -Werror=unguarded-availability-new
)

echo "==> $HOST build, macOS $MIN_OS+: compiling (${#SOURCES[@]} files, $ARCHS) against: $HEADERS"
failed=0
OBJECTS=()
for src in "${SOURCES[@]}"; do
  obj="$BUILD/obj/$(basename "${src%.*}").o"
  OBJECTS+=("$obj")
  extra=()
  case "$src" in
    *.m) extra=(-x objective-c -include Sources/UMMPerfusion_Prefix.pch) ;;
    *.c) extra=(-x c) ;;
  esac
  if ! xcrun clang "${COMMON_FLAGS[@]}" "${extra[@]}" -c "$src" -o "$obj" >>"$LOG" 2>&1; then
    echo "   FAILED: $src"
    failed=1
  fi
done
if [ $failed -ne 0 ]; then
  echo
  echo "Compilation failed. Errors:"
  grep -E "error:" "$LOG" | head -40
  echo
  echo "Full log: $(pwd)/$LOG"
  exit 1
fi

echo "==> Linking"
xcrun clang -bundle "${ARCH_FLAGS[@]}" -mmacosx-version-min=$MIN_OS \
  "${OBJECTS[@]}" \
  -framework Cocoa -framework CoreData -framework Accelerate \
  -undefined dynamic_lookup \
  -o "$BUNDLE/Contents/MacOS/$NAME" >>"$LOG" 2>&1 || { tail -30 "$LOG"; die "link failed (log: $LOG)"; }

echo "==> Compiling interface files"
for xib in Sources/UMMPPanel.xib Sources/UMMPCMPanel.xib Sources/UMMPPreferencePanel.xib; do
  nib="$BUNDLE/Contents/Resources/$(basename "${xib%.xib}").nib"
  if ! xcrun ibtool --errors --warnings --output-format human-readable-text \
        --minimum-deployment-target $MIN_OS --compile "$nib" "$xib" >>"$LOG" 2>&1 || [ ! -e "$nib" ]; then
    tail -30 "$LOG"
    die "ibtool failed on $xib (log: $LOG)"
  fi
done

echo "==> Assembling bundle"
cp Sources/Info.plist "$BUNDLE/Contents/Info.plist"
cp Sources/English.lproj/InfoPlist.strings "$BUNDLE/Contents/Resources/English.lproj/"
# (the OsiriX-era images are no longer shipped: the toolbar uses system symbols, the logo page is gone)
[ -f Sources/version.plist ] && cp Sources/version.plist "$BUNDLE/Contents/"
cp Sources/UMMP-icon.png Sources/UMMP-DSC-icon.png Sources/UMMP-Curves-icon.png "$BUNDLE/Contents/Resources/"

echo "==> Signing (ad hoc)"
codesign --force --sign - --timestamp=none "$BUNDLE" >>"$LOG" 2>&1 || die "codesign failed (log: $LOG)"

echo "==> Built: $(pwd)/$BUNDLE"
lipo -info "$BUNDLE/Contents/MacOS/$NAME" || true

if [ "${1:-}" = "install" ]; then
  DEST="$PLUGIN_DIR"
  mkdir -p "$DEST"
  rm -rf "$DEST/$NAME.osirixplugin"
  cp -R "$BUNDLE" "$DEST/"
  echo "==> Installed to: $DEST/$NAME.osirixplugin"
  echo "    Restart $HOST, then check Plugins > Plugins Manager."
fi
