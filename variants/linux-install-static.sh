#!/bin/bash

package_variant() {
    IN="$1"
    OUT="$2"

    mkdir -p "$OUT"/bin
    cp "$IN"/bin/* "$OUT"/bin

    # Page types are configure-time decisions: man pages need pod2man, HTML
    # needs makeinfo or texi2html. Copy whichever the build produced.
    if [[ -d "$IN/share/doc/ffmpeg" ]]; then
        mkdir -p "$OUT/doc"
        cp -r "$IN"/share/doc/ffmpeg/* "$OUT"/doc
    fi

    if [[ -d "$IN/share/man" ]]; then
        mkdir -p "$OUT/man"
        cp -r "$IN"/share/man/* "$OUT"/man
    fi

    mkdir -p "$OUT/presets"
    cp "$IN"/share/ffmpeg/*.ffpreset "$OUT"/presets
}
