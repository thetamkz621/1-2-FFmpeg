#!/bin/bash

SCRIPT_SKIP="1"

ffbuild_enabled() {
    (( $(ffbuild_ffver) > 404 )) || return -1
    return 0
}

# LOCAL DEVIATION from upstream FFmpeg-Builds:
#   upstream also emits a `COPY --link ... /opt/glslc /usr/bin/glslc` line in
#   both hooks below, i.e. it installs the host-side glslc binary into the
#   image. Natively 50-shaderc writes glslc to $FFBUILD_GLSLc and that
#   directory is already on PATH, so there is nothing to copy.
ffbuild_dockerlayer() {
    to_df "COPY --link --from=${SELFLAYER} \$FFBUILD_DESTPREFIX/. \$FFBUILD_PREFIX"
}

ffbuild_dockerfinal() {
    to_df "COPY --link --from=${PREVLAYER} \$FFBUILD_PREFIX/. \$FFBUILD_PREFIX"
}

ffbuild_dockerdl() {
    true
}

ffbuild_dockerbuild() {
    return 0
}
