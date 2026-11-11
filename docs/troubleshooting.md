# 故障排查

简体中文 | [English](troubleshooting_EN.md)

## 先运行 `--check`

`./native/setup.sh --check` 为只读诊断：不安装软件包，不需要 sudo，也不修改仓库内容。重点关注以下内容：

- `[MISSING]`：必需项缺失。宿主工具与运行时前置会在下一行给出对应发行版的安装命令；托管构建工具缺失时提示重新运行 `./native/setup.sh`。
- `[absent]`：可选工具缺失，不影响构建。
- 退出码 1 表示存在阻塞项：必需宿主工具、运行时前置或托管构建工具缺失。Implib 与可选工具不计入退出码。

处理顺序：按提示补齐缺失项，重新运行 `--check`，确认退出码为 0 后再执行构建。

## C++23 编译失败

**症状**：构建 `openal-soft` 时编译失败，错误与 `std::string_view` 的范围构造或 `<ranges>` 相关。

**原因**：`openal-soft` 使用 C++23 的范围构造。发行版默认编译器可能不支持该特性；`--check` 会使用当前 `$CXX` 编译一段探测代码，可在构建前发现。

**处理**：

安装支持 C++23 的编译器（GCC 12 或更高）。使用 clang 时，其配套的 libstdc++ 头文件也需为 GCC 12 或更高版本。

例如：
- RHEL 8：系统默认的 GCC 8 不满足要求。安装仓库中可用的 `gcc-toolset`（版本依仓库而定），然后用 `scl enable <toolset> bash` 启用；或将 `FFBUILD_CC` / `FFBUILD_CXX` 指向 `/opt/rh/<toolset>/root/usr/bin/gcc` 与 `g++`。
- Ubuntu 22.04：系统默认的 GCC 11 不满足要求。安装 `gcc-12` 与 `g++-12`，然后设置 `FFBUILD_CC=gcc-12 FFBUILD_CXX=g++-12`。

修改后重新运行 `--check`，确认 `c++23 string_view` 一项通过。

## `50-shaderc` 构建失败（`c++` 与 `CXX` 不同）

**症状**：`47-vulkan/50-shaderc` 阶段失败，错误涉及 `std::filesystem` 的未定义引用；`openal` 的 C++23 检查可能已通过。

**原因**：该阶段的 native_build 先 `unset CC CXX`，再由 cmake 使用 PATH 上的 `c++`。`FFBUILD_CC` / `FFBUILD_CXX` 无法传递到这里，只设置这两个变量不改变该阶段的行为。

**处理**：把支持 C++17 的编译器放到 PATH 最前，例如 `source /opt/rh/<toolset>/enable` 或 `export PATH=<toolchain>/bin:$PATH`。`--check` 的 `host c++ (shaderc)` 一项会提前报告该问题。

## clang 构建时 `implib-gen` 报 `Unrecognized form`

**症状**：`40-libdrm`、`50-libva` 或 `45-x11` 阶段失败，输出包含：

```
implib-gen.py: error: readelf failed with retcode 0:
readelf: Warning: Unrecognized form: 0x22
```

**原因**：clang 默认生成 DWARF5 调试信息，宿主 binutils 的 `readelf` 不认识其中部分形式；`util/bin/gen-implib` 调用的 `implib-gen.py` 把 `readelf` 的任何 stderr 输出当作失败。

**处理**：让编译器生成旧版调试信息，例如 `FFBUILD_EXTRA_CFLAGS=-gdwarf-4 FFBUILD_EXTRA_CXXFLAGS=-gdwarf-4`；或升级宿主 binutils。

## `ar` 索引符号失败或 LLVMgold 版本过低

**症状**：归档或链接阶段 `ar` 报找不到符号；或 `--check` 报告 LLVMgold 插件低于 15。

**原因**：`librsvg` 的 Rust 静态库包含 LLVM bitcode，binutils 需要版本不低于 15 的 LLVMgold 插件才能索引其中的符号。

**处理**：

1. 升级 LLVM，使 LLVMgold 插件版本不低于 15。这是推荐做法。
2. 若不依赖其他组件的 LTO bitcode 索引，可临时移除 `/usr/lib/bfd-plugins/LLVMgold*.so`，让 bfd 读取归档中的原生符号表。该操作会影响其他依赖 LLVM bitcode 的构建；移除前请记录文件路径，以便通过重新安装 LLVM 恢复。
3. 重新运行 `--check`，确认 `llvm bfd plugin` 一项报告预期版本。

## OCaml `num` 包缺失

**症状**：`--check` 报告 OCaml `num` 缺失；或 `fftw3` 在配置阶段因缺少 `num` 失败。

**原因**：`fftw3` 在 maintainer 模式下使用 OCaml 的 `genfft` 生成 codelet，依赖 findlib 的 `num` 包。部分发行版不提供该包。

**处理**：

- 仓库提供该包时直接安装：Debian/Ubuntu 为 `libnum-ocaml-dev`，Arch 为 `ocaml-num`，Fedora 为 `ocaml-num`。
- 仓库不提供该包时（例如 RHEL 8、openSUSE Leap 16），无需安装发行版软件包。重新运行 `./native/setup.sh`，脚本会通过 opam 将 `num` 安装到 `.buildtools/opam/root`。
- `--check` 会区分“缺少 `num`”与“缺少 OCaml 工具链”。后者需先安装 `ocaml`、`findlib` 与 `ocamlbuild`。

## 使用官方发行源码包构建失败

**症状**：`FFMPEG_REPO` 指向官方发行源码包解出的目录时，FFmpeg 本体编译失败，错误指向某个依赖头文件的函数签名。例如：

```
libavcodec/liboapvenc.c:512:29: error: passing argument 1 of 'oapvm_create'
  from incompatible pointer type
```

**原因**：依赖阶段固定在当前上游修订，官方发行源码包则冻结在标签点。标签之后为兼容新依赖所做的修改只存在于发布分支。`RELEASE` 校验只比较主次版本与版本附加项，不检查依赖的 API。

**处理**：

1. 优先使用发布分支的检出：将 `FFMPEG_REPO` 指向该分支的工作树，或不设置 `FFMPEG_REPO` 并使用对应的版本附加项。
2. 必须使用该源码包时，跳过不兼容的阶段，例如 `FFBUILD_SKIP_STAGES=openapv`。被跳过的阶段同时从 FFmpeg 的 configure 参数中移除，产物不再包含对应功能。

## win32 构建提示 wine 无法运行 32 位程序

**症状**：`./build.sh win32 …` 在依赖构建前退出，提示 `wine cannot run 32-bit Windows binaries`。

**原因**：只安装了 64 位 wine。meson 的交叉文件把 wine 作为 `exe_wrapper`，而 win32 的目标程序是 32 位 PE；加载失败会使首次特性探测中断。

**处理**：安装 wine 的 32 位支持。`build.sh` 会在依赖构建前编译并运行一个最小 32 位程序，缺少该支持时立即退出。

> 发行版通常把 32 位支持拆成独立包，或要求先启用 32 位架构；例如 Debian / Ubuntu 需要启用 `i386` 架构后安装 `wine32`。具体包名以发行版为准。

## 无法在构建机上直接运行 linuxarm64 产物

**症状**：直接执行 `bin/ffmpeg` 报 `Exec format error`，或提示找不到动态链接器。

**原因**：产物是 aarch64 ELF，构建机通常是 x86_64；它依赖的目标 glibc 位于 ctng 的 sysroot 中，宿主链接器不适用。

**处理**：通过 qemu-user 运行，并把 sysroot 交给它：

```bash
QEMU_LD_PREFIX=.buildtools/ctng/linuxarm64/aarch64-ffbuild-linux-gnu/sysroot \
    qemu-aarch64 ./artifacts/.../bin/ffmpeg -version
```

共享变体还需要指向解包目录中的 `lib/`：

```bash
QEMU_LD_PREFIX=<sysroot> qemu-aarch64 -E LD_LIBRARY_PATH=<解包目录>/lib \
    <解包目录>/bin/ffmpeg ...
```

> 静态变体不需要 `LD_LIBRARY_PATH`。`setup.sh --check` 缺少 `qemu-aarch64` 时只作提示，不影响构建。

## win64 构建提示缺少 wine

**症状**：`./build.sh win64 …` 在依赖构建前退出，提示 `target 'win64' needs wine`；未使用 ctng 时则提示需要 `FFBUILD_TOOLCHAIN_MODE=ctng`。

**原因**：win64 只能由 crosstool-ng 工具链生成；meson 的交叉文件把 wine 作为 `exe_wrapper`，配置阶段需要运行目标程序（例如 glib 的特性探测）。

**处理**：运行 `./native/setup.sh --install --with-ctng --ctng-target win64`，它会安装 wine 并构建 win64 工具链；随后使用 `FFBUILD_TOOLCHAIN_MODE=ctng ./build.sh win64 …`。wine 也可以由发行版包管理器单独安装。

## 权限错误

**症状**：出现 `Permission denied`；或构建工具的 configure 阶段报 `C compiler cannot create executables`（例如 `m4`）。

**原因**：先前以 root 运行过 `setup.sh`，导致 `.buildtools/` 归 root 所有。普通用户随后没有写权限，configure 无法写入文件或生成可执行文件。

**处理**：在仓库根目录执行：

```bash
sudo chown -R "$USER" .
```

若个别工具仍有残留的半成品构建目录，删除对应目录（例如 `.buildtools/src/m4`）后重试。此后以普通用户运行 `setup.sh`；脚本仅在安装发行版软件包时调用 sudo。

## 安装依赖时引入额外的桌面与多媒体软件包

**症状**：dnf 解析出的软件包数量与下载量明显高于预期，结果中包含 `gtk3`、`libheif`、`ffmpeg-free` 系列组件等。

**原因**：dnf 默认安装弱依赖（Recommends）。构建依赖中的 `ant` 会引入 JDK 绑定，进而推荐完整 JDK；完整 JDK 推荐 `gtk3`，随后引入桌面与多媒体库。

**处理**：

- 脚本生成的安装命令已包含 `--setopt=install_weak_deps=False`。手工执行 `--print-packages` 的输出时，请保留该选项。
- zypper 对应选项为 `--no-recommends`，脚本已包含。
- apt 对应选项为 `--no-install-recommends`，脚本已包含。

## 下载缓慢、超时或代理未生效

**症状**：源码下载长时间无进度、超时失败，或已配置代理但连接仍未经过代理。

**原因**：代理变量未导出到运行环境；或下载工具不读取这些变量（`svn`）；或超时与重试参数不适合当前网络。

**处理**：

- 代理变量：`http_proxy`、`https_proxy`、`all_proxy`（含大写形式）由环境继承；`FFBUILD_PROXY` 可统一覆盖所有协议，设为空值表示不使用代理。确认变量已导出：
  ```bash
  env | grep -i proxy
  ```
- `svn`：`lame` 与 `xvid` 通过 svn 获取源码。svn 只读取自身配置，不读取上述环境变量，需要在 `~/.subversion/servers` 中配置：
  ```ini
  [global]
  http-proxy-host = proxy.example.com
  http-proxy-port = 8080
  ```
  也可在 svn 命令中传入 `--config-option servers:global:http-proxy-host=...` 与 `--config-option servers:global:http-proxy-port=...`。
- 重试参数：`RETRY_MAX`（默认 10 次）、`RETRY_TIMEOUT`（初始超时，默认 120 秒）、`RETRY_TIMEOUT_INC`（退避增量，默认 60 秒）、`RETRY_SLEEP_MAX`（最大退避，默认 90 秒）。这些变量对所有经 `retry-tool` 的取源生效，包括 `setup.sh` 的 opam、Implib、rustup、crosstool-ng 与托管工具源码，以及 `download.sh` 与 `build.sh`。HTTP 4xx 也会重试；调试镜像地址时可临时设 `RETRY_MAX=1`。详见 [build.md](build.md#缓存与重试)。

## Python venv 不完整

**症状**：`--check` 报告 `build venv` 的 pip 或 meson 不完整；或构建时提示找不到 meson。

**原因**：venv 创建中断、依赖安装失败，或解释器被替换。

**处理**：删除 `.buildtools/venv`，重新运行 `./native/setup.sh`。脚本会使用满足版本要求的宿主解释器重建 venv，并重新安装 meson 等构建期模块；此过程需要能够访问软件包索引。完成后用 `--check` 复核。

## 相关

- [配置构建环境](setup.md)
- [构建](build.md)
