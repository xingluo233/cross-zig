# cross

**cross** 是一个 [Zig](https://ziglang.org/) 0.16+ 的交叉编译构建辅助库：给定一个 Zig 编译目标
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
zig fetch --save https://github.com/xingluo233/cross-zig/releases/download/v1.0.0/cross-v1.0.0.tar.gz
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
    defer config.deinit(b.allocator);

    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addCSourceFile(.{ .file = b.path("src/main.c"), .flags = &.{} });

    // 配置编译（include 路径、库路径、libc 配置、宏、crt/运行时补丁）
    config.configureCompile(exe);

    // 需要 translate-c 时同样配置
    const tc = b.addTranslateC(.{ .root_source_file = b.path("src/headers.h"), .target = target, .optimize = optimize });
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
zig build "-Dtarget=x86-linux-android.35"        # Android 32 位 x86（zig 中叫 x86）
zig build "-Dtarget=aarch64-linux-musl" -Dohos  # OpenHarmony（见下文说明）
zig build -Dtarget=wasm32-emscripten             # WebAssembly
zig build -Dtarget=wasm64-emscripten             # WebAssembly
```

## API

### `TargetConfig`

```zig
pub fn init(b: *std.Build, target: std.Build.ResolvedTarget, options: Options) !TargetConfig
pub fn deinit(self: TargetConfig, allocator: std.mem.Allocator) void
pub fn configureCompile(self: TargetConfig, compile: *std.Build.Step.Compile) void
pub fn configureTranslateC(self: TargetConfig, translate_c: *std.Build.Step.TranslateC) void
pub fn isNative(self: TargetConfig) bool
```

- `configureCompile` 会添加：系统 include 路径、库搜索路径、libc 配置文件（`setLibCFile`）、
  平台宏（`_FORTIFY_SOURCE`/`__ANDROID_API__`/`__MUSL__`/`__EMSCRIPTEN__` 等）、以及针对各端
  的 crt / 运行时补丁。
- `configureTranslateC` 只配置 include 路径与宏，供 `b.addTranslateC` 使用。
- `TargetConfig.init` 需要在配置阶段调用，后续构建过程即可正常使用。

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
- **静态 libc 布局适配**：zig 链接静态 bionic 时，lld 的库搜索路径仅来自 libc 配置的 `crt_dir`，
  而 NDK 把静态档案（`libc.a`/`libm.a`/`libdl.a`）、crt 对象（`crtbegin_static.o` 等）和
  `libunwind.a` / compiler-rt builtins 分散在两三个目录。cross 会自动在 zig 缓存下生成一个
  **合并目录**（`<cache>/cross-android-<arch>-<hash>/`），把 crt 对象、静态 libc 档案、
  `libunwind.a`、重命名后的 `libbuiltins.a`（compiler-rt）以及 `libatomic.a` 合一，
  同时链接 `unwind`/`builtins`/`atomic`。
- 产物为静态链接 libc 的可执行文件（EXEC），可直接在设备上运行，也可改为 napi `.so` 供应用加载。

### OpenHarmony

- **重要**：Zig 0.16 的 std 库尚不支持 `.ohos` ABI（`aarch64-linux-ohos` 目标会在编译
  `compiler_rt` 时报 `std/c.zig: unsupported ABI`）。因此当前使用方式为：

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
  `$EMSDK/upstream/emscripten/cache/sysroot`（`include/` + `lib/<triple>/`，含 `crt1.o`）。
  未运行过 `emcc`（或 cache 不完整）会直接报错：
  ```powershell
  emcc -v    # 任何一次调用即可生成 cache sysroot
  ```
- 路径解析顺序：`Options.emsdk_sysroot` > `$EMSDK/upstream/emscripten/cache/sysroot`；
  显式 sysroot 同样要求 `include/` 与 `lib/<triple>/` 完整。
- `crt1.o`（若存在）会被自动链接到可执行产物。
- 宏：`__EMSCRIPTEN__=1`。wasm 目标建议跳过可执行产物，以 object 形式交付（见 tests/smoke）。

## Smoke 示例

`tests/smoke/` 是一个完整的使用示例（path 依赖 `../..`），用一个 C 程序 `main.c` 和 translate-c 目标
`headers.h` 验证：编译、转译、宏注入、链接均正常。

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

覆盖：目标分类（`classify`）、各平台 triple/架构名、宏定义、clang 版本解析、
文件系统 helper、静态库合并的复制语义等（23 个测试）。需要真实 SDK 的路径探测通过 `tests/smoke`
在相应机器上验证。

## 目录结构

```
build.zig          # 入口：导出 TargetConfig / Options 及各平台模块
build.zig.zon      # 包定义：名称、版本（发版 tag 需与之一致）、paths
src/
  target.zig       # 目标分类、TargetConfig 联合类型、宏注入
  platform.zig     # 公共逻辑：libc.conf 生成、目录检查、版本解析
  android.zig      # Android NDK：路径解析、API 规则、静态 libc 合并目录
  ohos.zig         # OpenHarmony：sysroot 解析、clang builtins 探测
  emscripten.zig   # Emscripten：cache sysroot 解析、crt1 链接
  tests.zig        # 测试聚合入口
tests/smoke/         # 端到端验证示例（C 源 + 多目标构建）
scripts/
  ci-smoke.sh      # 全目标冒烟矩阵脚本
.github/workflows/
  ci.yml           # CI：lint + 单测 + 冒烟矩阵
  release.yml      # 自动发版：v* 标签触发，打包源码并发布变更说明
```

## 已知限制

- `-Dtarget=aarch64-linux-ohos` 在 Zig 0.16 下不可用（std 不支持 `.ohos` ABI），请使用
  `-Dohos` + `linux-musl` 路线；待上游支持后 cross 会优先使用 `.ohos` ABI。
