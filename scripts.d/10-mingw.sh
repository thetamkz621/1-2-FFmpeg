#!/bin/bash

SCRIPT_REPO="https://git.code.sf.net/p/mingw-w64/mingw-w64.git"
SCRIPT_COMMIT="57b595039040eaa15bece85b7cc71d952281b269"

ffbuild_depends() {
    return 0
}

ffbuild_enabled() {
    [[ $TARGET == win* ]] || return -1
    return 0
}

ffbuild_dockerdl() {
    echo "retry-tool sh -c \"rm -rf mingw && git clone '$SCRIPT_REPO' mingw\" && cd mingw && git checkout \"$SCRIPT_COMMIT\""
}

# Upstream builds these three parts into /opt/mingw and copies the result into
# the container root. Natively there is no image layer to copy from: install
# them straight into the compiler's sysroot, which is where later stages look
# for headers and libraries. The sysroot lives inside the ctng toolchain
# (.buildtools/ctng/<target>), so nothing is written outside the repository.
ffbuild_dockerbuild() {
    if [[ -z "${COMPILER_SYSROOT:-}" ]]; then
        COMPILER_SYSROOT="$("$CC" -print-sysroot 2>/dev/null)/usr/${FFBUILD_TOOLCHAIN}"
    fi
    if [[ ! -d "$COMPILER_SYSROOT" ]]; then
        echo "10-mingw: compiler sysroot '$COMPILER_SYSROOT' not found" >&2
        echo "           a ctng toolchain is required for $TARGET" >&2
        return 1
    fi

    unset CC CXX LD AR CPP LIBS CCAS
    unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS CCASFLAGS
    unset PKG_CONFIG_LIBDIR

    ###
    ### mingw-w64-headers
    ###
    (
        cd mingw-w64-headers

        # When the sysroot's include/ is a symlink, install into its target so
        # the headers land in the real tree instead of beside the link.
        local prefix="$COMPILER_SYSROOT"
        if [[ -L "$COMPILER_SYSROOT/include" ]]; then
            prefix="$(readlink -f "$COMPILER_SYSROOT/include")/.."
        fi

        local myconf=(
            --prefix="$prefix"
            --host="$FFBUILD_TOOLCHAIN"
            --with-default-win32-winnt="0x601"
            --with-default-msvcrt=ucrt
            --enable-idl
            --enable-sdk=all
        )

        ./configure "${myconf[@]}"
        make -j"$(nproc)"
        make install
    )

    ###
    ### mingw-w64-crt
    ###
    (
        cd mingw-w64-crt

        local myconf=(
            --prefix="$COMPILER_SYSROOT"
            --host="$FFBUILD_TOOLCHAIN"
            --with-default-msvcrt=ucrt
            --enable-wildcard
        )

        case $TARGET in
        *arm64)
            myconf+=(
                --disable-lib32
                --disable-lib64
                --enable-libarm64
            )
            ;;
        *arm32)
            myconf+=(
                --disable-lib32
                --disable-lib64
                --enable-libarm32
            )
            ;;
        *64)
            myconf+=(
                --disable-lib32
                --enable-lib64
            )
            ;;
        *32)
            myconf+=(
                --enable-lib32
                --disable-lib64
            )
            ;;
        esac

        ./configure "${myconf[@]}"
        make -j"$(nproc)"
        make install
    )

    ###
    ### mingw-w64-libraries/winpthreads
    ###
    (
        cd mingw-w64-libraries/winpthreads

        local myconf=(
            --prefix="$COMPILER_SYSROOT"
            --host="$FFBUILD_TOOLCHAIN"
            --with-pic
            --disable-shared
            --enable-static
        )

        ./configure "${myconf[@]}"
        make -j"$(nproc)"
        make install
    )
}

ffbuild_configure() {
    echo --disable-w32threads --enable-pthreads
}
