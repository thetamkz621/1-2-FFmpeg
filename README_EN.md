# 1-2-FFmpeg

[简体中文](README.md) | English

> [!NOTE]
> Extensive use of AI agents during development.

A Docker-free fork of [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds): build FFmpeg and its dependencies directly on a Linux x86_64 host.

Currently, only the `linux64` target is supported. Upstream's other targets remain present but are untested.

## Documentation

| Document | Contents |
|---|---|
| [Setting up the build environment](docs/setup_EN.md) | prerequisites, distribution packages, all `setup.sh` options, `--check` output |
| [Building](docs/build_EN.md) | compiler and toolchain modes, build controls, directory layout, source cache |
| [Troubleshooting](docs/troubleshooting_EN.md) | C++23, LLVMgold, OCaml num, permission errors, weak dependencies |

## How to make a build

### Prerequisites

An x86_64 Linux host is required. `setup.sh` handles distribution packages (by default it prints only the install command for the current host; pass `--install` to install them) and builds 24 managed build tools and the Python venv under `.buildtools/`, preparing the Rust toolchain and cargo-c as needed.

> [!IMPORTANT]
> Some dependencies have the following minimum version requirements. Adjust the installation commands as needed so that the installed packages meet them.
> | Item | Minimum requirement | Reason |
> |---|---|---|
> | Python | 3.10 | create the venv, run meson |
> | C++ compiler | C++23 support (for example, GCC 12) | `openal-soft` requires `std::string_view` range construction |
> | LLVM / LLVMgold | 15 | index Rust bitcode from `librsvg` with `ar` |

> Building requires no root privileges. Deleting the repository removes all build artifacts; distribution packages installed by `setup.sh` remain on the system.  
> Distribution package names, all options, and troubleshooting are documented in [docs/setup_EN.md](docs/setup_EN.md).

### Quick start

```bash
./native/setup.sh --check   # read-only diagnosis: missing items and install commands
./native/setup.sh --install # install packages and set up the build environment
# ./build.sh <target> <variant> [addin [addin] [addin] ...]
# for example:
./build.sh linux64 gpl      # fetch the sources and build
```

On success, the artifact is written to `artifacts/ffmpeg-<version>-<target>-<variant>[-<addins>]-<compiler-or-toolchain>-<date>.tar.xz`.

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
* `4.3`/`4.4`/`5.0`/`5.1`/`6.0`/`6.1`/`7.0`/`7.1`/`8.0`/`8.1`/`9.0` to build from the respective release branch instead of master.
* `debug` to not strip debug symbols from the binaries. This increases the output size by about 250 MB.
* `lto` build all dependencies and FFmpeg with `-flto=auto` (HIGHLY EXPERIMENTAL, broken for Windows, sometimes works for Linux)

### Compiler

```bash
FFBUILD_TOOLCHAIN_MODE=clang ./build.sh linux64 gpl
FFBUILD_TOOLCHAIN_MODE=gcc   ./build.sh linux64 gpl
FFBUILD_TOOLCHAIN_MODE=ctng  ./build.sh linux64 gpl   # crosstool-ng toolchain
```

> [!NOTE]
> `host` (the default) probes `cc`, then `gcc`, then `clang`; `CXX` follows the same compiler family. `clang` / `gcc` only change the default binary names for the host toolchain. `ctng` uses a locally built crosstool-ng toolchain and requires running `./native/setup.sh --with-ctng` first; the toolchain lives in `.buildtools/ctng`, and the initial build compiles glibc and GCC.  
> `FFBUILD_CC` / `CC` (and `CXX`, `LD`, `AR`, …) override this selection, including versioned compilers such as `FFBUILD_CC=gcc-12 FFBUILD_CXX=g++-12`.  
> Additional compiler flags can be supplied through `FFBUILD_EXTRA_CFLAGS` and `FFBUILD_EXTRA_LDFLAGS`.  
> To inspect the resolved configuration, run `source native/env.sh && ffbuild_env_dump`.  
> Common variables are documented in [docs/build_EN.md](docs/build_EN.md); the full list is in the comment block at the top of `native/env.sh`.

### Proxy

Proxy settings are inherited from the shell (`http_proxy` / `https_proxy` / `all_proxy`).

```bash
FFBUILD_PROXY=http://host:port ./native/download.sh   # override all protocols
FFBUILD_PROXY= ./native/download.sh                   # ignore the proxy configured in the shell
```

> `svn` does not read these variables (it reads only `~/.subversion/servers`), so the `lame` and `xvid` stages always connect directly.

## Project layout

```
ffbuild/{prefix,destdir,work,log,state,pkgroot}   build root (FFBUILD_ROOT)
.buildtools/                                      managed build tools, venv, Rust; not tracked by Git
.cache/downloads/                                 dependency source cache
artifacts/                                        build artifacts
```

> `FFBUILD_ROOT` must not contain a period (this breaks path handling in `libxcb`/`libglvnd`).  
> Artifacts match the host glibc; for a glibc 2.28 baseline, use `FFBUILD_TOOLCHAIN_MODE=ctng` (run `./native/setup.sh --with-ctng` first).

## License

Same as the upstream [`LICENSE`](LICENSE).
