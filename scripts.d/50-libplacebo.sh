#!/bin/bash

SCRIPT_REPO="https://code.videolan.org/videolan/libplacebo.git"
SCRIPT_COMMIT="275f7dea27924cdd34ab2e6c20e448b6bc4fab65"

ffbuild_depends() {
    echo base
    echo vulkan
    echo lcms2
    echo xxhash
}

ffbuild_enabled() {
    (( $(ffbuild_ffver) > 600 )) || return -1
    return 0
}

ffbuild_dockerdl() {
    default_dl .
    # git 2.36 起 submodule update 才支持 --filter；更老的 git（如 Ubuntu 22.04
    # 的 2.34）会打印用法并失败。
    local sm="git submodule update --init --recursive --depth=1"
    if git_version_ge 2.36; then
        sm+=" --filter=blob:none"
    fi
    echo "$sm"
}

ffbuild_dockerbuild() {
    mkdir build && cd build

    local myconf=(
        --prefix="$FFBUILD_PREFIX"
        --buildtype=release
        --default-library=static
        -Dvulkan=enabled
        -Dvk-proc-addr=enabled
        -Dvulkan-registry="$FFBUILD_PREFIX"/share/vulkan/registry/vk.xml
        -Dshaderc=enabled
        -Dglslang=disabled
        -Dlcms=enabled
        -Dxxhash=enabled
        -Ddemos=false
        -Dtests=false
        -Dbench=false
        -Dfuzz=false
    )

    if [[ $TARGET == win* ]]; then
        myconf+=(
            -Dd3d11=enabled
        )
    fi

    if [[ $TARGET == win* || $TARGET == linux* ]]; then
        myconf+=(
            --cross-file="$FFBUILD_MESON_CROSS_FILE"
        )
    else
        echo "Unknown target"
        return -1
    fi

    meson "${myconf[@]}" ..
    ninja -j$(nproc)
    DESTDIR="$FFBUILD_DESTDIR" ninja install

    echo "Libs.private: -lstdc++" >> "$FFBUILD_DESTPREFIX"/lib/pkgconfig/libplacebo.pc
}

ffbuild_configure() {
    echo --enable-libplacebo
}

ffbuild_unconfigure() {
    (( $(ffbuild_ffver) >= 500 )) || return 0
    echo --disable-libplacebo
}
