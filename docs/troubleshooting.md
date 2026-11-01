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
- RHEL 8：系统默认的 GCC 8 不满足要求。安装仓库中可用的 `gcc-toolset`（版本依仓库而定），然后用 `scl enable <toolset> bash` 启用；或将 `FFBUILD_CC` / `FFBUILD_CXX` 指向 `/opt/rh/<toolset>/root/usr/bin/gcc` 与 `g++`。若已安装 toolset，`--check` 的提示会给出其路径与启用方式。
- Ubuntu 22.04：系统默认的 GCC 11 不满足要求。安装 `gcc-12` 与 `g++-12`，然后设置 `FFBUILD_CC=gcc-12 FFBUILD_CXX=g++-12`。

修改后重新运行 `--check`，确认 `c++23 string_view` 一项通过。

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
- 重试参数：`RETRY_MAX`（默认 10 次）、`RETRY_TIMEOUT`（初始超时，默认 120 秒）、`RETRY_TIMEOUT_INC`（退避增量，默认 60 秒）、`RETRY_SLEEP_MAX`（最大退避，默认 90 秒）。这些变量仅影响经 `retry-tool` 的取源，即 `download.sh` 与 `build.sh`；`setup.sh` 自身下载的 opam、Implib 与托管工具当前不受这些变量控制。详见 [build.md](build.md#缓存与重试)。

## Python venv 不完整

**症状**：`--check` 报告 `build venv` 的 pip 或 meson 不完整；或构建时提示找不到 meson。

**原因**：venv 创建中断、依赖安装失败，或解释器被替换。

**处理**：删除 `.buildtools/venv`，重新运行 `./native/setup.sh`。脚本会使用满足版本要求的宿主解释器重建 venv，并重新安装 meson 等构建期模块；此过程需要能够访问软件包索引。完成后用 `--check` 复核。

## 相关

- [配置构建环境](setup.md)
- [构建](build.md)
