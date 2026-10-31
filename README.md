# 1-2-FFmpeg

简体中文 | [English](README_EN.md)

> [!NOTE]
> 修改过程中大量使用 AI agent。

基于 [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds) 的去 Docker 化版本：
直接在 Linux x86_64 主机上构建 FFmpeg 及其依赖。

仅支持 `linux64` 目标。上游的其余目标仍保留，但未经验证。

## 文档

| 文档 | 内容 |
|---|---|
| [安装构建环境](docs/setup.md) | 前置、各发行版装什么包、`setup.sh` 的全部选项、`--check` 怎么读 |
| [构建](docs/build.md) | 编译器与工具链模式、构建控制变量、目录布局、源码缓存 |
| [常见失败](docs/troubleshooting.md) | C++23、LLVMgold、OCaml num、权限问题、弱依赖 |

## 构建方法

### 前置

x86_64 Linux 主机，需要 `bash`、`git` 与 python 3.10 或以上。`setup.sh` 负责装发行版包
（默认只打印本机需要的包，加 `--install` 才代装），并在 `.buildtools/`
下自建 24 个构建工具、Python venv 与 rust 工具链。

> 构建不需要 root；删掉仓库即可清掉全部构建产物（`setup.sh` 装的发行版包仍留在系统里）。
> 各发行版的包名、全部选项与排错见 [docs/setup.md](docs/setup.md)。

> [!IMPORTANT]
> 需要支持 C++23 特性的编译器（例如 GCC 12 或以上版本）
> > 依赖 `openal-soft` 需要 `std::string_view` 的范围构造
> 
> 需要 LLVM 15 或以上版本
> > binutils 的 LLVMgold 插件版本需 >= 15  
> > 否则 `ar` 索引不到 Rust bitcode 的符号（来自依赖 `librsvg`）

### 快速开始

```bash
./native/setup.sh --check   # 只读诊断：缺什么、怎么装
./native/setup.sh           # 打印本机需要的包（不改系统）
./build.sh linux64 gpl      # 取源码并构建
```

成功后产物位于 `artifacts/ffmpeg-<版本>-<目标>-<变体>[-<附加项>]-<编译器>-<日期>.tar.xz`。

### 目标、变体与附加项

可用目标：
* ~~`win64`（x86_64 Windows）~~
* ~~`win32`（x86 Windows）~~
* `linux64`（x86_64 Linux）
* ~~`linuxarm64`（arm64 / aarch64 Linux）~~

~~linuxarm64 目标因缺少 arm64（aarch64）架构支持或交叉编译限制，部分依赖无法构建。~~

* ~~`davs2` 与 `xavs2`：aarch64 支持已损坏。~~
* ~~`libmfx` 与 `libva`：Intel QSV 用库，无 aarch64 支持。~~

可用变体：
* `gpl` 包含全部依赖，包括需要完整 GPL 而非仅 LGPL 的部分。
* `lgpl` 缺少仅 GPL 的库，主要是 libx264 与 libx265。
* `nonfree` 在 gpl 变体的依赖之外额外包含 fdk-aac。
* `gpl-shared` 同 gpl，但提供 libav* 系列动态库而非纯静态可执行文件。
* `lgpl-shared` 同上，使用 lgpl 依赖集。
* `nonfree-shared` 同上，使用 nonfree 依赖集。

以上变体均可与任意附加项组合：
* `4.3`/`4.4`/`5.0`/`5.1`/`6.0`/`6.1`/`7.0`/`7.1`/`8.0`/`8.1`/`9.0` 从对应 release 分支而非 master 构建。
* `debug` 不剥离调试符号，产物体积约增加 250MB。
* `lto` 对所有依赖与 ffmpeg 使用 -flto=auto（高度实验性，Windows 上不可用，Linux 上有时可行）。

### 编译器

```bash
FFBUILD_TOOLCHAIN_MODE=clang ./build.sh linux64 gpl
FFBUILD_TOOLCHAIN_MODE=gcc   ./build.sh linux64 gpl
FFBUILD_TOOLCHAIN_MODE=ctng  ./build.sh linux64 gpl   # crosstool-ng 工具链（未验证）
```

> [!NOTE]
> `host`（默认）按 `cc` → `gcc` → `clang` 探测，`CXX` 跟随同一家族；`clang` / `gcc` 只设置宿主
> 工具链的默认值；`ctng` 使用本地构建的 crosstool-ng 工具链（目前未验证），需先运行
> `./native/setup.sh --with-ctng`。`FFBUILD_CC` / `CC`（以及 `CXX`/`LD`/`AR` 等）可覆盖，
> 也可指向带版本号的编译器（如 `FFBUILD_CC=gcc-12 FFBUILD_CXX=g++-12`）。
> 追加 Flag 用 `FFBUILD_EXTRA_CFLAGS`、`FFBUILD_EXTRA_LDFLAGS`。查看最终配置：
> `source native/env.sh && ffbuild_env_dump`；完整变量表见 `native/env.sh` 顶部注释与
> [docs/build.md](docs/build.md)。

### 设置代理

默认继承 shell 的代理设置（`http_proxy` / `https_proxy` / `all_proxy`）。

```bash
FFBUILD_PROXY=http://host:port ./native/download.sh   # 覆盖所有协议
FFBUILD_PROXY= ./native/download.sh                   # 忽略 shell 中的代理
```

> `svn` 不读取这些变量（只认 `~/.subversion/servers`），因此 lame 与 xvid 两个阶段始终直连。

## 目录

```
ffbuild/{prefix,destdir,work,log,state,pkgroot}   构建根（FFBUILD_ROOT）
.buildtools/                                      托管的构建工具、venv、rust，不入库
.cache/downloads/                                 依赖源码缓存
artifacts/                                        产物
```

> `FFBUILD_ROOT` 路径不能包含 `.`（上游 libxcb/libglvnd 的路径处理会出错）；产物对齐宿主
> glibc，~~需要 glibc 2.28 基线时使用 `FFBUILD_TOOLCHAIN_MODE=ctng`~~。

## 许可

沿用上游 [`LICENSE`](LICENSE)。
