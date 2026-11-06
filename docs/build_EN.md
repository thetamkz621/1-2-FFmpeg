# Building

[简体中文](build.md) | English

```bash
./build.sh <target> <variant> [addin [addin] [addin] ...]

./build.sh linux64 gpl
./build.sh linux64 lgpl 8.1
./build.sh linux64 gpl-shared debug
```

Targets, variants, and addins are listed in the [README](../README_EN.md#targets-variants-and-addins).

Before building, `native/download.sh --needed <target> <variant>` runs automatically to fetch the required sources; set `FFBUILD_SKIP_DOWNLOAD=1` to skip this step (reusing the existing cache). `FFBUILD_FFMPEG_ONLY=1` also skips it.

## Targets

| Target | Toolchain | Notes |
|---|---|---|
| `linux64` | host `gcc` / `clang`, or `ctng` | native or same-architecture cross build |
| `win64` | `ctng` only | requires wine; `build.sh` exits early without wine or ctng |
| `win32` | `ctng` only | requires a wine build that can run 32-bit programs; `build.sh` exits early when the preflight check fails |

```bash
# linux64 with the host toolchain
./build.sh linux64 gpl-shared 9.0

# linux64 with crosstool-ng (glibc 2.28 baseline)
./native/setup.sh --install --with-ctng
FFBUILD_TOOLCHAIN_MODE=ctng ./build.sh linux64 gpl-shared 9.0

# win64
./native/setup.sh --install --with-ctng --ctng-target win64
FFBUILD_TOOLCHAIN_MODE=ctng ./build.sh win64 gpl-shared 9.0

# win32
./native/setup.sh --install --with-ctng --ctng-target win32
FFBUILD_TOOLCHAIN_MODE=ctng ./build.sh win32 gpl-shared 9.0
```

The target is selected by the first argument to `build.sh`; when building a toolchain, pass the same target to `setup.sh --ctng-target`.

## Compiler and toolchain

| Variable | Meaning |
|---|---|
| `FFBUILD_TOOLCHAIN_MODE` | `host` (default; probes `cc` → `gcc` → `clang`) / `clang` / `gcc` / `ctng` |
| `FFBUILD_CC` `FFBUILD_CXX` `FFBUILD_LD` `FFBUILD_AR` … | per-tool overrides (or use `CC=` / `CXX=`, among others) |
| `FFBUILD_TOOLCHAIN_TRIPLE` | override the `--host` triple passed to each stage |
| `FFBUILD_CTNG_ROOT` | crosstool-ng toolchain location, default `.buildtools/ctng/<target>` (unaffected by `FFBUILD_CLEAN`) |

`clang` / `gcc` only set the defaults for the host toolchain. `ctng` requires running `./native/setup.sh --with-ctng --ctng-target <target>` for that target first.

> The ctng toolchain lives in `.buildtools/ctng/<target>`; the initial linux64 build compiles glibc and GCC, while win64 compiles mingw-w64 and GCC.  
> Pruning runs before dependencies are built, so `soxr` and `vidstab` are compiled serially; host `gcc` and `clang` builds are unaffected.  
> meson stages for win64 run target binaries through wine; without wine, `build.sh` exits before any dependency is built.

## Compiler flags

| Variable | Semantics |
|---|---|
| `FFBUILD_CFLAGS` / `FFBUILD_CXXFLAGS` / `FFBUILD_LDFLAGS` / `FFBUILD_LDEXEFLAGS` | **replace** the built-in defaults |
| `FFBUILD_EXTRA_CFLAGS` / `FFBUILD_EXTRA_CXXFLAGS` / `FFBUILD_EXTRA_LDFLAGS` / `FFBUILD_EXTRA_LDEXEFLAGS` | **append** to the effective values |
| `FFBUILD_EXTRA_STAGE_CFLAGS` / `FFBUILD_EXTRA_STAGE_CXXFLAGS` / `FFBUILD_EXTRA_STAGE_LDFLAGS` | append to the per-stage flags |
| `FFBUILD_EXTRA_LIBS` | libraries appended to the FFmpeg link command |

> When `FFBUILD_CFLAGS` or a related variable replaces the defaults, the built-in `-I$FFBUILD_PREFIX/include` is replaced as well; use `FFBUILD_EXTRA_*` to add flags instead.

## Build controls

| Variable | Meaning |
|---|---|
| `FFBUILD_CLEAN=1` | remove `FFBUILD_ROOT` before building (**⚠️ use with caution**) |
| `FFBUILD_FORCE=1` | rebuild every stage, ignoring resume state |
| `FFBUILD_DEPS_ONLY=1` | build dependencies only; do not build FFmpeg |
| `FFBUILD_FFMPEG_ONLY=1` | skip dependencies and reuse the existing prefix |
| `FFBUILD_SKIP_DOWNLOAD=1` | do not refresh the download cache |
| `FFBUILD_JOBS=<N>` | number of parallel jobs, default `nproc` |
| `FFBUILD_ROOT=<path>` | build root, default `<repo>/ffbuild`; the path must not contain `.` |
| `FFBUILD_BUILD_DATE=YYYYMMDD` | pin the date in the artifact name |
| `FFBUILD_SKIP_STAGES=a,b` | skip the listed stages, separated by commas or spaces (for example, `rav1e` and `librsvg` when Rust is unavailable) |
| `FFBUILD_EXTRA_VERSION=<str>` | passed to FFmpeg as `--extra-version`, default `YYYYMMDD`; affects `ffmpeg -version` output, not the artifact name |

The build root is stamped with `<target>:<compiler>`. A host build and a ctng build, or two different targets, cannot share one root; use a separate `FFBUILD_ROOT` or set `FFBUILD_CLEAN=1` when switching.

## FFmpeg source

`FFMPEG_REPO` selects the FFmpeg source tree; the default is `https://github.com/FFmpeg/FFmpeg.git`.

| Value | Behavior |
|---|---|
| Remote git URL | Clone the branch selected by the version addin (`master` by default); `GIT_BRANCH_OVERRIDE` overrides it |
| Local git repository | Clone it and check out its current `HEAD`; `GIT_BRANCH_OVERRIDE` selects a branch or commit instead |
| Local plain directory | Copy it into the build root; it must contain `configure` |
| Nonexistent path | Fail with an error |

- The source is always copied or cloned to `$FFBUILD_ROOT/ffmpeg`; the original is never modified.
- Uncommitted changes in a local git repository are not part of the build. To include them, copy the working tree to a plain directory and point `FFMPEG_REPO` at the copy.
- When the source root contains `RELEASE`, its major and minor version must match the version addin (`8.1` for `RELEASE` `8.1.1`); otherwise the build stops.
- `GIT_BRANCH_OVERRIDE` has no effect on a local plain directory.
- A source tree with neither `RELEASE` nor `.git` makes `ffbuild/version.sh` record `N` as the artifact version.

## Network

| Variable | Meaning |
|---|---|
| `FFBUILD_PROXY` | override the proxy for all protocols; when unset, the current shell's `http_proxy` / `https_proxy` / `all_proxy` (and their uppercase forms) are inherited; an empty value disables the proxy |
| `FFBUILD_NO_PROXY` | overrides `no_proxy`; empty by default, adds nothing |

The full variable list is in the comment block at the top of `native/env.sh`. To inspect the resolved configuration (bash only):

```bash
source native/env.sh && ffbuild_env_dump
```

## Layout and artifacts

| Path | Contents |
|---|---|
| `ffbuild/prefix` | dependency install prefix (where `PKG_CONFIG_LIBDIR` points) |
| `ffbuild/work` | unpack and build directories for each stage |
| `ffbuild/log` | per-stage logs |
| `ffbuild/state` | resume state |
| `ffbuild/destdir` | per-stage `DESTDIR`, merged into `prefix` when the stage finishes |
| `ffbuild/pkgroot` | packaging scratch directory |
| `.buildtools/ctng/<target>` | crosstool-ng toolchain (`ctng` mode) |
| `.buildtools/` | managed build tools, venv, Rust, opam |
| `.cache/downloads/` | source cache |
| `artifacts/` | build artifacts |

Artifact name:

```
artifacts/ffmpeg-<version>-<target>-<variant>[-<addins>]-<compiler-or-toolchain>-<date>.tar.xz
```

> This field is `gcc` or `clang` for host builds, and `ctng` in ctng mode.  
> Windows artifacts contain `bin/*.exe` and `bin/*.dll`, with import libraries under `lib/`; they use the UCRT and do not depend on libgcc, libstdc++, or winpthread DLLs.

## Cache and retries

`.cache/downloads/` is content-addressed: `<stage>_<hash>.tar.xz` with a `<stage>.tar.xz` symlink.

Common commands:

```bash
./native/download.sh --needed linux64 gpl   # fetch only the sources required by this target
./native/download.sh hashonly               # print the cache key
```

On a slow network, adjust the following parameters (used by `util/bin/retry-tool`):

| Variable | Meaning |
|---|---|
| `RETRY_MAX` | maximum number of attempts, default `10` |
| `RETRY_TIMEOUT` | initial timeout in seconds, default `120` |
| `RETRY_TIMEOUT_INC` | backoff increment in seconds, default `60` |
| `RETRY_SLEEP_MAX` | maximum backoff in seconds, default `90` |

These settings apply to every fetch: `setup.sh` (opam, Implib.so, rustup, crosstool-ng and managed build-tool sources), `download.sh`, `build.sh` and `buildtools.sh` all download through `retry-tool`.

Unless overridden, `download.sh` uses a 600-second timeout and 8 attempts, while `setup.sh` and `buildtools.sh` use a 600-second timeout. HTTP 4xx responses are retried like any other failure; set `RETRY_MAX=1` temporarily when debugging a mirror URL.
