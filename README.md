# 1-2-FFmpeg

简体中文 | [English](README_EN.md)

> [!NOTE]
> 修改过程中大量使用 AI agent。

基于 [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds) 的去 Docker 化版本：
直接在 Linux x86_64 主机上构建 FFmpeg 及其依赖。

仅支持 `linux64` 目标。上游的其余目标仍保留，但未经验证。

## 构建方法

### 前置

Debian/Ubuntu 系 x86_64 主机、bash、git 与 sudo（或 root）。构建前置依赖由 `setup.sh` 通过
apt 安装——gcc/g++/clang、autoconf/automake、cmake/meson、python3 及常用命令行工具；
发行版版本过旧的则源码构建进 `.buildtools/`。

`./native/setup.sh --check` 只报告所需与可选工具，不改动系统。

### 准备

```bash
./native/setup.sh          # 安装构建前置依赖并打印最终配置
./native/setup.sh --check
./native/download.sh       # 拉取依赖源码（内容哈希缓存）
```

### 开始构建

```bash
./build.sh 目标 变体 [附加项 [附加项] [附加项] ...]
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
* `4.4`/`5.0`/`5.1`/`6.0`/`6.1`/`7.0`/`7.1`/`8.0`/`8.1`/`9.0` 从对应 release 分支而非 master 构建。
* `debug` 不剥离调试符号，产物体积约增加 250MB。
* `lto` 对所有依赖与 ffmpeg 使用 -flto=auto（高度实验性，Windows 上不可用，Linux 上有时可行）。

### 编译器

```bash
FFBUILD_TOOLCHAIN_MODE=clang ./build.sh linux64 gpl
FFBUILD_TOOLCHAIN_MODE=gcc   ./build.sh linux64 gpl
FFBUILD_TOOLCHAIN_MODE=ctng  ./build.sh linux64 gpl   # 对齐 glibc 2.28 基线（未验证）
```

> [!NOTE]
> `host`（默认）按 `cc` → `gcc` → `clang` 探测，`CXX` 跟随同一家族；`clang` / `gcc` 只设置宿主
> 工具链的默认值；`ctng` 使用本地构建的 crosstool-ng 工具链（目前未验证），需先运行
> `./native/setup.sh --with-ctng`。`FFBUILD_CC` / `CC`（以及 `CXX`/`LD`/`AR` 等）可覆盖。
> 追加 Flag 用 `FFBUILD_EXTRA_CFLAGS`、`FFBUILD_EXTRA_LDFLAGS`。查看最终配置：
> `source native/env.sh && ffbuild_env_dump`；完整变量表见 `native/env.sh` 顶部注释。

### 设置代理

默认继承 shell 的代理设置（`http_proxy` / `https_proxy` / `all_proxy`）。

```bash
FFBUILD_PROXY=http://host:port ./native/download.sh   # 覆盖所有协议
FFBUILD_PROXY= ./native/download.sh                   # 忽略 shell 中的代理
```

> [!IMPORTANT]
> - `FFBUILD_ROOT` 路径不能包含 `.`（上游 libxcb/libglvnd 的路径处理会出错）。
> - 产物对齐宿主 glibc；~~需要 glibc 2.28 基线时使用 `FFBUILD_TOOLCHAIN_MODE=ctng`。~~
> - 构建不需要 root，删除仓库即可清理全部构建产物。

> `svn` 不读取这些变量（只认 `~/.subversion/servers`），因此 lame 与 xvid 两个阶段始终直连。

## 目录

```
ffbuild/{prefix,work,log,state,pkgroot}   构建根（FFBUILD_ROOT）
.buildtools/                              托管的构建工具，不入库
.cache/downloads/                         依赖源码缓存
artifacts/                                产物
```

## 许可

沿用上游 [`LICENSE`](LICENSE)。
