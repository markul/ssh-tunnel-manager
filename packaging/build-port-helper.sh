#!/bin/sh
set -eu

source_dir="$SRCROOT/LocalWebProxy/Sources/PortSocketSupport"
output="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/web-proxy-bind"
# codesign creates a sibling .cstemp file. Sign in Xcode's writable staging
# directory, then copy only the declared output into the app bundle.
staged_output="$DERIVED_FILE_DIR/web-proxy-bind"
/bin/mkdir -p "$(/usr/bin/dirname "$output")"
set --
for architecture in $ARCHS; do
    set -- "$@" -arch "$architecture"
done
/usr/bin/xcrun clang "$@" -O2 -Wall -Wextra -Werror \
    -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" -DSTM_BINDER_MAIN \
    -I"$source_dir/include" "$source_dir/PortSocketSupport.c" -o "$staged_output"
if [ "${CODE_SIGNING_ALLOWED:-NO}" != "NO" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    /usr/bin/codesign --force --options runtime --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$staged_output"
else
    /usr/bin/codesign --force --sign - "$staged_output"
fi
/bin/cp "$staged_output" "$output"
