# Troubleshooting

[简体中文](troubleshooting.md) | English

## Start with `--check`

`./native/setup.sh --check` is read-only: it installs nothing and needs no sudo. Every
`[MISSING]` line is followed by the install command for your distribution — fix those first.

## `string_view` / C++23 build failures

`openal-soft` uses C++23 range constructors. `--check` compiles a probe with the current
`$CXX`:

- EL8: the system gcc 8.5 is too old. Use `scl enable gcc-toolset-15 bash`, or
  `FFBUILD_CC=/opt/rh/gcc-toolset-15/root/usr/bin/g FFBUILD_CXX=.../g++`.
- Ubuntu 22.04: install `gcc-12` and run with `FFBUILD_CC=gcc-12 FFBUILD_CXX=g++-12`.

## `ar` reports missing symbols / LLVMgold is too old

`librsvg`'s Rust static library carries LLVM bitcode; binutils needs LLVMgold ≥ 15 to
index it. Either upgrade llvm, or remove `/usr/lib/bfd-plugins/LLVMgold*.so` so bfd reads
the native symbol tables. `--check` prints the version it found.

## The OCaml `num` package is missing

Debian and Arch ship `libnum-ocaml-dev` / `ocaml-num`; EL8 and Leap 16 do not, so setup
provisions num through opam into `.buildtools/opam/root`. When `--check` says the
distribution has no num package, rerun `./native/setup.sh` — there is no distro package
to install.

## `Permission denied` / `C compiler cannot create executables`

Usually a previous `setup.sh` run as root: `.buildtools/` is owned by root and a normal
user can no longer write to it, which surfaces as `C compiler cannot create executables`
in m4's configure stage.

```bash
sudo chown -R "$USER" .
```

Run setup as your own user from then on; the script calls sudo itself for packages only.

## The install pulls in a desktop/media stack

dnf installs weak dependencies by default: `ant` pulls `java-devel → full JDK → gtk3 →
libheif → libheif-ffmpeg`, dragging in the whole ffmpeg-free stack and roughly doubling the
package count. The script already passes `--setopt=install_weak_deps=False`; keep it when
you paste the `--print-packages` output by hand. The zypper equivalent is
`--no-recommends`.

## Slow downloads, timeouts, proxy not applied

- Managed tools and source downloads honour `http_proxy` / `https_proxy` /
  `FFBUILD_PROXY`; check the shell actually exported them (`env | grep -i proxy`).
- `svn` ignores these variables (lame and xvid), so configure `~/.subversion/servers`.
- Timeouts and retry counts are tunable, see
  [build_EN.md](build_EN.md#cache-and-retries).

## Broken venv

If `--check` reports an incomplete venv, remove `.buildtools/venv` and rerun
`./native/setup.sh`; it recreates the venv with the host interpreter.

## See also

- [Setting up the build host](setup_EN.md)
- [Building](build_EN.md)
