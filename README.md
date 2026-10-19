# cross

**cross** 是一个 [Zig](https://ziglang.org/) 0.17.x 的交叉编译构建辅助库：给定一个 Zig 编译目标
（target），自动定位对应的 SDK / sysroot（Android NDK、OpenHarmony NDK、Emscripten SDK），配置
include 路径、库搜索路径、libc 配置文件（`*-libc.conf`）、crt/运行时补丁和必要的编译宏，让
`zig build` 能够真正完成交叉编译与链接。

它不是独立程序，而是作为依赖引入到你自己的 `build.zig` 中使用。

## 支持的平台

| 平台 | 目标识别 | 工具链来源 | 支持架构 |
|---|---|---|---|
| Android | `*-linux-android*` ABI | `ANDROID_NDK_HOME`（或 `Options.android_sysroot`） | aarch64, arm/thumb, x86_64, x86, riscv64 |
| OpenHarmony (OHOS) | `*-linux-ohos` ABI，或 `-Dohos=true` + `*-linux-musl` | `OHOS_NDK_HOME`（或 `Options.ohos_sysroot`） | aarch64, arm/thumb, x86_64 |
| Emscripten | `wasm32/64-emscripten` | `EMSDK`（或 `Options.emsdk_sysroot`） | wasm32, wasm64 |
| Native | 其它所有目标 | 系统自带 | — |

## 引入方式

通过 GitHub Releases 引入，运行一次即可自动计算 hash 并写入 `build.zig.zon`：

```powershell
zig fetch --save https://github.com/xingluo233/cross-zig/releases/download/v1.0.2/cross-v1.0.2.tar.gz
```

引入后，`build.zig` 中通过 `const cross = @import("cross");` 使用（见下节）。

## 快速开始

在你的 `build.zig` 中：

```zig
const std = @import("std");
const cross = @import("cross");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = cross.Options{
        .ohos = b.option(bool, "ohos", "Use the OpenHarmony NDK (OHOS_NDK_HOME) for a linux-musl target") orelse false,
    };

    // 解析目标并定位 SDK（失败时会打印具体原因）
    const config = cross.TargetConfig.init(b, target, options) catch |err| {
        std.log.err("cross.TargetConfig.init failed: {s}", .{@errorName(err)});
        @panic("see error above");
    };

    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/main.c"),
        .flags = &.{},
    });

    // 配置编译（include 路径、库路径、libc 配置、宏、crt/运行时补丁）
    config.configureCompile(exe);

    // 需要 translate-c 时同样配置
    const tc = b.addTranslateC(.{
        .root_source_file = b.path("src/headers.h"),
        .target = target,
        .optimize = optimize,
    });
    config.configureTranslateC(tc);

    b.installArtifact(exe);
}
```

然后设置 SDK 环境变量并按目标构建：

```powershell
# Windows PowerShell 示例
$env:ANDROID_NDK_HOME = "D:\Android\Sdk\ndk\30.0.15729638"
$env:OHOS_NDK_HOME   = "D:\OpenHarmony\Sdk\26.0.0\native"
$env:EMSDK           = "D:\emsdk"

zig build "-Dtarget=aarch64-linux-android.35"   # Android (注意 target 带版本时需用引号)
zig build "-Dtarget=x86-linux-android.35"        # Android 32 位 x86
zig build "-Dtarget=aarch64-linux-musl" -Dohos  # OpenHarmony（见下文说明）
zig build -Dtarget=wasm32-emscripten             # WebAssembly
zig build -Dtarget=wasm64-emscripten             # WebAssembly
```

## API

### `TargetConfig`

```zig
pub fn init(b: *std.Build, target: std.Build.ResolvedTarget, options: Options) !TargetConfig
pub fn configureCompile(self: TargetConfig, compile: *std.Build.Step.Compile) void
pub fn configureTranslateC(self: TargetConfig, translate_c: *std.Build.Step.TranslateC) void
pub fn isNative(self: TargetConfig) bool
```

- `configureCompile` 会添加：系统 include 路径、库搜索路径、libc 配置文件（`setLibCFile`）、
  平台宏（`_FORTIFY_SOURCE`/`__ANDROID_API__`/`__MUSL__` 等）、以及针对各端
  的 crt / 运行时补丁。
- 链接系统库时一律显式 `use_pkg_config = .no`：Android 的 `unwind`/`builtins`/`atomic` 和 OHOS 的
  `clang_rt.builtins` 都来自 NDK，而不是宿主机。`linkSystemLibrary` 的默认值是 `.yes`，宿主机只要
  装了不可用的 `pkg-config`（Windows 上很常见），交叉链接就会直接失败。
- `configureTranslateC` 只配置 include 路径与宏，供 `b.addTranslateC` 使用。
- `TargetConfig.init` 需要在配置阶段调用，后续构建过程即可正常使用。
- `TargetConfig` 里的路径都分配在构建的 arena 上（`b.allocator` 就是它），构建结束自动回收，
  所以没有 `deinit`。

### `Options`

```zig
pub const Options = struct {
    ohos: bool = false,              // 对 linux-musl 目标强制走 OHOS NDK
    android_sysroot: ?[]const u8 = null,  // 覆盖 ANDROID_NDK_HOME，指向 $NDK/toolchains/llvm/prebuilt/<host>/sysroot 或等价物
    ohos_sysroot: ?[]const u8 = null,     // 覆盖 OHOS_NDK_HOME，指向 OHOS sysroot
    emsdk_sysroot: ?[]const u8 = null,    // 覆盖 EMSDK，指向 Emscripten sysroot
};
```

环境变量为默认来源；显式传入 sysroot 时跳过环境变量探测。

## 各平台说明

### Android

- 架构映射：`aarch64-linux-android`、`x86_64-linux-android`、`arm-linux-androideabi`（arm/thumb）、
  `i686-linux-android`（x86，位于 NDK 目录）、`riscv64-linux-android`。
- **API level**：默认取 zig 目标的 API 级别。cross 不硬编码 API 限制——每个 NDK 版本支持的
  最高 API 不同（r29 最高 35、r30-beta2 最高 36、r30-beta3 最高 37），且 riscv64 只提供该
  版本的最高 API 目录（它只支持最新 API）；cross 直接检查目录是否存在，不存在时列出该架构
  实际可用的 API 级别，并给出建议的 `-Dtarget`。
- **静态 libc 布局适配**：zig 链接静态 bionic 时，lld 的库搜索路径来自 libc 配置的 `crt_dir`
  加上 cross 显式添加的 `-L`；而 NDK 把静态档案（`libc.a`/`libm.a`/`libdl.a`）、crt 对象
  （`crtbegin_static.o` 等）和 `libunwind.a` / compiler-rt builtins 分散在两三个目录。
  cross 用一个 `WriteFile` 步骤把这些文件合并到一个 **生成目录**：目录位置由 Zig 的缓存
  管理决定（默认 `<构建根>/.zig-cache/o/<hash>/`，`--cache-dir` / `ZIG_LOCAL_CACHE_DIR`
  会自动生效），配置阶段不再直接读写本地缓存。合并目录把 crt 对象、静态 libc 档案、
  `libunwind.a`、重命名后的 `libbuiltins.a`（compiler-rt）以及 `libatomic.a` 合一，
  同时链接 `unwind`/`builtins`/`atomic`。
- 产物为静态链接 libc 的可执行文件（EXEC），可直接在设备上运行，也可改为 napi `.so` 供应用加载。
- **Windows 上链接 NDK 共享库的临时办法**：zig 0.17.0 会把 `-L` 中匹配到的 `.so` 以
  `-l:<绝对路径>` 传给 lld，Windows 盘符里的冒号让 lld 报
  `unable to find library -l:D:\...\liblog.so`。这是 zig 的上游 bug（
  [issue #37257](https://codeberg.org/ziglang/zig/issues/37257)，预计 0.17.1 修复），不是 cross
  的行为。修复前可以用 `addObjectFile` 直接链接 `.so` 作为临时方案：

  ```zig
  exe.root_module.addObjectFile(b.graph.cwdRelativePath(
      b.pathJoin(&.{ android_config.paths.lib_api, "liblog.so" }),
  ));
  ```

  静态库（`.a`）不受影响，`linkSystemLibrary` 可以继续正常用于它们。

### OpenHarmony

- **重要**：Zig 0.17 虽然能解析 `.ohos` ABI，但还没有真正可用——只要目标需要
  `emutls`（`compiler_rt`），就会在 `std/c.zig` 的 `pthread_mutex_t` 处报
  `unsupported ABI` 而失败。因此当前使用方式仍是：

  ```powershell
  zig build "-Dtarget=aarch64-linux-musl" -Dohos
  ```

  即目标 ABI 用 zig 认识的 `musl`，头文件与库全部来自 OHOS NDK sysroot。产物与 OHOS 官方
  NDK静态链接产物**二进制同构**（相同的 `.note.ohos.ident`、相同的
  `__emutls_get_address` 等符号、同款段布局），可在鸿蒙设备上直接运行；应用场景下建议打包为
  napi `.so` 供 `.hap` 加载。
- 自动探测 OHOS NDK clang 版本目录并静态链接 `clang_rt.builtins`（否则静态链接 libc.a 会遇到
  `undefined symbol: __emutls_get_address`）。
- 宏：`__MUSL__=1`；非 Debug 额外定义 `NDEBUG=1`。

### Emscripten

- **必须先由 emcc 生成 cache sysroot**：cross 只接受完整的
  `$EMSDK/upstream/emscripten/cache/sysroot`（`include/` + `lib/<triple>/`）。
  未运行过 `emcc`（或 cache 不完整）会直接报错：
  ```powershell
  emcc -v    # 任何一次调用即可生成 cache sysroot
  ```
- 路径解析顺序：`Options.emsdk_sysroot` > `$EMSDK/upstream/emscripten/cache/sysroot`；
  显式 sysroot 同样要求 `include/` 与 `lib/<triple>/` 完整。
- **只支持 object / 静态库**：Zig 的 wasm libc 不提供 Emscripten `crt1.o` 需要的符号
  （例如 `exit`），所以 cross 无法链接 Emscripten 可执行产物；构建 `.exe` / `.test` 目标会
  直接给出明确错误。需要可执行文件时请先用 `zig build` 产出 object，再用 `emcc` 链接。
  `tests/smoke` 在 emscripten 下正是以 object 形式交付。
- 宏：不需要额外注入，`__EMSCRIPTEN__` 由 Zig 目标本身定义。
- **不要为 wasm 目标构建 `dynamic` 库**：wasm-ld 对 `-shared` 只会给一句
  "creating shared libraries, with -shared, is not yet stable" 警告，而 zig 会把这段 lld
  stderr 当成错误、把对应 step 标记为 failure —— 但 `zig build` 的**退出码仍然是 0**。
  `tests/smoke` 因此在 emscripten 下跳过共享库；`scripts/ci-smoke.sh` 另外扫描构建日志里的
  `error:` / `failure` 行，避免这类失败被退出码掩盖。

## Smoke 示例

`tests/smoke/` 是一个完整的使用示例（path 依赖 `../..`），用一个 C 程序 `main.c` 和 translate-c 目标
`headers.h` 验证：编译、转译、宏注入、链接均正常。`main.c` 编译为可执行产物（emscripten 下
为 object），`lib.c` 同时构建静态库与共享库（emscripten 下不含共享库，原因见上文）。

```powershell
cd tests/smoke

# 单元测试（在仓库根目录）
cd ../..
zig build test

# 冒烟构建（任一目标）
cd tests/smoke
zig build                                        # native
zig build "-Dtarget=aarch64-linux-android.35"    # Android
zig build -Dtarget=wasm32-emscripten              # Emscripten（仅生成 object）
zig build "-Dtarget=aarch64-linux-musl" -Dohos    # OpenHarmony
zig build run                                     # native 直接运行
```

`headers.h` 会校验 Android 下 `__ANDROID_API__` / `__ANDROID_MIN_SDK_VERSION__` 宏已注入；
`main.c` 会校验 musl / Android / Emscripten 下的 `<sys/socket.h>` 可用。

## 测试

```powershell
zig build test     # 或 zig test src/tests.zig
```

覆盖：目标分类（`classify`）、各平台 triple/架构名、宏定义、clang 版本解析与排序、
文件系统 helper、工具链版本目录探测等（17 个测试）。需要真实 SDK 的
路径探测通过 `tests/smoke` 在相应机器上验证。

## 目录结构

```
build.zig          # 入口：导出 TargetConfig / Options 及各平台模块
build.zig.zon      # 包定义：名称、版本（发版 tag 需与之一致）、paths
src/
  target.zig       # 目标分类、TargetConfig 联合类型、宏注入
  platform.zig     # 公共逻辑：libc.conf 生成、目录检查、版本解析
  libc_conf.zig    # 构建期小工具：在 make 阶段渲染 *-libc.conf
  android.zig      # Android NDK：路径解析、API 规则、静态 libc 合并目录
  ohos.zig         # OpenHarmony：sysroot 解析、clang builtins 探测
  emscripten.zig   # Emscripten：cache sysroot 解析、仅支持 object/静态库
  tests.zig        # 测试聚合入口
tests/smoke/         # 端到端验证示例（C 源 + 多目标构建）
scripts/
  ci-smoke.sh      # 全目标冒烟矩阵脚本
.github/workflows/
  ci.yml           # CI：lint + 单测 + 冒烟矩阵
  release.yml      # 自动发版：v* 标签触发，打包源码并发布变更说明
```

## 构建缓存与 SDK 变更

- cross 的配置阶段只读地探测 SDK；探测到的目录（SDK 根、`lib/clang` 版本目录、
  `lib/linux/<arch>`、API level 目录等）通过 Zig 的 `dependOnDirectoryMetadata` 登记为
  配置依赖，目录条目变化（新增 API level、clang 版本目录、`libatomic.a` 出现等）会自动
  触发重新配置。文件级变化由它们所在目录的条目跟踪，避免对不存在的可选文件登记依赖。
- **环境变量本身不在 Zig 的配置缓存键里**。把 `ANDROID_NDK_HOME`、`OHOS_NDK_HOME` 或
  `EMSDK` 换成另一套 SDK 后，如果旧 SDK 目录仍然存在且未变化，配置缓存可能继续指向旧路径。
  此时用 `zig build --cache-poison=poisoned`（或删除 `.zig-cache`）强制重新配置。
- 生成目录（Android 合并目录、OHOS crt shim、`*-libc.conf`）全部由 Zig 的缓存管理决定位置，
  跟随 `--cache-dir` / `ZIG_LOCAL_CACHE_DIR`；配置阶段不再直接写本地缓存。
- `*-libc.conf` 由 make 阶段的 helper 生成，其参数通过 `make_absolute = true` 交给 build
  runner 解析。不支持把 Run 参数绝对化的 host 会收到明确的 `AbsolutePathRequired` 错误，
  而不是写出一份路径错误的配置。
- 不要把全局缓存放到 build root 内（例如 `ZIG_GLOBAL_CACHE_DIR=zig-pkg` 指向项目里的
  `zig-pkg`）。相对形式的全局缓存路径会让 libunwind 等子编译的临时文件解析失败，报
  `unable to make temporary file: Permission denied`；用默认全局缓存即可。

## 已知限制

- `-Dtarget=aarch64-linux-ohos` 目前仍不可用：Zig 0.17 能解析该 ABI，但 `compiler_rt`
  需要的 `emutls` 会在 `std/c.zig` 报 `unsupported ABI`。
  请继续使用 `-Dohos` + `linux-musl`；待上游补全 `.ohos` 的 `pthread_mutex_t` 后即可切换。
- Zig 0.17 要求 libc 配置里的 `cc_dir`（`crtbegin.o` / `crtend.o` 所在目录，**不是**库搜索
  路径）。OHOS NDK 只提供 `clang_rt.crtbegin.o`，cross 用一个 `WriteFile` 步骤在 Zig 管理的
  缓存目录里生成改名副本（`crtbegin.o`/`crtend.o`/`crtbeginS.o`/`crtendS.o`），位置跟随
  `--cache-dir`，配置阶段不再直接写本地缓存。
