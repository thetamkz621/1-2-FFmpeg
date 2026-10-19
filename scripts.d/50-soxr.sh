#!/bin/bash

SCRIPT_REPO="https://git.code.sf.net/p/soxr/code"
SCRIPT_COMMIT="945b592b70470e29f917f4de89b4281fbbd540c0"

ffbuild_enabled() {
    return 0
}

ffbuild_dockerstage() {
    to_df "RUN --mount=src=${SELF},dst=/stage.sh --mount=src=${SELFCACHE},dst=/cache.tar.xz --mount=src=patches/soxr,dst=/patches run_stage /stage.sh"
}

ffbuild_dockerbuild() {
    for patch in "${FFBUILD_PATCHES:-/patches}"/*.patch; do
        [[ -e "$patch" ]] || continue
        echo "Applying $(basename "$patch")"
        patch -p1 --forward --silent < "$patch"
    done

    sed -i 's/VERSION 3.1 /VERSION 3.1...3.10 /g' CMakeLists.txt

    # Short-circuit the check to generate a .pc file. We always want it.
    sed -i 's/NOT WIN32/1/g' src/CMakeLists.txt

    mkdir build && cd build

    cmake -DCMAKE_TOOLCHAIN_FILE="$FFBUILD_CMAKE_TOOLCHAIN" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$FFBUILD_PREFIX" \
        -DWITH_OPENMP="$([[ $TARGET == winarm64 ]] && echo OFF || echo ON)" \
        -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_SHARED_LIBS=OFF \
        ..
    make -j$(nproc)
    make install DESTDIR="$FFBUILD_DESTDIR"
}

ffbuild_configure() {
    echo --enable-libsoxr
}

ffbuild_unconfigure() {
    echo --disable-libsoxr
}

ffbuild_ldflags() {
    echo -pthread
}

ffbuild_libs() {
    # FFmpeg probes libsoxr with a bare -lsoxr (no pkg-config), so the OpenMP
    # runtime has to arrive through --extra-libs as well.  Reuse what CMake
    # recorded in soxr.pc instead of hard-coding GCC's -lgomp: clang lowers
    # OpenMP to the kmp ABI and links libomp.
    local pc="${FFBUILD_PREFIX:-}/lib/pkgconfig/soxr.pc" priv
    [[ -f "$pc" ]] || return 0
    priv="$(sed -n 's/^Libs\.private:[[:space:]]*//p' "$pc")"
    [[ -n "$priv" ]] && echo "$priv"
    return 0
}
