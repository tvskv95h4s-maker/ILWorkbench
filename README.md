<div align="center">
  <img src="docs/icon.png" width="112" alt="ILWorkbench">
  <h1>ILWorkbench</h1>
  <p><b>macOS 上的 .NET 反编译 / IL 编辑工作台</b><br>
  树形浏览 · C# 反编译 · IL 指令编辑 · 结构编辑 · 直接保存回 DLL<br>
  双击 DMG 即用，<b>不需要用户安装 .NET</b></p>
  <p>
    <img src="https://img.shields.io/badge/macOS-13%2B-blue" alt="macOS 13+">
    <img src="https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-lightgrey" alt="universal">
    <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT">
  </p>
  <p><a href="README.en.md">English</a> · 中文</p>
</div>

![ILWorkbench](docs/screenshots/hero.png)

---

## 这是什么

一个原生 macOS 应用：把 .NET 程序集拖进来，就能像 dnSpy 那样浏览命名空间 / 类型 / 方法 / 字段，
读反编译出的 C#，查看并编辑 IL 指令，改完直接保存回 DLL。

界面是 SwiftUI + AppKit（`NSOutlineView`，真虚拟化、懒加载、原生双击），
反编译与 IL 读写由一个自带的 .NET 助手进程完成（dnlib + ICSharpCode.Decompiler）。
助手是自包含发布的，**用户机器上不需要装 .NET**，拖进「应用程序」就能用。

## 功能

**浏览与反编译**

- 打开 `.dll` / `.exe`（工具栏、⌘O、拖进窗口，或 `--open <路径>`）
- 程序集树：`程序集 → 模块 → PE / 类型引用 / 引用 / 资源 / 全局命名空间{} / 各命名空间`
  - 行上只显示名字，完整签名与 token 在提示气泡里（与 dnSpy 一致），也可在设置里把签名/token 常显
  - 懒加载 + 虚拟化：2 万节点的程序集全量展开也不卡（展开本身几乎不耗时）
  - `类型引用` 显示为 dnSpy 的 `短名 @token`（如 `AccessibleRole @010003C0`），泛型展开为 `Action<T1, T2>`
  - `PE` 是可展开的树：`DOS 头 / 文件头 / 可选头 (32 位) / 节 #n / Cor20 头 / 存储签名 / 存储标题 / 存储流 #n`，
    逐项点开看明细（节表、CLR 头、元数据版本、`#~` 流各表行数）
  - `引用` 里的程序集可在磁盘上递归查找并像 dnSpy 一样直接展开查看（只读）
- 右键根节点 → **移除程序集**（⇧⌘W）
- 点程序集 / 模块节点 → 显示 dnSpy 同款「程序集信息」文档（路径、标识、全局类型、架构、运行库、时间戳，
  以及反编译出的 `using` 与 `[assembly: …]` 属性）
- C# 视图：ICSharpCode.Decompiler 输出，带语法高亮（自研词法高亮器，百万字符级文本也秒开）

**IL 编辑**

- 选中方法 → 切到 `IL`，逐条指令显示（偏移、opcode、操作数），底部显示 maxStack 与异常处理数
- 编辑常量（字符串 / 数字）、替换指令、在指令前插入、在方法末尾追加、删除指令
- 保存时按情况决定是否保留 metadata RID：删过成员就重新编号，避免写出 `dummy_ptr.{guid}` 之类的占位行

**结构编辑**

- 在命名空间 / 类型上右键：添加字段、添加方法、添加类型；删除类型 / 成员
- 新增方法体一定是合法 IL（返回常量或返回默认值），随后可在 IL 视图里继续改
- 接口方法用 `MethodSig.CreateInstance` + `HideBySig`，避免加载时 `TypeLoadException`

**界面**

- 中文 / English 一键切换，**包括树节点标签**（`类型引用` / `Type References`、`节 #0: .text` / `Section #0: .text`）
- `⌘,` 设置：左树右详情，**确定 / 取消**（不点确定不生效）
  - 环境 ▸ 通用设置：语言、主题、是否允许编辑（关掉即只读）
  - 环境 ▸ 字体：代码/IL 面板字体与字号，实时预览
  - 代码编辑器 ▸ C# ▸ 通用设置：语法高亮开关、自动换行、Tab 宽度
  - 程序集资源管理器：隐藏合成成员 / `[CompilerGenerated]` 项、显示签名、显示 token

**容错**

打开任何文件都不会崩：不是 .NET 程序集时，根节点显示文件名 + 错误图标，点开给出本地化诊断文档
（识别结果、大小、文件头、机器、CLR 头、加载器原因）。

| 输入 | 识别结果 |
|---|---|
| C/C++ 等原生 Windows DLL/EXE | 有 PE 头但无 CLR 头 |
| macOS 可执行文件 / dylib | Mach-O |
| Linux 可执行文件 / so | ELF |
| zip / NuGet 包 | 压缩包 |
| 文本文件 / 文件夹 | 文本 / 文件夹 |
| 托管程序集但 metadata 损坏 | metadata 损坏或版本不受支持 |

## 截图

**C# 视图**（左侧树 + 反编译结果，带语法高亮）

![C# 视图](docs/screenshots/csharp-view.png)

**IL 视图**（逐条指令 + 编辑按钮，例：`Greet` 的全部 IL）

![IL 视图](docs/screenshots/il-view.png)

**程序集信息**（点程序集或模块节点）

![程序集信息](docs/screenshots/assembly-info.png)

**设置**（左树右详情，确定 / 取消）

![设置](docs/screenshots/settings.png)

## 安装（最终用户）

1. 到 [Releases](../../releases) 下载 `ILWorkbench-x.y.z.dmg`
2. 打开 DMG，把 **ILWorkbench** 拖进「应用程序」
3. 首次打开若提示「无法验证开发者」：右键 → 打开，或
   `xattr -dr com.apple.quarantine /Applications/ILWorkbench.app`

应用是通用二进制（Apple Silicon + Intel），助手也是双架构自包含，**不需要安装 .NET**。

## 从源码构建

需要：macOS 13+、Xcode 15+、.NET 7 SDK。

```bash
git clone https://github.com/<you>/ILWorkbench.git
cd ILWorkbench

# 1. 构建 .NET 助手（dnlib + ICSharpCode.Decompiler）
Scripts/build-helper.sh
Scripts/publish-helper.sh osx-arm64      # Intel 机器换成 osx-x64
                                         # 也可以两个都做，出通用包

# 2. 构建 app（构建阶段会把 Helper/publish 打进 .app）
xcodebuild -project ILWorkbench.xcodeproj -scheme ILWorkbench \
  -configuration Release -derivedDataPath build \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build

open build/Build/Products/Release/ILWorkbench.app
```

> `Helper/publish/` 是 app 的构建输入，必须先 `publish-helper.sh`，否则打出来的 app 里没有助手。

出 DMG：

```bash
Scripts/make-dmg.sh          # 产物在 dist/
```

签名与公证（可选，消除 Gatekeeper 提示）：

```bash
ILWORKBENCH_SIGN_IDENTITY="Developer ID Application: …" \
ILWORKBENCH_NOTARY_PROFILE="profile-name" Scripts/make-dmg.sh
```

## 自检与调试（无需截屏权限）

app 二进制自带一组诊断命令，脚本和 CI 都靠它们验证：

```bash
APP=build/Build/Products/Release/ILWorkbench.app/Contents/MacOS/ILWorkbench
SAMPLE=Samples/SampleLib/bin/Release/net7.0/SampleLib.dll

"$APP" --selftest "$SAMPLE" /tmp/out.dll     # 打开 + 反编译 + 保存
"$APP" --ilcheck "$SAMPLE"                   # IL 视图、程序集文档、状态链路
"$APP" --opentest "$SAMPLE" /bin/ls a.txt    # 各种非程序集文件的降级
"$APP" --canceltest <大程序集>               # 长任务取消是否及时
"$APP" --treesnapshot "$SAMPLE" /tmp/tree.png --expand 类型引用
"$APP" --renderpreview "$SAMPLE" /tmp/code.png --type Greeter
```

端到端验证（IL 编辑 + 结构编辑 + 写回后用 Verifier 反射加载）：

```bash
Scripts/verify.sh
```

## 重新生成 README 截图

```bash
Scripts/make-promo-shots.sh          # 只用仓库自带的 Samples/SampleLib
```

会构建示例程序集、把它复制到 `/Users/Shared/ILWorkbench-Sample/`（避免截图里出现个人目录），
渲染窗口到 `build/promo-raw/`，再用 `Scripts/compose-promo.py` 合成到 `docs/screenshots/`
（合成需要 Python 3 + Pillow，可用 `PYTHON=/path/to/python3` 指定解释器）。

## 目录结构

```
ILWorkbench/            SwiftUI + AppKit 前端
  AssemblyOutlineView.swift   NSOutlineView 侧边树（懒加载、双击、右键菜单）
  AppModel.swift              状态与请求编排（选择、缓存、展开、保存）
  ContentView.swift           工具栏 / 详情面板 / IL 编辑器 / 结构编辑表单
  CodeTextView.swift          NSTextView 代码面板（异步高亮、字体/换行设置）
  SyntaxHighlighter.swift     C# / IL 词法高亮
  HelperClient.swift          与助手进程的 JSON-RPC（回环 TCP + 原始 socket）
  Localization.swift          中英文字符串表 + 设置存储
  SettingsView.swift          设置窗口（左树右详情 + 确定/取消）
  SelfTest.swift              诊断命令实现
Helper/                 .NET 助手（控制台程序）
  AssemblySession.cs          建树、反编译、IL 读取、引用解析、保存
  IlEditing.cs                IL 指令级编辑
  StructureEditing.cs         类型/字段/方法增删
  FileProbe.cs                非托管文件识别（容错）
  Program.cs                  JSON-RPC 服务端
Samples/SampleLib/      用于示例与验证的示例程序集（README 截图就是它）
Samples/Verifier/       写回后用反射加载的校验器
Scripts/                构建、发布、打包、验证、截图脚本
docs/                   图标与截图
```

## 工作原理

```
SwiftUI 前端  ──JSON-RPC（一行一条，回环 TCP，原始 BSD socket）──▶  .NET 助手进程
   NSOutlineView（虚拟化、懒加载）                                  dnlib：结构 / IL / 写回
   NSTextView（异步语法高亮）                                       ICSharpCode.Decompiler：C# 文本
```

- 请求在助手侧由单个工作线程顺序执行（避免并发的 metadata 访问问题），
  `cancel` 由读线程立即处理，所以取消能在 1 秒内生效
- 传输层用回环 TCP 而不是 stdin/stdout：`Process` + `Pipe` 在 macOS 上曾出现
  子进程写入无法回传的问题（详见开发记录）

## 已知限制

- **依赖解析**：`引用` 里的程序集需要在磁盘相邻目录或系统目录里能找到才能展开；
  找不到的只显示引用信息（例如 macOS 上没有的 .NET Framework 系统程序集）
- **超大类型**：首次反编译由反编译引擎决定，120 万字符的类型约 7 秒（可取消）
- **仅查看/编辑，不带调试器**，也没有反汇编器（原生二进制不做反汇编）
- **仅 macOS 13+**；Windows/Linux 未适配
- 未签名分发时会有 Gatekeeper 提示（可用环境变量签名+公证）

## 致谢

- [dnSpy](https://github.com/dnSpy/dnSpy) —— 交互与信息呈现方式的主要参考
- [ILSpy / ICSharpCode.Decompiler](https://github.com/icsharpcode/ILSpy) —— C# 反编译引擎
- [dnlib](https://github.com/0xd4d/dnlib) —— 程序集读写与 IL 编辑
- [.NET](https://github.com/dotnet/runtime) —— 自包含助手运行时

## 许可证

[MIT](LICENSE)。第三方组件均为 MIT 许可：dnlib、ICSharpCode.Decompiler、.NET Runtime。
