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

## Compiler and toolchain

| Variable | Meaning |
|---|---|
| `FFBUILD_TOOLCHAIN_MODE` | `host` (default; probes `cc` → `gcc` → `clang`) / `clang` / `gcc` / `ctng` |
| `FFBUILD_CC` `FFBUILD_CXX` `FFBUILD_LD` `FFBUILD_AR` … | per-tool overrides (or use `CC=` / `CXX=`, among others) |
| `FFBUILD_TOOLCHAIN_TRIPLE` | override the `--host` triple passed to each stage |
| `FFBUILD_CTNG_ROOT` | crosstool-ng toolchain location, default `$FFBUILD_ROOT/ctng` |

`clang` / `gcc` only set the defaults for the host toolchain. `ctng` requires running `./native/setup.sh --with-ctng` first. (**Currently untested.**)

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
| `ffbuild/ctng` | crosstool-ng toolchain (`ctng` mode) |
| `.buildtools/` | managed build tools, venv, Rust, opam |
| `.cache/downloads/` | source cache |
| `artifacts/` | build artifacts |

Artifact name:

```
artifacts/ffmpeg-<version>-<target>-<variant>[-<addins>]-<compiler>-<date>.tar.xz
```

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

These parameters affect only downloads that pass through `retry-tool`, namely `download.sh` and `build.sh`; downloads performed by `setup.sh` are not currently controlled by them.
