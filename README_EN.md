# 1-2-FFmpeg

[简体中文](README.md) | English

> [!NOTE]
> Heavy usage of AI agent during modification.

A Docker-free fork of [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds):
build FFmpeg and its dependencies directly on a Linux x86_64 host.

Currently, only the `linux64` target is supported. Upstream's other targets are still present but untested.

## Documentation

| Document | Contents |
|---|---|
| [Setting up the build host](docs/setup_EN.md) | prerequisites, per-distribution packages, every `setup.sh` option, reading `--check` |
| [Building](docs/build_EN.md) | compiler and toolchain modes, build controls, directory layout, source cache |
| [Troubleshooting](docs/troubleshooting_EN.md) | C++23, LLVMgold, OCaml num, permission errors, weak dependencies |

## How to make a build

### Prerequisites

An x86_64 Linux host with `bash`, `git` and python 3.10 or newer. `setup.sh` installs the
distro packages (apt hosts directly; other hosts only print the command unless you pass
`--install`) and builds the 24 managed tools, the Python venv and the Rust toolchain under
`.buildtools/`.

> Building needs no root; deleting the repository removes every build artifact (the distro
> packages installed by `setup.sh` stay in the system).
> Per-distribution packages, every option and troubleshooting live in
> [docs/setup_EN.md](docs/setup_EN.md).

> [!IMPORTANT]
> Requires compiler with C++23 support (like GCC 12 or higher).
> > Dependency `openal-soft` demands for range constructor for std::string_view `std::string_view`
> 
> Requires LLVM 15 or higher.
> > LLVMgold plugin version (for binutils) must be 15 or higher.  
> > Otherwise `ar` cannot index Rust bitcode symbols (From dependency `librsvg`).

### Quick start

```bash
./native/setup.sh --check   # read-only: what is missing and how to install it
./native/setup.sh           # apt hosts install; other hosts print the command (add --install)
./build.sh linux64 gpl      # fetches the sources, then builds
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
* `4.3`/`4.4`/`5.0`/`5.1`/`6.0`/`6.1`/`7.0`/`7.1`/`8.0`/`8.1`/`9.0` to build from the respective release branch instead of master.
* `debug` to not strip debug symbols from the binaries. This increases the output size by about 250MB.
* `lto` build all dependencies and ffmpeg with -flto=auto (HIGHLY EXPERIMENTAL, broken for Windows, sometimes works for Linux)

### Compiler

```bash
FFBUILD_TOOLCHAIN_MODE=clang ./build.sh linux64 gpl
FFBUILD_TOOLCHAIN_MODE=gcc   ./build.sh linux64 gpl
FFBUILD_TOOLCHAIN_MODE=ctng  ./build.sh linux64 gpl   # crosstool-ng toolchain (untested)
```

> [!NOTE]
> `host` (default) probes `cc`, then `gcc`, then `clang`, with `CXX` following the same family.
> `clang` / `gcc` only set the host toolchain's defaults, and `ctng` uses a locally built
> crosstool-ng toolchain — untested so far — and needs `./native/setup.sh --with-ctng` first.
> `FFBUILD_CC` / `CC` (and `CXX`/`LD`/`AR`/...) override the choice, including versioned
> compilers such as `FFBUILD_CC=gcc-12 FFBUILD_CXX=g++-12`. Extra flags:
> `FFBUILD_EXTRA_CFLAGS`, `FFBUILD_EXTRA_LDFLAGS`. See the resolved configuration with
> `source native/env.sh && ffbuild_env_dump`; the full variable list is documented at the
> top of `native/env.sh` and in [docs/build_EN.md](docs/build_EN.md).

### Set proxy

Proxy settings are inherited from the shell (`http_proxy` / `https_proxy` / `all_proxy`).

```bash
FFBUILD_PROXY=http://host:port ./native/download.sh   # override all protocols
FFBUILD_PROXY= ./native/download.sh                   # ignore the shell's proxy
```

> `svn` ignores these variables (it only reads `~/.subversion/servers`), so the lame and xvid
> stages always connect directly.

## Project layout

```
ffbuild/{prefix,destdir,work,log,state,pkgroot}   build root (FFBUILD_ROOT)
.buildtools/                                     managed build tools, venv, rust; not tracked by git
.cache/downloads/                                dependency source cache
artifacts/                                       build output
```

> `FFBUILD_ROOT` must not contain a dot (upstream's libxcb/libglvnd path handling breaks on
> it); artifacts match the host glibc, ~~use `FFBUILD_TOOLCHAIN_MODE=ctng` for a glibc 2.28
> baseline~~.

## License

Same as upstream [`LICENSE`](LICENSE)
