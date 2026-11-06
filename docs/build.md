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

## 目标

| 目标 | 工具链 | 说明 |
|---|---|---|
| `linux64` | host `gcc` / `clang`，或 `ctng` | 同架构原生或交叉构建 |
| `win64` | 仅 `ctng` | 需要 wine；缺少 wine 或未使用 ctng 时 `build.sh` 直接退出 |

```bash
# linux64，宿主工具链
./build.sh linux64 gpl-shared 9.0

# linux64，crosstool-ng（glibc 2.28 基线）
./native/setup.sh --install --with-ctng
FFBUILD_TOOLCHAIN_MODE=ctng ./build.sh linux64 gpl-shared 9.0

# win64
./native/setup.sh --install --with-ctng --ctng-target win64
FFBUILD_TOOLCHAIN_MODE=ctng ./build.sh win64 gpl-shared 9.0
```

目标由 `build.sh` 的第一个参数决定；构建工具链时用 `setup.sh --ctng-target` 指定同一个目标。

## 编译器与工具链

| 变量 | 作用 |
|---|---|
| `FFBUILD_TOOLCHAIN_MODE` | `host`（默认，按 `cc` → `gcc` → `clang` 探测）/ `clang` / `gcc` / `ctng` |
| `FFBUILD_CC` `FFBUILD_CXX` `FFBUILD_LD` `FFBUILD_AR` … | 逐个覆盖编译器与工具（也可使用 `CC=` / `CXX=` 等） |
| `FFBUILD_TOOLCHAIN_TRIPLE` | 覆盖传递给 stage 的 `--host` 三元组 |
| `FFBUILD_CTNG_ROOT` | crosstool-ng 工具链位置，默认 `.buildtools/ctng/<target>`（不受 `FFBUILD_CLEAN` 影响） |

`clang` / `gcc` 仅设置宿主工具链的默认值；`ctng` 需先按目标运行 `./native/setup.sh --with-ctng --ctng-target <target>`。

> ctng 工具链位于 `.buildtools/ctng/<target>`；linux64 首次构建包含 glibc 与 GCC，win64 包含 mingw-w64 与 GCC。  
> 裁剪在依赖构建前执行，因此 `soxr` 与 `vidstab` 按串行编译；宿主 `gcc` / `clang` 模式不受影响。  
> win64 的 meson 阶段通过 wine 运行目标程序；缺少 wine 时 `build.sh` 在依赖构建前退出。

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

构建根使用 `<target>:<compiler>` 标记。host 与 ctng、linux64 与 win64 不能共用一个构建根；切换时使用独立的 `FFBUILD_ROOT`，或设置 `FFBUILD_CLEAN=1`。

## FFmpeg 源码

`FFMPEG_REPO` 指定 FFmpeg 源码，默认 `https://github.com/FFmpeg/FFmpeg.git`。

| 取值 | 行为 |
|---|---|
| 远程 git 地址 | 克隆版本附加项对应的分支（默认 `master`）；`GIT_BRANCH_OVERRIDE` 覆盖该分支 |
| 本地 git 仓库 | 克隆该仓库并检出其当前 `HEAD`；设置 `GIT_BRANCH_OVERRIDE` 时改为检出该分支或提交 |
| 本地普通目录 | 复制到构建根；目录必须包含 `configure` |
| 不存在的路径 | 报错退出 |

- 源码始终复制或克隆到 `$FFBUILD_ROOT/ffmpeg`，原目录不会被修改。
- 本地 git 仓库中未提交的改动不会进入构建；需要包含这些改动时，将工作树复制为普通目录后指向该副本。
- 源码根含 `RELEASE` 时，其主次版本必须与版本附加项一致（例如 `RELEASE` 为 `8.1.1` 时传入 `8.1`），否则构建退出。
- `GIT_BRANCH_OVERRIDE` 对本地普通目录无效。
- 源码既无 `RELEASE` 也不是 git 仓库时，`ffbuild/version.sh` 会把产物版本记为 `N`。

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
| `.buildtools/ctng/<target>` | crosstool-ng 工具链（`ctng` 模式） |
| `.buildtools/` | 托管构建工具、venv、Rust、opam |
| `.cache/downloads/` | 源码缓存 |
| `artifacts/` | 构建产物 |

产物名称：

```
artifacts/ffmpeg-<版本>-<目标>-<变体>[-<附加项>]-<编译器或工具链>-<日期>.tar.xz
```

> 该字段在宿主 `gcc` / `clang` 模式下为 `gcc` / `clang`，在 `ctng` 模式下为 `ctng`。  
> `win64` 产物为 `bin/*.exe` 与 `bin/*.dll`，导入库在 `lib/`；运行时依赖 UCRT，不依赖 libgcc、libstdc++ 或 winpthread 的 DLL。

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

这些参数对所有取源生效：`setup.sh`（opam、Implib.so、rustup、crosstool-ng 与托管构建工具源码）、`download.sh`、`build.sh` 以及 `buildtools.sh` 都经 `retry-tool` 下载。

未显式设置时，`download.sh` 使用 600 秒超时与 8 次尝试，`setup.sh` 与 `buildtools.sh` 使用 600 秒超时。HTTP 4xx 同样按重试次数退避；调试镜像地址时可临时设 `RETRY_MAX=1`。
