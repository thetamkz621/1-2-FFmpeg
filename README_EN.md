# 1-2-FFmpeg

[简体中文](README.md) | English

> [!NOTE]
> Heavy usage of AI agent during modification.

A Docker-free fork of [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds):
build FFmpeg and its dependencies directly on a Linux x86_64 host.

Currently, only the `linux64` target is supported. Upstream's other targets are still present but untested.

## How to make a build

### Prerequisites

Debian/Ubuntu-style x86_64 host with `bash`, `git` and `sudo` (or root). `setup.sh` takes only
the base toolchain from apt (gcc/g++, clang, python3, git and the usual CLI tools) and builds the
rest — autoconf, automake, cmake, nasm, yasm, gettext and the Python venv — under `.buildtools/`.

`./native/setup.sh --check` prints the required and optional tool list without changing anything.

### Preparation

```bash
./native/setup.sh          # install build prerequisites, print the resolved config
./native/setup.sh --check
./native/download.sh       # fetch dependency sources (content-addressed cache)
```

### Start building

```bash
./build.sh target variant [addin [addin] [addin] ...]
```

On success, the resulting archive will be in `artifacts/ffmpeg-<version>-<target>-<variant>[-<addins>]-<compiler>-<date>.tar.xz`.

### Targets, Variants and Addins

Available targets:
* ~~`win64` (x86_64 Windows)~~
* ~~`win32` (x86 Windows)~~
* `linux64` (x86_64 Linux)
* ~~`linuxarm64` (arm64 (aarch64) Linux)~~

~~The linuxarm64 target will not build some dependencies due to lack of arm64 (aarch64) architecture support or cross-compiling restrictions.~~

* ~~`davs2` and `xavs2`: aarch64 support is broken.~~
* ~~`libmfx` and `libva`: Library for Intel QSV, so there is no aarch64 support.~~

Available variants:
* `gpl` Includes all dependencies, even those that require full GPL instead of just LGPL.
* `lgpl` Lacking libraries that are GPL-only. Most prominently libx264 and libx265.
* `nonfree` Includes fdk-aac in addition to all the dependencies of the gpl variant.
* `gpl-shared` Same as gpl, but comes with the libav* family of shared libs instead of pure static executables.
* `lgpl-shared` Same again, but with the lgpl set of dependencies.
* `nonfree-shared` Same again, but with the nonfree set of dependencies.

All of those can be optionally combined with any combination of addins:
* `4.4`/`5.0`/`5.1`/`6.0`/`6.1`/`7.0`/`7.1`/`8.0`/`8.1`/`9.0` to build from the respective release branch instead of master.
* `debug` to not strip debug symbols from the binaries. This increases the output size by about 250MB.
* `lto` build all dependencies and ffmpeg with -flto=auto (HIGHLY EXPERIMENTAL, broken for Windows, sometimes works for Linux)

### Compiler

```bash
FFBUILD_TOOLCHAIN_MODE=clang ./build.sh linux64 gpl
FFBUILD_TOOLCHAIN_MODE=gcc   ./build.sh linux64 gpl
FFBUILD_TOOLCHAIN_MODE=ctng  ./build.sh linux64 gpl   # glibc 2.28 baseline (unverified)
```

> [!NOTE]
> `host` (default) probes `cc`, then `gcc`, then `clang`, with `CXX` following the same family.
> `clang` / `gcc` only set the host toolchain's defaults, and `ctng` uses a locally built
> crosstool-ng toolchain — untested so far — and needs `./native/setup.sh --with-ctng` first.
> `FFBUILD_CC` / `CC` (and `CXX`/`LD`/`AR`/...) override the choice. Extra flags:
> `FFBUILD_EXTRA_CFLAGS`, `FFBUILD_EXTRA_LDFLAGS`. See the resolved configuration with
> `source native/env.sh && ffbuild_env_dump`; the full variable list is documented at the
> top of `native/env.sh`.

### Set proxy

Proxy settings are inherited from the shell (`http_proxy` / `https_proxy` / `all_proxy`).

```bash
FFBUILD_PROXY=http://host:port ./native/download.sh   # override all protocols
FFBUILD_PROXY= ./native/download.sh                   # ignore the shell's proxy
```

> [!IMPORTANT]
> - `FFBUILD_ROOT` must not contain a dot (upstream's libxcb/libglvnd path handling breaks on it).
> - Artifacts match the host glibc; ~~use `FFBUILD_TOOLCHAIN_MODE=ctng` for a glibc 2.28 baseline.~~
> - Building needs no root; deleting the repository removes every build artifact.

> `svn` ignores these variables (it only reads `~/.subversion/servers`), so the lame and xvid
> stages always connect directly.

## Project layout

```
ffbuild/{prefix,work,log,state,pkgroot}   build root (FFBUILD_ROOT)
.buildtools/                              managed build tools, not tracked by git
.cache/downloads/                         dependency source cache
artifacts/                                build output
```

## License

Same as upstream [`LICENSE`](LICENSE)
