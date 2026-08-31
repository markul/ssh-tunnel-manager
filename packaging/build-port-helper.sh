#!/bin/sh
set -eu

source_dir="$SRCROOT/LocalWebProxy/Sources/PortSocketSupport"
output="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/web-proxy-bind"
/bin/mkdir -p "$(/usr/bin/dirname "$output")"
set --
for architecture in $ARCHS; do
    set -- "$@" -arch "$architecture"
done
/usr/bin/xcrun clang "$@" -O2 -Wall -Wextra -Werror \
    -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -DSTM_BINDER_MAIN \
    -I"$source_dir/include" "$source_dir/PortSocketSupport.c" -o "$output"
if [ "${CODE_SIGNING_ALLOWED:-NO}" != "NO" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    /usr/bin/codesign --force --options runtime --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$output"
else
    /usr/bin/codesign --force --sign - "$output"
fi
