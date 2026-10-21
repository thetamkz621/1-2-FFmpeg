#!/bin/bash

package_variant() {
    IN="$1"
    OUT="$2"

    mkdir -p "$OUT"/bin
    cp "$IN"/bin/* "$OUT"/bin

    # Documentation is optional at this point: ffmpeg only installs man pages when
    # texi2html was available at build time, and a missing share/man must not turn
    # a finished build into a packaging failure (the archive is still complete).
    if [[ -d "$IN/share/doc/ffmpeg" ]]; then
        mkdir -p "$OUT/doc"
        cp -r "$IN"/share/doc/ffmpeg/. "$OUT"/doc/
    fi

    if [[ -d "$IN/share/man" ]]; then
        mkdir -p "$OUT/man"
        cp -r "$IN"/share/man/. "$OUT"/man/
    fi

    if compgen -G "$IN/share/ffmpeg/*.ffpreset" >/dev/null; then
        mkdir -p "$OUT/presets"
        cp "$IN"/share/ffmpeg/*.ffpreset "$OUT/presets"
    fi
}
