#!/bin/bash

SCRIPT_REPO="https://gitlab.freedesktop.org/xorg/lib/libxtrans.git"
SCRIPT_COMMIT="79f6b0bfe2170496e8c37626043d009f4cd3f1e1"

ffbuild_enabled() {
    [[ $TARGET != linux* ]] && return -1
    return 0
}

ffbuild_dockerbuild() {
    autoreconf -i

    local myconf=(
        --prefix="$FFBUILD_PREFIX"
        --without-xmlto
        --without-fop
        --without-xsltproc
    )

    if [[ $TARGET == linux* ]]; then
        myconf+=(
            --host="$FFBUILD_TOOLCHAIN"
        )
    else
        echo "Unknown target"
        return -1
    fi

    ./configure "${myconf[@]}"
    make -j$(nproc)
    make install DESTDIR="$FFBUILD_DESTDIR"

    # No copy into /usr/share/aclocal: the macros are exported through
    # ACLOCAL_PATH ($FFBUILD_PREFIX/share/aclocal), which native/env.sh already
    # sets, so writing to the system acdir is unnecessary and needs root.
}
