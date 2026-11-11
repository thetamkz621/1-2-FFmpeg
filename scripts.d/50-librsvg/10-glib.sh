#!/bin/bash

SCRIPT_REPO="https://github.com/GNOME/glib.git"
SCRIPT_COMMIT="5a124d1e66a6c2dc56989303b4d6d4781c2952ed"

ffbuild_depends() {
    echo base
    echo zlib
    echo libiconv
    echo pcre2
    echo libffi
}

ffbuild_enabled() {
    return 0
}

ffbuild_dockerdl() {
    default_dl .
    echo "git submodule update --init --recursive --depth=1"
    echo "meson subprojects download proxy-libintl"
}

ffbuild_dockerbuild() {
    # A previous run of this stage installs proxy-libintl into the shared
    # prefix. On the next run dependency('intl') resolves against those files
    # instead of the subproject: the header declares the functions dllimport,
    # the probe for ngettext fails to link, and meson returns the cached
    # external dependency even with allow_fallback, so the assert on an
    # internal dependency fires. Remove both so a rebuild resolves intl from
    # source; ninja install writes them back, and glib-2.0.pc keeps
    # advertising -lintl for downstream stages.
    rm -f "$FFBUILD_PREFIX/include/libintl.h" "$FFBUILD_PREFIX/lib/libintl.a"

    # Skip auto-initialization of GIO appinfo. It's relatively expensive and automatically done on demand when needed.
    sed -zi 's/[^\n]*gio_win32_appinfo_init[^\n]*\n//g; t; q1' gio/giomodule.c

    mkdir build && cd build

    local myconf=(
        --prefix="$FFBUILD_PREFIX"
        --buildtype=release
        --default-library=static
        --wrap-mode=nodownload
        -Dtests=false
        -Dinstalled_tests=false
        -Dglib_debug=disabled
        -Dnls=disabled
        -Dintrospection=disabled
        -Ddocumentation=false
        -Dman-pages=disabled
        -Dsysprof=disabled
        -Dlibelf=disabled
        -Dmultiarch=false
        -Dbsymbolic_functions=false
        -Dselinux=disabled
        -Dlibmount=disabled
        -Ddtrace=disabled
        -Dsystemtap=disabled
    )

    if [[ $TARGET == win* || $TARGET == linux* ]]; then
        myconf+=(
            --cross-file="$FFBUILD_MESON_CROSS_FILE"
        )
    else
        echo "Unknown target"
        return -1
    fi

    meson setup "${myconf[@]}" ..
    ninja -j$(nproc)
    DESTDIR="$FFBUILD_DESTDIR" ninja install

    rm -rf "$FFBUILD_DESTPREFIX"/share
}
