# 安装构建环境

简体中文 | [English](setup_EN.md)

`native/setup.sh` 把一台 x86_64 Linux 主机准备到"可以直接跑 `build.sh`"的状态，
它做四件事：

1. 装上发行版提供的基础包（编译器、clang、python、git、JDK、OCaml……）；
2. 在仓库内 `.buildtools/` 下自建 24 个构建工具（autoconf、cmake、nasm 等）；
3. 建 Python venv（meson、jsonschema、jinja2）；
4. 装 rust 工具链、cargo-c 与 Implib.so。

所有产物都写在仓库里，不动 `/usr/local`、`/opt` 和用户主目录；只有装发行版包那一步用 sudo。

## 支持的发行版

| 包管理器 | 发行版 | 默认行为 |
|---|---|---|
| apt | Debian 13、Ubuntu 22.04 / 24.04 / 26.04 | 直接代装 |
| dnf | Fedora 44 | 只打印命令 |
| dnf（EL8） | Rocky Linux 8.10 | 只打印命令，安装时自动带 `--enablerepo=powertools` |
| pacman | Arch Linux | 只打印命令 |
| zypper | openSUSE Leap 16 | 只打印命令 |

非 apt 宿主默认只打印一条可直接粘贴的命令，不动 sudo——猜错包名的代价比省下的几步大。
加 `--install` 才代装。

最近一轮（包名表改动之后）复测的是 Ubuntu 24.04、Fedora 44、Rocky 8.10、Arch 与
Leap 16；Debian 13、Ubuntu 22.04 / 26.04 用的是同一套包名，验证在更早一轮。

## 常用命令

```bash
./native/setup.sh --check             # 只读诊断，不改动系统
./native/setup.sh                     # apt 宿主直接装；其他宿主只打印命令
./native/setup.sh --print-packages    # 打印本机需要的包
./native/setup.sh --install           # 让脚本代装（非 apt 宿主）
```

装完或改完配置后用 `--check` 复核，退出码 0 表示运行时前置齐了。

## 选项一览

| 选项 | 说明 |
|---|---|
| `--check` | 只读诊断：列出必需与可选工具、缺失项的安装命令；有缺失时退出码为 1 |
| `--all` | 安装清单加上上游镜像里有、默认变体用不到的包（p7zip、qemu-user、nodejs、gtk-doc……） |
| `--install` | 非 apt 宿主也代装 |
| `--no-install` | 完全跳过装包（包由外部管理） |
| `--print-packages[=all]` | 打印一条可直接粘贴的安装命令；`=all` 含 `--all` 的额外包 |
| `--buildtools-only` | 只建托管工具与 venv，不写工具链描述文件、不建构建根 |
| `--with-tools=a,b` | 指定要重建的工具（默认只补缺失的） |
| `--no-managed-tools` | 一个工具都不建，用宿主自带的版本 |
| `--with-ctng` | 额外构建 crosstool-ng 工具链（配合 `FFBUILD_TOOLCHAIN_MODE=ctng`，未验证） |

`-h` / `--help` 打印同样的清单。脚本头部的注释是这个清单的权威来源。

## 包名从哪来

`native/pkgdeps.conf` 是"能力 → 包名"的映射表：每行一个能力，按
apt / dnf / dnf-el8 / pacman / zypper 五列给出，`-` 表示该发行版没有这个包
（例如 EL8 没有 `ocaml-num`）。

新增发行版或包名变动只改这张表，不改脚本。改之前先在真实宿主上跑
`--print-packages` 和 `--check` 核对——包名随发行版版本漂移，别按记忆填。

## 各发行版的坑

- **RHEL 8 系**：系统 python 只有 3.6，表里指定 `python3.12`；ocaml 在 powertools；
  cargo-c 需要 `openssl3-devel`（并行装在 `/usr/include/openssl3`）；系统 gcc 8.5
  不满足 C++23，`--check` 会提示改用已装的 `gcc-toolset`。
- **Fedora**：dnf 默认装弱依赖，`ant` 会沿 `java-devel → 完整 JDK → gtk3 → libheif →
  libheif-ffmpeg` 拉进 ffmpeg-free 全家。脚本安装时已带
  `--setopt=install_weak_deps=False`，手抄命令时别漏；JDK 侧用 `java-devel`，
  headless 包里没有 `javac`，而 libbluray 的 BD-J 需要它。
- **Arch**：没有弱依赖概念，`base-devel` 会带进常见工具；ocaml 的 num 包名是 `ocaml-num`。
- **openSUSE**：`java-devel` 解析到 `java-25-openjdk-devel`；OCaml 构建工具叫
  `ocaml-ocamlbuild`；`nodejs` 这个能力由 `asar` 提供，表里用 `nodejs-default`。
- **所有宿主**：不要用 root 跑 `setup.sh`。`.buildtools/` 会归 root，之后普通用户重跑
  会撞权限错误（脚本会先给告警）。

## `--check` 怎么读

```
[ok]       已就绪
[managed]  由 .buildtools/ 提供，不计为失败
[MISSING]  缺，下一行是安装命令
[absent]   可选工具，缺了也能构建
```

`--check` 是只读的：不装包、不建目录、不需要 sudo。

## 代理

默认继承 shell 的 `http_proxy` / `https_proxy` / `all_proxy`，也可以用
`FFBUILD_PROXY` 统一覆盖（设为空值表示不用代理）。托管工具的源码下载和
`download.sh` 都走它。

`svn` 不读这些变量（lame 与 xvid 两个阶段），需要自备 `~/.subversion/servers`。

## 相关

- [构建](build.md)：目标、变体、编译器与构建控制变量
- [常见失败](troubleshooting.md)
