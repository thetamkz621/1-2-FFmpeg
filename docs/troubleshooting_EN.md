# Troubleshooting

[简体中文](troubleshooting.md) | English

## Start with `--check`

`./native/setup.sh --check` is a read-only diagnosis: it installs no packages, requires no sudo, and does not modify the repository. Pay particular attention to the following:

- `[MISSING]`: a required item is missing. For host tools and runtime prerequisites, the following line provides the install command for the current distribution; for managed build tools, the output prompts you to rerun `./native/setup.sh`.
- `[absent]`: an optional tool is missing; the build does not depend on it.
- Exit code 1 indicates a blocking condition: a required host tool, a runtime prerequisite, or a managed build tool is missing. Implib and optional tools do not affect the exit code.

Address each reported item, rerun `--check`, and confirm that the exit code is 0 before starting a build.

## C++23 build failures

**Symptoms**: building `openal-soft` fails with errors involving `std::string_view` range construction or `<ranges>`.

**Cause**: `openal-soft` uses C++23 range construction. The distribution's default compiler may not support this feature. `--check` compiles a small probe with the current `$CXX`, so the problem is reported before the build starts.

**Resolution**:

Install a compiler with C++23 support (GCC 12 or later). When clang is used, the libstdc++ headers it uses must also come from GCC 12 or later.

For example:

- RHEL 8: the system default GCC 8 does not meet this requirement. Install a `gcc-toolset` available in the configured repositories (the version depends on the repositories), then enable it with `scl enable <toolset> bash`; alternatively, set `FFBUILD_CC` and `FFBUILD_CXX` to `/opt/rh/<toolset>/root/usr/bin/gcc` and `g++`.
- Ubuntu 22.04: the system default GCC 11 does not meet this requirement. Install `gcc-12` and `g++-12`, then set `FFBUILD_CC=gcc-12 FFBUILD_CXX=g++-12`.

After making the change, rerun `--check` and confirm that the `c++23 string_view` check passes.

## `50-shaderc` fails because `c++` differs from `CXX`

**Symptoms**: the `47-vulkan/50-shaderc` stage fails with undefined references to `std::filesystem`; the `openal` C++23 check may already pass.

**Cause**: this stage's native_build unsets `CC` and `CXX`, after which cmake uses `c++` from `PATH`. `FFBUILD_CC` / `FFBUILD_CXX` never reach it, so setting those variables alone does not change the stage's behaviour.

**Fix**: put a C++17-capable compiler at the front of `PATH`, for example `source /opt/rh/<toolset>/enable` or `export PATH=<toolchain>/bin:$PATH`. The `host c++ (shaderc)` item in `--check` reports the problem in advance.

## `implib-gen` reports `Unrecognized form` when building with clang

**Symptoms**: the `40-libdrm`, `50-libva`, or `45-x11` stage fails with output such as:

```
implib-gen.py: error: readelf failed with retcode 0:
readelf: Warning: Unrecognized form: 0x22
```

**Cause**: clang emits DWARF5 debug information by default, and the host binutils `readelf` does not recognise some of its forms. `implib-gen.py`, invoked by `util/bin/gen-implib`, treats any stderr output from `readelf` as a failure.

**Fix**: make the compiler emit the older debug format, for example `FFBUILD_EXTRA_CFLAGS=-gdwarf-4 FFBUILD_EXTRA_CXXFLAGS=-gdwarf-4`; or upgrade the host binutils.

## `ar` fails to index symbols, or LLVMgold is too old

**Symptoms**: `ar` reports missing symbols during archiving or linking; or `--check` reports an LLVMgold plugin older than version 15.

**Cause**: the Rust static library from `librsvg` contains LLVM bitcode. binutils requires the LLVMgold plugin, version 15 or later, to index the symbols in that bitcode.

**Resolution**:

1. Upgrade LLVM so that the LLVMgold plugin is version 15 or later. This is the recommended approach.
2. If no other component requires LTO bitcode indexing, the plugin may be removed temporarily so that bfd falls back to the native symbol tables in the archive. This affects other builds that rely on LLVM bitcode; record the paths first so that the files can be restored by reinstalling LLVM.
3. Rerun `--check` and confirm that the `llvm bfd plugin` check reports the expected version.

## Missing OCaml `num` package

**Symptoms**: `--check` reports that OCaml `num` is missing; or `fftw3` fails during configuration because `num` is unavailable.

**Cause**: in maintainer mode, `fftw3` generates codelets with OCaml's `genfft`, which requires the `num` package from findlib. Some distributions do not provide this package.

**Resolution**:

- If the configured repositories provide the package, install it directly: `libnum-ocaml-dev` on Debian/Ubuntu; `ocaml-num` on Arch and Fedora.
- Where the package is unavailable (for example, on RHEL 8 and openSUSE Leap 16), no distribution package is required. Rerun `./native/setup.sh`; the script provisions `num` through opam into `.buildtools/opam/root`.
- `--check` distinguishes a missing `num` package from a missing OCaml toolchain. The latter requires `ocaml`, `findlib` and `ocamlbuild` to be installed first.

## Build failures with an official release source archive

**Symptoms**: When `FFMPEG_REPO` points to a directory unpacked from an official release source archive, compilation of FFmpeg fails in a file that calls a dependency API. For example:

```
libavcodec/liboapvenc.c:512:29: error: passing argument 1 of 'oapvm_create'
  from incompatible pointer type
```

**Cause**: dependency stages are pinned to current upstream revisions, whereas an official release archive is frozen at its tag. Compatibility changes made after the tag exist only on the release branch. The `RELEASE` check compares the major and minor version with the version addin; it does not check dependency APIs.

**Resolution**:

1. Prefer a checkout of the release branch: point `FFMPEG_REPO` at its working tree, or leave `FFMPEG_REPO` unset and select the corresponding version addin.
2. If the archive must be used, skip the incompatible stage, for example `FFBUILD_SKIP_STAGES=openapv`. A skipped stage is also removed from FFmpeg's configure flags, so the resulting build no longer provides that feature.

## Permission errors

**Symptoms**: `Permission denied`; or a build tool's configure stage reports `C compiler cannot create executables` (for example, `m4`).

**Cause**: `setup.sh` was previously run as root, leaving `.buildtools/` owned by root. A normal user then has no write permission, and configure cannot write files or produce executables.

**Resolution**: run the following from the repository root:

```bash
sudo chown -R "$USER" .
```

If an individual tool still has a partially populated build directory, remove that directory (for example, `.buildtools/src/m4`) and retry. Run `setup.sh` under your normal user account from then on; the script calls sudo only when installing distribution packages.

## Extra desktop and multimedia packages

**Symptoms**: dnf resolves a noticeably larger set of packages than expected, including `gtk3`, `libheif`, and components from `ffmpeg-free`; the download is correspondingly larger.

**Cause**: dnf installs weak dependencies (Recommends) by default. The `ant` build dependency brings in its JDK binding, which recommends a full JDK; the full JDK, in turn, recommends `gtk3`, which brings in desktop and multimedia libraries.

**Resolution**:

- The commands generated by the script already include `--setopt=install_weak_deps=False`. Keep this option when executing the `--print-packages` output manually.
- The zypper equivalent is `--no-recommends`; the script already includes it.
- The apt equivalent is `--no-install-recommends`; the script already includes it.

## Slow downloads, timeouts, or proxy settings not taking effect

**Symptoms**: source downloads stall or time out, or connections do not go through the configured proxy.

**Cause**: the proxy variables are not exported to the process environment; a download tool ignores them (`svn`); or the timeout and retry settings do not suit the current network.

**Resolution**:

- Proxy variables: `http_proxy`, `https_proxy`, and `all_proxy` (including their uppercase forms) are inherited from the environment; `FFBUILD_PROXY` overrides all protocols, and an empty value disables the proxy. Confirm that the variables are exported:
  ```bash
  env | grep -i proxy
  ```
- `svn`: `lame` and `xvid` fetch their sources over svn. svn reads only its own configuration and ignores the variables above, so configure `~/.subversion/servers`:
  ```ini
  [global]
  http-proxy-host = proxy.example.com
  http-proxy-port = 8080
  ```
  Alternatively, pass `--config-option servers:global:http-proxy-host=...` and `--config-option servers:global:http-proxy-port=...` to the svn command.
- Retry settings: `RETRY_MAX` (attempts, default 10), `RETRY_TIMEOUT` (initial timeout, default 120 s), `RETRY_TIMEOUT_INC` (backoff increment, default 60 s), and `RETRY_SLEEP_MAX` (maximum backoff, default 90 s). These variables apply to every fetch that passes through `retry-tool`, including the opam, Implib, rustup, crosstool-ng and managed-tool downloads performed by `setup.sh`, as well as `download.sh` and `build.sh`. HTTP 4xx responses are retried too; set `RETRY_MAX=1` temporarily when debugging a mirror URL. See [build_EN.md](build_EN.md#cache-and-retries).

## Incomplete Python venv

**Symptoms**: `--check` reports an incomplete pip or meson installation in the build venv; or the build cannot find meson.

**Cause**: venv creation was interrupted, dependency installation failed, or the interpreter was replaced.

**Resolution**: remove `.buildtools/venv` and rerun `./native/setup.sh`. The script recreates the venv with a host interpreter that meets the version requirement and reinstalls build-time modules such as meson; this requires access to a package index. Verify the result with `--check`.

## See also

- [Setting up the build environment](setup_EN.md)
- [Building](build_EN.md)
