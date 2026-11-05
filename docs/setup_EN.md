# Setting Up the Build Environment

[简体中文](setup.md) | English

`native/setup.sh` sets up the build environment in the following steps:

1. handles the base distribution packages (compiler, Python, Git, JDK, OCaml, …): by default it prints the install command and installs them only with `--install`;
2. builds 24 managed build tools under `.buildtools/` (autoconf, cmake, nasm, …);
3. creates the Python venv (meson, jsonschema, jinja2);
4. prepares the Rust toolchain and cargo-c as needed, and installs Implib.so.

All artifacts remain inside the repository; sudo is used only to install distribution packages.

## Tested distributions and package managers

| Package manager | Distribution | Notes |
|---|---|---|
| apt | Debian 13, Ubuntu 22.04 / 24.04 / 26.04 | — |
| dnf | Fedora 44 | — |
| dnf (EL8) | Rocky Linux 8.10 | passes `--enablerepo=powertools` when installing |
| pacman | Arch Linux | — |
| zypper | openSUSE Leap 16 | — |

> [!NOTE]
> The package installation step prints only the install command for the current host and does not invoke the package manager. Pass `--install` to install the packages.

## Common commands

```bash
./native/setup.sh --check             # read-only diagnosis
./native/setup.sh --print-packages    # print the package install command
./native/setup.sh                     # set up the build environment (prints the install command by default)
./native/setup.sh --install           # install packages and set up the build environment
```

After installing packages or changing the configuration, run `./native/setup.sh --check`; exit code 0 indicates that the runtime prerequisites are satisfied.

## Options

| Option | Meaning |
|---|---|
| `--check` | read-only diagnosis: lists required and optional tools; prints the install command when host tools or runtime prerequisites are missing, and a hint to rerun setup when managed build tools are missing; exit code 1 when required tools, runtime prerequisites, or managed build tools are missing — Implib and optional tools do not count |
| `--all` | adds packages provided by the upstream image that the default variant does not use (p7zip, qemu-user, nodejs, gtk-doc, …) |
| `--install` | install the packages required by the current host (default: print the command only) |
| `--no-install` | skip package installation entirely |
| `--print-packages[=all]` | print the install command; `=all` includes the extra packages from `--all` |
| `--buildtools-only` | process only the managed build tools, venv, and Implib (installing opam when needed) |
| `--with-tools=a,b` | process only the listed managed build tools (already-built ones are skipped) |
| `--no-managed-tools` | do not build the managed build tools; use the host-provided versions, but an existing `.buildtools/prefix/bin` still precedes them on `PATH` |
| `--with-ctng` | additionally build the crosstool-ng toolchain (used with `FFBUILD_TOOLCHAIN_MODE=ctng`; **untested**); skipped when the existing toolchain matches the current configuration |
| `--force-ctng` | rebuild the crosstool-ng toolchain |

`-h` / `--help` prints the usage summary (same options as the table above, without the description column). The comment block at the top of the script is the authoritative source for this list.

## Package name mapping

`native/pkgdeps.conf` maps each capability to package names: one capability per line, with five columns for apt / dnf / dnf-el8 / pacman / zypper. `-` indicates that the distribution has no such package (for example, EL8 has no `ocaml-num`).

## `--check` output

```
[ok]        ready
[managed]   provided by .buildtools/; not counted as a failure
[MISSING]   missing; the following line usually gives the install command
[absent]    optional tool; its absence does not affect the build
```

For a missing managed build tool, `[MISSING]` does not produce an install command; the output instead prompts you to rerun `setup.sh`.

## Proxy

Proxy settings are inherited from the current shell (`http_proxy` / `https_proxy` / `all_proxy`); `FFBUILD_PROXY` overrides all of them (an empty value disables the proxy). Source downloads for the managed build tools and `download.sh` both follow this setting.

`svn` does not read these environment variables (the `lame` and `xvid` stages), so a proxy must be configured in `~/.subversion/servers`.

## See also

- [Building](build_EN.md): targets, variants, compilers, and build controls
- [Troubleshooting](troubleshooting_EN.md)
