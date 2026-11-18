#!/bin/bash
#
# Builds the universal plugin (Apple silicon + Intel) and packs it for colleagues:
#   dist/UMMPerfusion-IsiX-<version>.zip   (TARGET=horos: dist/UMMPerfusion-Horos-<version>.zip)
#     UMMPerfusion.osirixplugin
#     Install UMMPerfusion.command
#     README.txt, CHANGES.md, LICENSE.txt
#
set -euo pipefail
cd "$(dirname "$0")"

TARGET="${TARGET:-isix}"
if [ "$TARGET" = "horos" ]; then
  BUILD=build-horos; HOSTNAME=Horos; DIST_FILES=Distribution/Horos
else
  BUILD=build; HOSTNAME=IsiX; DIST_FILES=Distribution
fi
TARGET="$TARGET" ./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $BUILD/UMMPerfusion.osirixplugin/Contents/Info.plist)
NAME="UMMPerfusion-$HOSTNAME-$VERSION"
STAGE="dist/$NAME"

rm -rf "$STAGE" "dist/$NAME.zip"
mkdir -p "$STAGE"
cp -R $BUILD/UMMPerfusion.osirixplugin "$STAGE/"
cp "$DIST_FILES/Install UMMPerfusion.command" "$STAGE/"
chmod +x "$STAGE/Install UMMPerfusion.command"
sed "s/@VERSION@/$VERSION/g" $DIST_FILES/README.txt > "$STAGE/README.txt"
cp CHANGES.md "$STAGE/"
{
  echo "UMMPerfusion — original licence (BSD-3-Clause):"
  echo
  cat Sources/LICENSE
  echo
  echo "------------------------------------------------------------------------"
  echo "IsiX/Horos port (build scripts, GraphKitShim, DSC extensions, fixes): distributed under the"
  echo "same BSD-3-Clause terms as the original. No warranty. Not a medical device."
} > "$STAGE/LICENSE.txt"

codesign --verify --deep "$STAGE/UMMPerfusion.osirixplugin"
echo "==> Architectures: $(lipo -archs "$STAGE/UMMPerfusion.osirixplugin/Contents/MacOS/UMMPerfusion")"

(cd dist && ditto -c -k --sequesterRsrc --keepParent "$NAME" "$NAME.zip")
echo "==> Package: $(pwd)/dist/$NAME.zip"
