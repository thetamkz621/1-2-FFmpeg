#!/bin/bash

SCRIPT_REPO="https://github.com/google/shaderc.git"
SCRIPT_COMMIT="2737994b552137a85545f956e303d620e6ff232c"

ffbuild_enabled() {
    (( $(ffbuild_ffver) > 404 )) || return -1
    return 0
}

ffbuild_dockerdl() {
    default_dl .
    echo "./utils/git-sync-deps || exit $?"
}

ffbuild_dockerbuild() {
    mkdir build && cd build

    cmake -GNinja -DCMAKE_TOOLCHAIN_FILE="$FFBUILD_CMAKE_TOOLCHAIN" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$FFBUILD_PREFIX" \
        -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON -DSHADERC_SKIP_COPYRIGHT_CHECK=ON \
        -DENABLE_EXCEPTIONS=ON -DENABLE_GLSLANG_BINARIES=OFF -DSPIRV_SKIP_EXECUTABLES=ON \
        -DSPIRV_TOOLS_BUILD_STATIC=ON -DBUILD_SHARED_LIBS=OFF ..
    ninja -j$(nproc)

    # Keep the staging tree inside the build dir: /tmp may be a different
    # filesystem (tmpfs), where the hard-link merge below fails with EXDEV.
    export DESTDIR="$PWD/staging$FFBUILD_DESTDIR"
    ninja install

    if [[ $TARGET == win* ]]; then
        rm -r "${DESTDIR}${FFBUILD_PREFIX}"/bin "${DESTDIR}${FFBUILD_PREFIX}"/lib/*.dll.a
    elif [[ $TARGET == linux* ]]; then
        rm -r "${DESTDIR}${FFBUILD_PREFIX}"/bin "${DESTDIR}${FFBUILD_PREFIX}"/lib/*.so*
    else
        echo "Unknown target"
        return -1
    fi

    cp -al "$DESTDIR"/. "$FFBUILD_DESTDIR"
    rm -rf "$DESTDIR"
    unset DESTDIR

    # for some reason, this does not get installed...
    cp libshaderc_util/libshaderc_util.a "$FFBUILD_DESTPREFIX"/lib

    echo "Libs: -lstdc++" >> "$FFBUILD_DESTPREFIX"/lib/pkgconfig/shaderc_combined.pc
    echo "Libs: -lstdc++" >> "$FFBUILD_DESTPREFIX"/lib/pkgconfig/shaderc_static.pc

    cp "$FFBUILD_DESTPREFIX"/lib/pkgconfig/{shaderc_combined,shaderc}.pc

    mkdir ../native_build && cd ../native_build

    unset CC CXX CFLAGS CXXFLAGS LD LDFLAGS AR RANLIB NM DLLTOOL PKG_CONFIG_LIBDIR
    cmake -GNinja -DCMAKE_BUILD_TYPE=Release \
        -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON -DSHADERC_SKIP_COPYRIGHT_CHECK=ON \
        -DENABLE_EXCEPTIONS=ON -DSPIRV_TOOLS_BUILD_STATIC=ON -DBUILD_SHARED_LIBS=OFF ..
    ninja -j$(nproc) glslc/glslc

    # Upstream parks the binary at /opt/glslc for the image's COPY step. There is
    # no image here: glslc is a host build tool, so native/env.sh names its path
    # in FFBUILD_GLSLc ($FFBUILD_ROOT/bin/glslc, a directory already on PATH).
    # No default: a fallback would silently write outside the build root again.
    # rm -f first: a build root prepared by an older version still has a
    # dangling bin/glslc symlink, and cp would write through it.
    if [[ -z "${FFBUILD_GLSLc:-}" ]]; then
        echo "50-shaderc: FFBUILD_GLSLc is not set (it comes from native/env.sh)" >&2
        return 1
    fi
    mkdir -p "$(dirname "$FFBUILD_GLSLc")"
    rm -f "$FFBUILD_GLSLc"
    cp glslc/glslc "$FFBUILD_GLSLc"
}

ffbuild_configure() {
    (( $(ffbuild_ffver) < 900 )) || return 0
    echo --enable-libshaderc
}

ffbuild_unconfigure() {
    (( $(ffbuild_ffver) > 404 )) || return 0
    (( $(ffbuild_ffver) < 900 )) || return 0
    echo --disable-libshaderc
}
