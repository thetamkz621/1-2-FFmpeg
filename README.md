# 1-2-FFmpeg

简体中文 | [English](README_EN.md)

> [!NOTE]
> 开发过程中大量使用 AI agent。

基于 [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds) 的去 Docker 化版本：直接在 Linux x86_64 主机上构建 FFmpeg 及其依赖。

支持 `linux64`、`win64` 与 `win32` 目标。Windows 目标只能使用 crosstool-ng 工具链，并需要 wine；`win32` 还要求 wine 能运行 32 位程序。

## 文档

| 文档 | 内容 |
|---|---|
| [配置构建环境](docs/setup.md) | 前置条件、各发行版所需软件包、`setup.sh` 全部选项、`--check` 输出说明 |
| [构建](docs/build.md) | 编译器与工具链模式、构建控制变量、目录布局、源码缓存 |
| [故障排查](docs/troubleshooting.md) | C++23、LLVMgold、OCaml num、Windows 目标缺少 wine、权限问题、弱依赖 |

## 构建方法

### 前置条件

需要 x86_64 Linux 主机。`setup.sh` 负责发行版软件包（默认仅打印当前主机所需的安装命令，传递 `--install` 后才安装），并在 `.buildtools/` 下构建 24 个托管构建工具与 Python venv，并按需准备 Rust 工具链与 cargo-c。

> [!IMPORTANT]
> 部分依赖的最低版本要求如下。如需安装满足要求的版本，请相应调整安装命令。
> | 项 | 最低要求 | 原因 |
> |---|---|---|
> | Python | 3.10 | 创建 venv、运行 meson |
> | C++ 编译器 | 支持 C++23（例如 GCC 12） | `openal-soft` 需要 `std::string_view` 范围构造 |
> | LLVM / LLVMgold | 15 | 供 `ar` 索引 `librsvg` 的 Rust bitcode |

> 构建不需要 root 权限；删除仓库即可清除全部构建产物（`setup.sh` 安装的发行版软件包仍保留在系统中）。  
> 各发行版软件包名称、全部选项与故障排查见 [docs/setup.md](docs/setup.md)。

### 快速开始

```bash
./native/setup.sh --check   # 只读诊断：报告缺失项与安装命令
./native/setup.sh --install # 安装软件包并配置构建环境
# ./build.sh <目标> <变体> [附加项 [附加项] [附加项] ...]
# 例如：
./build.sh linux64 gpl      # 获取源码并构建
```

成功后产物位于 `artifacts/ffmpeg-<版本>-<目标>-<变体>[-<附加项>]-<编译器或工具链>-<日期>.tar.xz`。

### 目标、变体与附加项

可用目标：
* `linux64`（x86_64 Linux）
* `win64`（x86_64 Windows，仅 ctng）
* `win32`（x86 Windows，仅 ctng）
* ~~`linuxarm64`（arm64 / aarch64 Linux）~~

`win64` 与 `win32` 需要先安装 wine 并构建对应的 crosstool-ng 工具链：

```bash
./native/setup.sh --install --with-ctng --ctng-target win64
FFBUILD_TOOLCHAIN_MODE=ctng ./build.sh win64 gpl-shared 9.0

./native/setup.sh --install --with-ctng --ctng-target win32
FFBUILD_TOOLCHAIN_MODE=ctng ./build.sh win32 gpl-shared 9.0
```

~~linuxarm64 目标因缺少 arm64（aarch64）架构支持或受交叉编译限制，部分依赖无法构建。~~

* ~~`davs2` 与 `xavs2`：aarch64 支持不可用。~~
* ~~`libmfx` 与 `libva`：Intel QSV 库，无 aarch64 支持。~~

可用变体：
* `gpl` 包含全部依赖，包括要求完整 GPL 而非仅 LGPL 的部分。
* `lgpl` 不包含仅 GPL 的库，主要是 libx264 与 libx265。
* `nonfree` 在 gpl 变体的依赖之外额外包含 fdk-aac。
* `gpl-shared` 同 gpl，但提供 libav* 系列动态库，而非纯静态可执行文件。
* `lgpl-shared` 同上，使用 lgpl 依赖集。
* `nonfree-shared` 同上，使用 nonfree 依赖集。

以上变体均可与任意附加项组合：
* `4.3`/`4.4`/`5.0`/`5.1`/`6.0`/`6.1`/`7.0`/`7.1`/`8.0`/`8.1`/`9.0` 从对应 release 分支而非 master 构建。
* `debug` 保留调试符号，产物体积约增加 250 MB。
* `lto` 对所有依赖与 FFmpeg 使用 `-flto=auto`（高度实验性；Windows 上不可用，Linux 上有时可行）。

### 编译器

```bash
FFBUILD_TOOLCHAIN_MODE=clang ./build.sh linux64 gpl
FFBUILD_TOOLCHAIN_MODE=gcc   ./build.sh linux64 gpl
FFBUILD_TOOLCHAIN_MODE=ctng  ./build.sh linux64 gpl   # crosstool-ng 工具链
FFBUILD_TOOLCHAIN_MODE=ctng  ./build.sh win64 gpl-shared 9.0   # 需先构建 win64 工具链
FFBUILD_TOOLCHAIN_MODE=ctng  ./build.sh win32 gpl-shared 9.0   # 需先构建 win32 工具链
```

> [!NOTE]
> `host`（默认）按 `cc` → `gcc` → `clang` 顺序探测，`CXX` 跟随同一编译器家族；`clang` / `gcc` 仅设置宿主工具链的默认二进制名称；`ctng` 使用本地构建的 crosstool-ng 工具链，按目标存放在 `.buildtools/ctng/<target>`；linux64 首次构建包含 glibc 与 GCC，Windows 目标包含 mingw-w64 与 GCC，耗时较长。构建工具链时使用 `./native/setup.sh --with-ctng --ctng-target <目标>`，并确保已安装 wine（`--install` 会一并安装）。  
> `FFBUILD_CC` / `CC`（以及 `CXX`、`LD`、`AR` 等）可覆盖上述选择，也可指向带版本号的编译器（如 `FFBUILD_CC=gcc-12 FFBUILD_CXX=g++-12`）。  
> 追加编译选项使用 `FFBUILD_EXTRA_CFLAGS`、`FFBUILD_EXTRA_LDFLAGS`。  
> 查看最终配置：`source native/env.sh && ffbuild_env_dump`。  
> 常用变量说明见 [docs/build.md](docs/build.md)；完整列表见 `native/env.sh` 顶部注释。

### 代理

默认继承 shell 的代理配置（`http_proxy` / `https_proxy` / `all_proxy`）。

```bash
FFBUILD_PROXY=http://host:port ./native/download.sh   # 覆盖所有协议
FFBUILD_PROXY= ./native/download.sh                   # 不使用 shell 中的代理
```

> `svn` 不读取这些变量（仅读取 `~/.subversion/servers`），因此 `lame` 与 `xvid` 两个阶段始终直接连接。

## 目录

```
ffbuild/{prefix,destdir,work,log,state,pkgroot}   构建根（FFBUILD_ROOT）
.buildtools/                                      托管构建工具、venv、Rust，不纳入版本控制
.cache/downloads/                                 依赖源码缓存
artifacts/                                        产物
```

> `.buildtools/ctng/<target>` 存放各目标的 crosstool-ng 工具链。

> `FFBUILD_ROOT` 路径不能包含 `.`（上游 `libxcb`/`libglvnd` 的路径处理会失败）。  
> `linux64` 产物与宿主 glibc 匹配；如需 glibc 2.28 基线，使用 `FFBUILD_TOOLCHAIN_MODE=ctng`（先运行 `./native/setup.sh --with-ctng`）。`win64` 与 `win32` 产物依赖 UCRT。

## 许可

沿用上游 [`LICENSE`](LICENSE)。
