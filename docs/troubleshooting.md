# 常见失败

简体中文 | [English](troubleshooting_EN.md)

## 先看 `--check`

`./native/setup.sh --check` 是只读的，不装包也不需要 sudo。它给出的
`[MISSING]` 行下面就是对应发行版的安装命令，先照着补齐再谈别的。

## `string_view` / C++23 编译失败

`openal-soft` 用到 C++23 的范围构造。`--check` 会拿当前 `$CXX` 实测这段代码：

- EL8：系统 gcc 8.5 不够。用 `scl enable gcc-toolset-15 bash`，或者
  `FFBUILD_CC=/opt/rh/gcc-toolset-15/root/usr/bin/g FFBUILD_CXX=.../g++`。
- Ubuntu 22.04：装 `gcc-12`，然后 `FFBUILD_CC=gcc-12 FFBUILD_CXX=g++-12`。

## `ar` 报找不到符号 / LLVMgold 版本过低

`librsvg` 的 Rust 静态库带 LLVM bitcode，binutils 需要 LLVMgold ≥ 15 才能索引。
要么把 llvm 升到 15 以上，要么删掉 `/usr/lib/bfd-plugins/LLVMgold*.so`，让 bfd 读
原生符号表。`--check` 会报出实际版本。

## OCaml 的 `num` 包缺失

Debian/Arch 直接有 `libnum-ocaml-dev` / `ocaml-num`；EL8 与 Leap 16 的仓库里没有，
setup 会用 opam 把 num 装到 `.buildtools/opam/root`。`--check` 报"该发行版没有 num 包"
时，重跑 `./native/setup.sh` 即可，不用去装系统包。

## `Permission denied` / `C compiler cannot create executables`

多半是之前用 root 跑过 `setup.sh`：`.buildtools/` 归 root，普通用户再跑就写不进去，
在 m4 的 configure 阶段表现成"`C compiler cannot create executables`"。

```bash
sudo chown -R "$USER" .
```

之后用普通用户跑（sudo 只在装包时由脚本自己调用）。

## 装包时拉进一堆桌面/多媒体库

dnf 默认装 Recommends：`ant` 会沿 `java-devel → 完整 JDK → gtk3 → libheif →
libheif-ffmpeg` 把 ffmpeg-free 全家拉进来，包数和下载量翻倍。脚本安装时已经带上
`--setopt=install_weak_deps=False`；按 `--print-packages` 的输出手抄命令时别漏掉。
zypper 对应的是 `--no-recommends`。

## 下载慢、超时、代理不生效

- 托管工具与依赖源码都受 `http_proxy` / `https_proxy` / `FFBUILD_PROXY` 控制；
  先确认 shell 里真的导出了（`env | grep -i proxy`）。
- `svn` 不读环境变量（lame、xvid 两个阶段），要写 `~/.subversion/servers`。
- 超时时间与重试次数可调，见 [build.md](build.md#缓存与重试)。

## venv 残缺

`--check` 报 venv 不完整时，删掉 `.buildtools/venv` 后重跑 `./native/setup.sh`；
它会用宿主解释器重建。

## 相关

- [安装构建环境](setup.md)
- [构建](build.md)
