# 配置构建环境

简体中文 | [English](setup_EN.md)

`native/setup.sh` 用于配置构建环境，包括以下步骤：

1. 处理发行版提供的基础软件包（编译器、Python、Git、JDK、OCaml 等）：默认仅打印安装命令，传递 `--install` 时安装；
2. 在仓库内 `.buildtools/` 下构建 24 个托管构建工具（autoconf、cmake、nasm 等）；
3. 创建 Python venv（meson、jsonschema、jinja2）；
4. 按需准备 Rust 工具链与 cargo-c，并安装 Implib.so。

所有产物均位于仓库内；仅在安装发行版软件包时使用 sudo。

## 已验证的发行版与包管理器

| 包管理器 | 发行版 | 备注 |
|---|---|---|
| apt | Debian 13、Ubuntu 22.04 / 24.04 / 26.04 | — |
| dnf | Fedora 44 | — |
| dnf（EL8） | Rocky Linux 8.10 | 安装时自动传入 `--enablerepo=powertools`；cargo-c 使用 vendored OpenSSL |
| pacman | Arch Linux | — |
| zypper | openSUSE Leap 16 | — |

> [!NOTE]
> 软件包安装步骤默认仅打印当前主机所需的安装命令，不调用包管理器；传递 `--install` 后才安装软件包。

## 常用命令

```bash
./native/setup.sh --check             # 只读诊断
./native/setup.sh --print-packages    # 打印软件包安装命令
./native/setup.sh                     # 配置构建环境（默认仅打印安装命令）
./native/setup.sh --install           # 安装软件包并配置构建环境
```

安装软件包或修改配置后，运行 `./native/setup.sh --check` 复核；退出码为 0 表示运行时前置已满足。

## 选项一览

| 选项 | 说明 |
|---|---|
| `--check` | 只读诊断：列出必需与可选工具；宿主工具或运行时前置缺失时给出安装命令，托管构建工具缺失时提示重新运行 `setup.sh`；必需工具、运行时前置或托管构建工具缺失时退出码为 1，Implib 与可选工具不计入 |
| `--all` | 在安装清单中加入上游镜像提供、但默认变体不使用的软件包（p7zip、qemu-user、nodejs、gtk-doc 等） |
| `--install` | 安装当前主机所需的软件包（默认仅打印命令） |
| `--no-install` | 完全跳过软件包安装步骤 |
| `--print-packages[=all]` | 打印安装命令；`=all` 包含 `--all` 的额外软件包 |
| `--buildtools-only` | 仅处理托管构建工具、venv 与 Implib（必要时安装 opam） |
| `--with-tools=a,b` | 仅处理列出的托管构建工具（已构建的跳过） |
| `--no-managed-tools` | 不构建托管构建工具，使用宿主提供的版本；当前仓库中已有的 `.buildtools/prefix/bin` 仍优先于 `PATH` |
| `--with-ctng` | 额外构建 crosstool-ng 工具链（与 `FFBUILD_TOOLCHAIN_MODE=ctng` 配合使用）；已构建且配置未变时跳过 |
| `--ctng-target <target>` | 选择工具链目标，默认 `linux64`；`linuxarm64` 需要 qemu-user 运行产物 |
| `--force-ctng` | 强制重建 crosstool-ng 工具链 |
| `--keep-ctng-src` | 保留 ct-ng 的按目标构建树（默认在安装完成后删除，可释放数 GB） |

工具链按目标安装到 `.buildtools/ctng/<target>`，完成标记为 `.buildtools/state/ctng-<target>.done`。`linuxarm64` 下 `--install` 会安装 qemu-user；`--check` 缺少它时只作提示，因为构建本身不运行目标程序。`--with-ctng` 始终以 host 模式准备环境：即使设置了 `FFBUILD_TOOLCHAIN_MODE=ctng`，也会继续构建工具链，不会因此提前退出。同一仓库中不要并发运行 `--with-ctng`：各目标共用 ct-ng 的源码树与 `.config`，检测到另一个构建正在进行时，后一个进程直接退出。

`-h` / `--help` 打印用法摘要（选项与上表一致，但不含说明列）。脚本头部的注释是该清单的权威来源。

## 软件包名称映射

`native/pkgdeps.conf` 是“能力 → 包名”的映射表：每行一个能力，按 apt / dnf / dnf-el8 / pacman / zypper 分为五列；`-` 表示该发行版没有对应软件包（例如 EL8 没有 `ocaml-num`）。

EL8 不安装 OpenSSL 开发包：系统 OpenSSL 过旧时，cargo-c 通过自身的 `vendored-openssl` 特性静态编译一份 OpenSSL。`--all` 用到的 `p7zip`、`lcov` 只存在于 EPEL，未启用 EPEL 时 `--print-packages=all` 会先输出 `dnf install -y epel-release`，`--install --all` 自动完成该步骤。

## `--check` 输出说明

```
[ok]       已就绪
[managed]  由 .buildtools/ 提供，不计为失败
[MISSING]  缺失；通常下一行给出安装命令，构建无法进行
[warn]     不阻断构建；产物或可选能力可能受影响
[absent]   可选工具；缺失不影响构建
[pending]  尚未满足，但 setup 会自动完成（例如 cargo-c 以 vendored OpenSSL 构建）
```

缺失项若属于托管构建工具，则不会给出安装命令，而是提示重新运行 `setup.sh`。

## 代理

默认继承当前 shell 的代理配置（`http_proxy` / `https_proxy` / `all_proxy`）；也可通过 `FFBUILD_PROXY` 统一覆盖（设为空值表示不使用代理）。托管构建工具的源码下载与 `download.sh` 均遵循该设置。

`svn` 不读取这些环境变量（`lame` 与 `xvid` 两个阶段），需在 `~/.subversion/servers` 中配置代理。

## 相关

- [构建](build.md)：目标、变体、编译器与构建控制变量
- [故障排查](troubleshooting.md)
