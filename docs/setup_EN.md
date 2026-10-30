# Setting Up the Build Host

[简体中文](setup.md) | English

`native/setup.sh` brings an x86_64 Linux host to the point where `build.sh` can run.
It does four things:

1. installs the distro packages (compiler, clang, python, git, JDK, OCaml, …);
2. builds 24 helper tools under `.buildtools/` (autoconf, cmake, nasm, …);
3. creates the Python venv (meson, jsonschema, jinja2);
4. installs the Rust toolchain, cargo-c and Implib.so.

Everything it builds lives inside the repo; it never writes to `/usr/local`, `/opt` or
your home directory. sudo is only used for the distro packages.

## Supported distributions

| Package manager | Distribution | Default behaviour |
|---|---|---|
| apt | Debian 13, Ubuntu 22.04 / 24.04 / 26.04 | installs the packages |
| dnf | Fedora 44 | prints the command only |
| dnf (EL8) | Rocky Linux 8.10 | prints the command only, adds `--enablerepo=powertools` |
| pacman | Arch Linux | prints the command only |
| zypper | openSUSE Leap 16 | prints the command only |

On non-apt hosts the default is to print one ready-to-paste command and never touch sudo —
guessing package names wrong is worse than the few steps it saves. Pass `--install` to let
the script install them.

The latest round (after the package table was reworked) re-tested Ubuntu 24.04, Fedora 44,
Rocky 8.10, Arch and Leap 16. Debian 13 and Ubuntu 22.04 / 26.04 share the same apt column,
but their verification dates from an earlier round.

## Common commands

```bash
./native/setup.sh --check             # read-only diagnosis
./native/setup.sh                     # apt hosts install; others only print
./native/setup.sh --print-packages    # print what this host needs
./native/setup.sh --install           # let the script install (non-apt hosts)
```

Run `--check` afterwards; exit code 0 means the runtime prerequisites are satisfied.

## Options

| Option | Meaning |
|---|---|
| `--check` | read-only diagnosis; lists required/optional tools and the commands for anything missing; exit 1 when something is missing |
| `--all` | extend the install list with upstream-image packages the default variant does not use (p7zip, qemu-user, nodejs, gtk-doc, …) |
| `--install` | also install packages on non-apt hosts |
| `--no-install` | skip package installation entirely |
| `--print-packages[=all]` | print a ready-to-paste install command; `=all` includes the `--all` extras |
| `--buildtools-only` | build the managed tools and venv only; no toolchain descriptors, no build root |
| `--with-tools=a,b` | rebuild these tools (by default only missing ones) |
| `--no-managed-tools` | build nothing; use whatever the host provides |
| `--with-ctng` | additionally build the crosstool-ng toolchain (for `FFBUILD_TOOLCHAIN_MODE=ctng`, untested) |

`-h` / `--help` prints the same list. The comment block at the top of the script is the
authoritative source.

## Where the package names come from

`native/pkgdeps.conf` maps a capability to package names: one capability per line, with
columns for apt / dnf / dnf-el8 / pacman / zypper. `-` means the distribution has no such
package (EL8 has no `ocaml-num`, for example).

New distributions or renamed packages only change that table, not the script. Verify any
change on a real host with `--print-packages` and `--check` first — names drift between
releases, don't fill them from memory.

## Per-distribution notes

- **RHEL 8 family**: the system python is 3.6, the table asks for `python3.12`; ocaml lives
  in powertools; cargo-c needs `openssl3-devel` (installed side by side in
  `/usr/include/openssl3`); the system gcc 8.5 has no C++23, and `--check` points at the
  `gcc-toolset` that is already installed.
- **Fedora**: dnf installs weak dependencies by default, and `ant` drags in
  `java-devel → full JDK → gtk3 → libheif → libheif-ffmpeg` (the whole ffmpeg-free stack).
  The script passes `--setopt=install_weak_deps=False`; keep it if you paste the command
  by hand. The JDK side needs `java-devel` — the headless package has no `javac`, which
  libbluray's BD-J build requires.
- **Arch**: no weak dependencies; `base-devel` brings the usual tools; the OCaml num
  package is `ocaml-num`.
- **openSUSE**: `java-devel` resolves to `java-25-openjdk-devel`; the OCaml build tool is
  `ocaml-ocamlbuild`; the `nodejs` capability is provided by `asar`, so the table asks
  for `nodejs-default`.
- **All hosts**: do not run `setup.sh` as root. `.buildtools/` would be owned by root and
  a later run as your normal user fails on permissions (the script warns about this).

## Reading `--check`

```
[ok]        ready
[managed]   provided by .buildtools/, not counted as a failure
[MISSING]   missing; the next line is the install command
[absent]    optional tool, the build works without it
```

`--check` is read-only: it installs nothing, creates nothing and needs no sudo.

## Proxy

The shell's `http_proxy` / `https_proxy` / `all_proxy` are inherited; `FFBUILD_PROXY`
overrides all of them (an empty value disables the proxy). Source downloads for the
managed tools and `download.sh` both honour it.

`svn` does not read these variables (the lame and xvid stages), so it needs
`~/.subversion/servers`.

## See also

- [Building](build_EN.md): targets, variants, compilers and build controls
- [Troubleshooting](troubleshooting_EN.md)
