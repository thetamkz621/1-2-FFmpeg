# native/buildtools.d/

FFmpeg 依赖阶段需要的**构建工具**，一个工具一份配方。与 `scripts.d/` 的区别：
`scripts.d/` 编的是 FFmpeg 的依赖库，这里编的是"编依赖库时用的工具"。

文件跑在 `native/buildtools.sh` 之下，命名 `NN-<tool>.sh`，`NN` 即构建顺序
（间隔 10，便于插入）。脚本会被 source 两次：一次取元数据、一次执行构建，因此
**顶层只能有变量赋值和函数定义**。

```bash
BT_VERSION="1.4.21"                       # 必填；git 源时为 commit
BT_URLS=( "https://…/m4-$BT_VERSION.tar.xz" )   # BT_URL 单地址，或 BT_URLS 回退列表
BT_SHA256="…"                             # 归档校验和；BT_SOURCE=git 时留空
# 可选：BT_SOURCE=git + BT_COMMIT、BT_BIN（默认=工具名）、BT_STRIP_COMPONENTS（默认 1）

bt_deps() { echo m4; }                    # 可选：依赖的工具名，仅用于顺序断言
bt_build() {                              # 必填：在解包目录里执行
    ./configure --prefix="$BT_PREFIX"
    make -j"$BT_JOBS"
    make install
}
```

约束：

- `bt_build` 里不要读写 `$FFBUILD_*`，只用 `$BT_PREFIX` / `$BT_JOBS` / `$BT_CACHE`。
- 不要 `sudo`、不要写系统目录、不要碰用户主目录。
- **不要往前缀里装 `*.pc`**：工具前缀不进 `PKG_CONFIG_LIBDIR`，一旦出现 .pc，
  驱动会报错（它意味着依赖构建可能把工具当库）。
- 安装前缀只有一份（`.buildtools/prefix`），PATH 里也只加这一条。
