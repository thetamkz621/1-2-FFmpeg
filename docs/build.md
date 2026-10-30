# 构建

简体中文 | [English](build_EN.md)

```bash
./build.sh <目标> <变体> [附加项 ...]

./build.sh linux64 gpl
./build.sh linux64 lgpl 8.1
./build.sh linux64 gpl-shared debug
```

可用目标、变体与附加项见 [README](../README.md#目标变体与附加项)。

构建开始前会自动跑 `native/download.sh --needed <目标> <变体>` 拉取所需源码；
`FFBUILD_SKIP_DOWNLOAD=1` 可以跳过（复用已有缓存），`FFBUILD_FFMPEG_ONLY=1` 也会跳过。

## 编译器与工具链

| 变量 | 作用 |
|---|---|
| `FFBUILD_TOOLCHAIN_MODE` | `host`（默认，按 cc → gcc → clang 探测）/ `clang` / `gcc` / `ctng` |
| `FFBUILD_CC` `FFBUILD_CXX` `FFBUILD_LD` `FFBUILD_AR` … | 逐个覆盖编译器与工具（也可直接用 `CC=` / `CXX=`） |
| `FFBUILD_TOOLCHAIN_TRIPLE` | 覆盖传给 stage 的 `--host` 三元组 |
| `FFBUILD_CTNG_ROOT` | ctng 工具链位置，默认 `$FFBUILD_ROOT/ctng` |

`clang` / `gcc` 只是给宿主工具链设默认值；`ctng` 需要先
`./native/setup.sh --with-ctng`，目前未验证。

带版本号的编译器可以直接指过去：

```bash
FFBUILD_CC=gcc-12 FFBUILD_CXX=g++-12 ./build.sh linux64 gpl
```

## 编译参数

| 变量 | 语义 |
|---|---|
| `FFBUILD_CFLAGS` / `FFBUILD_CXXFLAGS` / `FFBUILD_LDFLAGS` / `FFBUILD_LDEXEFLAGS` | **替换**内置默认值 |
| `FFBUILD_EXTRA_CFLAGS` / `_CXXFLAGS` / `_LDFLAGS` / `_LDEXEFLAGS` | 在生效值上**追加** |
| `FFBUILD_EXTRA_STAGE_CFLAGS` / `_CXXFLAGS` / `_LDFLAGS` | 追加到每个 stage 的参数 |

完整变量表见 `native/env.sh` 顶部注释。查看最终生效的配置：

```bash
source native/env.sh && ffbuild_env_dump
```

## 构建控制

| 变量 | 作用 |
|---|---|
| `FFBUILD_CLEAN=1` | 构建前清空 `FFBUILD_ROOT` |
| `FFBUILD_FORCE=1` | 忽略断点状态，重建所有 stage |
| `FFBUILD_DEPS_ONLY=1` | 只构建依赖，不编 FFmpeg |
| `FFBUILD_FFMPEG_ONLY=1` | 跳过依赖，复用现有 prefix |
| `FFBUILD_SKIP_DOWNLOAD=1` | 不刷新下载缓存 |
| `FFBUILD_JOBS=<N>` | 并行数，默认 `nproc` |
| `FFBUILD_ROOT=<path>` | 构建根，默认 `<repo>/ffbuild`；路径里不能有 `.` |
| `FFBUILD_BUILD_DATE=YYYYMMDD` | 固定产物名里的日期 |

## 目录与产物

| 路径 | 内容 |
|---|---|
| `ffbuild/prefix` | 依赖的安装前缀（`PKG_CONFIG_LIBDIR` 指向它） |
| `ffbuild/work` | 各 stage 的解包与编译目录 |
| `ffbuild/log` | 每个 stage 的日志 |
| `ffbuild/state` | 断点续建用的状态 |
| `ffbuild/destdir` | 每个 stage 的 `DESTDIR`，结束后合并进 `prefix` |
| `ffbuild/pkgroot` | 打包暂存目录 |
| `ffbuild/ctng` | crosstool-ng 工具链（`ctng` 模式） |
| `.buildtools/` | 托管工具、venv、rust、opam |
| `.cache/downloads/` | 源码缓存 |
| `artifacts/` | 产物 |

产物名：

```
artifacts/ffmpeg-<版本>-<目标>-<变体>[-<附加项>]-<编译器>-<日期>.tar.xz
```

版本取自 FFmpeg 的 `ffbuild/version.sh`：发布分支上是 `nX.Y.Z`，master 上是
`<commit>-<描述>`。

## 缓存与重试

`.cache/downloads/` 按内容寻址：`<stage>_<hash>.tar.xz` 加一个 `<stage>.tar.xz`
软链。常用的两条命令：

```bash
./native/download.sh --needed linux64 gpl   # 只取这个目标需要的源码
./native/download.sh hashonly               # 打印缓存键
```

弱网下可以调 `util/bin/retry-tool` 的参数：`RETRY_MAX`（默认 10 次）、
`RETRY_TIMEOUT`（首次超时，默认 120 秒）、`RETRY_TIMEOUT_INC`（每次递增，默认 60 秒）、
`RETRY_SLEEP_MAX`（最大退避，默认 90 秒）。
