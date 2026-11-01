# 构建

简体中文 | [English](build_EN.md)

```bash
./build.sh <目标> <变体> [附加项 [附加项] [附加项] ...]

./build.sh linux64 gpl
./build.sh linux64 lgpl 8.1
./build.sh linux64 gpl-shared debug
```

可用目标、变体与附加项见 [README](../README.md#目标、变体与附加项)。

构建开始前会自动运行 `native/download.sh --needed <目标> <变体>` 获取所需源码；`FFBUILD_SKIP_DOWNLOAD=1` 可跳过该步骤（复用已有缓存），`FFBUILD_FFMPEG_ONLY=1` 同样会跳过。

## 编译器与工具链

| 变量 | 作用 |
|---|---|
| `FFBUILD_TOOLCHAIN_MODE` | `host`（默认，按 `cc` → `gcc` → `clang` 探测）/ `clang` / `gcc` / `ctng` |
| `FFBUILD_CC` `FFBUILD_CXX` `FFBUILD_LD` `FFBUILD_AR` … | 逐个覆盖编译器与工具（也可使用 `CC=` / `CXX=` 等） |
| `FFBUILD_TOOLCHAIN_TRIPLE` | 覆盖传递给 stage 的 `--host` 三元组 |
| `FFBUILD_CTNG_ROOT` | crosstool-ng 工具链位置，默认 `$FFBUILD_ROOT/ctng` |

`clang` / `gcc` 仅设置宿主工具链的默认值；`ctng` 需先运行 `./native/setup.sh --with-ctng`。（**目前未验证**）

## 编译参数

| 变量 | 语义 |
|---|---|
| `FFBUILD_CFLAGS` / `FFBUILD_CXXFLAGS` / `FFBUILD_LDFLAGS` / `FFBUILD_LDEXEFLAGS` | **替换**内置默认值 |
| `FFBUILD_EXTRA_CFLAGS` / `FFBUILD_EXTRA_CXXFLAGS` / `FFBUILD_EXTRA_LDFLAGS` / `FFBUILD_EXTRA_LDEXEFLAGS` | 在生效值上**追加** |
| `FFBUILD_EXTRA_STAGE_CFLAGS` / `FFBUILD_EXTRA_STAGE_CXXFLAGS` / `FFBUILD_EXTRA_STAGE_LDFLAGS` | 追加到各 stage 的参数 |
| `FFBUILD_EXTRA_LIBS` | 追加到 FFmpeg 链接命令的库 |

> `FFBUILD_CFLAGS` 等替换默认值时，默认值中的 `-I$FFBUILD_PREFIX/include` 也会被一并替换；如需追加选项，请使用 `FFBUILD_EXTRA_*`。

## 构建控制

| 变量 | 作用 |
|---|---|
| `FFBUILD_CLEAN=1` | 构建前清空 `FFBUILD_ROOT`（**⚠️ 谨慎使用**） |
| `FFBUILD_FORCE=1` | 忽略断点续建状态，重建全部 stage |
| `FFBUILD_DEPS_ONLY=1` | 仅构建依赖，不构建 FFmpeg |
| `FFBUILD_FFMPEG_ONLY=1` | 跳过依赖，复用现有 prefix |
| `FFBUILD_SKIP_DOWNLOAD=1` | 不刷新下载缓存 |
| `FFBUILD_JOBS=<N>` | 并行任务数，默认 `nproc` |
| `FFBUILD_ROOT=<path>` | 构建根，默认 `<repo>/ffbuild`；路径不能包含 `.` |
| `FFBUILD_BUILD_DATE=YYYYMMDD` | 固定产物名称中的日期 |
| `FFBUILD_SKIP_STAGES=a,b` | 跳过指定 stage，以逗号或空格分隔（例如缺少 Rust 时跳过 `rav1e` 与 `librsvg`） |
| `FFBUILD_EXTRA_VERSION=<str>` | 传递给 FFmpeg 的 `--extra-version`，默认 `YYYYMMDD`；影响 `ffmpeg -version` 输出，不影响产物名称 |

## 网络

| 变量 | 作用 |
|---|---|
| `FFBUILD_PROXY` | 统一覆盖所有协议的代理；未设置时继承当前 shell 的 `http_proxy` / `https_proxy` / `all_proxy`（含大写形式）；设为空值表示禁用代理 |
| `FFBUILD_NO_PROXY` | 覆盖 `no_proxy`；默认空值，不额外添加 |

完整变量表见 `native/env.sh` 顶部注释。查看最终生效的配置（需在 bash 下）：

```bash
source native/env.sh && ffbuild_env_dump
```

## 目录与产物

| 路径 | 内容 |
|---|---|
| `ffbuild/prefix` | 依赖的安装前缀（`PKG_CONFIG_LIBDIR` 指向此目录） |
| `ffbuild/work` | 各 stage 的解包与编译目录 |
| `ffbuild/log` | 各 stage 的日志 |
| `ffbuild/state` | 断点续建状态 |
| `ffbuild/destdir` | 各 stage 的 `DESTDIR`，stage 结束后合并到 `prefix` |
| `ffbuild/pkgroot` | 打包暂存目录 |
| `ffbuild/ctng` | crosstool-ng 工具链（`ctng` 模式） |
| `.buildtools/` | 托管构建工具、venv、Rust、opam |
| `.cache/downloads/` | 源码缓存 |
| `artifacts/` | 构建产物 |

产物名称：

```
artifacts/ffmpeg-<版本>-<目标>-<变体>[-<附加项>]-<编译器>-<日期>.tar.xz
```

## 缓存与重试

`.cache/downloads/` 采用内容寻址：`<stage>_<hash>.tar.xz`，并附带一个 `<stage>.tar.xz` 软链接。

常用命令：

```bash
./native/download.sh --needed linux64 gpl   # 仅获取该目标所需的源码
./native/download.sh hashonly               # 打印缓存键
```

网络状况不佳时，可调整以下参数（由 `util/bin/retry-tool` 使用）：

| 变量 | 作用 |
|---|---|
| `RETRY_MAX` | 最大尝试次数，默认 `10` |
| `RETRY_TIMEOUT` | 初始超时时间（秒），默认 `120` |
| `RETRY_TIMEOUT_INC` | 退避增量（秒），默认 `60` |
| `RETRY_SLEEP_MAX` | 最大退避时间（秒），默认 `90` |

这些参数仅影响经 `retry-tool` 的下载，即 `download.sh` 与 `build.sh`；`setup.sh` 自身的下载当前不受其控制。
