#!/bin/bash

package_variant() {
    IN="$1"
    OUT="$2"

    mkdir -p "$OUT"/bin
    cp "$IN"/bin/* "$OUT"/bin

    mkdir -p "$OUT"/lib
    cp -a "$IN"/lib/*.so* "$OUT"/lib

    mkdir -p "$OUT"/lib/pkgconfig
    cp -a "$IN"/lib/pkgconfig/*.pc "$OUT"/lib/pkgconfig
    sed -i \
        -e 's|^prefix=.*|prefix=${pcfiledir}/../..|' \
        -e 's|/ffbuild/prefix|${prefix}|' \
        -e '/Libs.private:/d' \
        "$OUT"/lib/pkgconfig/*.pc

    mkdir -p "$OUT"/include
    cp -r "$IN"/include/* "$OUT"/include

    # Page types are configure-time decisions: man pages need pod2man, HTML
    # needs makeinfo or texi2html. Copy whichever the build produced.
    if [[ -d "$IN/share/doc/ffmpeg" ]]; then
        mkdir -p "$OUT"/doc
        cp -r "$IN"/share/doc/ffmpeg/* "$OUT"/doc
    fi

    if [[ -d "$IN/share/man" ]]; then
        mkdir -p "$OUT"/man
        cp -r "$IN"/share/man/* "$OUT"/man
    fi

    mkdir -p "$OUT/presets"
    cp "$IN"/share/ffmpeg/*.ffpreset "$OUT"/presets
}
