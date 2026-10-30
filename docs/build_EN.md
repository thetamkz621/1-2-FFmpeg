# Building

[简体中文](build.md) | English

```bash
./build.sh <target> <variant> [addin ...]

./build.sh linux64 gpl
./build.sh linux64 lgpl 8.1
./build.sh linux64 gpl-shared debug
```

Targets, variants and addins are listed in the [README](../README_EN.md#targets-variants-and-addins).

Before building, `native/download.sh --needed <target> <variant>` runs automatically to
refresh the source cache; `FFBUILD_SKIP_DOWNLOAD=1` skips it (reuse the cache), and
`FFBUILD_FFMPEG_ONLY=1` skips it as well.

## Compiler and toolchain

| Variable | Meaning |
|---|---|
| `FFBUILD_TOOLCHAIN_MODE` | `host` (default: probe cc → gcc → clang) / `clang` / `gcc` / `ctng` |
| `FFBUILD_CC` `FFBUILD_CXX` `FFBUILD_LD` `FFBUILD_AR` … | per-tool overrides (or plain `CC=` / `CXX=`) |
| `FFBUILD_TOOLCHAIN_TRIPLE` | override the `--host` triple handed to every stage |
| `FFBUILD_CTNG_ROOT` | ct-ng toolchain location, default `$FFBUILD_ROOT/ctng` |

`clang` / `gcc` only set the default for the host toolchain; `ctng` needs
`./native/setup.sh --with-ctng` first and is untested.

Versioned compilers work directly:

```bash
FFBUILD_CC=gcc-12 FFBUILD_CXX=g++-12 ./build.sh linux64 gpl
```

## Compiler flags

| Variable | Semantics |
|---|---|
| `FFBUILD_CFLAGS` / `FFBUILD_CXXFLAGS` / `FFBUILD_LDFLAGS` / `FFBUILD_LDEXEFLAGS` | **replace** the built-in defaults |
| `FFBUILD_EXTRA_CFLAGS` / `_CXXFLAGS` / `_LDFLAGS` / `_LDEXEFLAGS` | **append** to whatever is in effect |
| `FFBUILD_EXTRA_STAGE_CFLAGS` / `_CXXFLAGS` / `_LDFLAGS` | append to the per-stage flags |

The full variable list lives in the comment block at the top of `native/env.sh`. To see the
resolved configuration:

```bash
source native/env.sh && ffbuild_env_dump
```

## Build controls

| Variable | Meaning |
|---|---|
| `FFBUILD_CLEAN=1` | wipe `FFBUILD_ROOT` before building |
| `FFBUILD_FORCE=1` | rebuild every stage, ignoring resume state |
| `FFBUILD_DEPS_ONLY=1` | build dependencies only, skip FFmpeg |
| `FFBUILD_FFMPEG_ONLY=1` | skip dependencies, reuse the existing prefix |
| `FFBUILD_SKIP_DOWNLOAD=1` | do not refresh the download cache |
| `FFBUILD_JOBS=<N>` | parallel jobs, default `nproc` |
| `FFBUILD_ROOT=<path>` | build root, default `<repo>/ffbuild`; the path must not contain `.` |
| `FFBUILD_BUILD_DATE=YYYYMMDD` | pin the date in the artifact name |

## Layout and artifacts

| Path | Contents |
|---|---|
| `ffbuild/prefix` | dependency install prefix (`PKG_CONFIG_LIBDIR` points here) |
| `ffbuild/work` | unpack/build directories of each stage |
| `ffbuild/log` | per-stage logs |
| `ffbuild/state` | resume state |
| `ffbuild/destdir` | per-stage `DESTDIR`, merged into `prefix` when the stage finishes |
| `ffbuild/pkgroot` | packaging scratch directory |
| `ffbuild/ctng` | crosstool-ng toolchain (`ctng` mode) |
| `.buildtools/` | managed tools, venv, rust, opam |
| `.cache/downloads/` | source cache |
| `artifacts/` | build artifacts |

Artifact name:

```
artifacts/ffmpeg-<version>-<target>-<variant>[-<addin>]-<compiler>-<date>.tar.xz
```

The version comes from FFmpeg's `ffbuild/version.sh`: `nX.Y.Z` on a release branch,
`<commit>-<describe>` on master.

## Cache and retries

`.cache/downloads/` is content-addressed: `<stage>_<hash>.tar.xz` plus a
`<stage>.tar.xz` symlink. The two useful commands:

```bash
./native/download.sh --needed linux64 gpl   # only what this target needs
./native/download.sh hashonly               # print the cache key
```

On a slow link, `util/bin/retry-tool` honours `RETRY_MAX` (default 10 attempts),
`RETRY_TIMEOUT` (first attempt, 120 s), `RETRY_TIMEOUT_INC` (growth per retry, 60 s) and
`RETRY_SLEEP_MAX` (backoff cap, 90 s).
