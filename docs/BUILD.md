# 构建、签名与安装指南

本文说明如何在本机把 `dsh-mobile-harmonyos` 编译成 HAP、如何签名，以及如何安装到 HarmonyOS NEXT 真机。

> **验证范围**：本文的命令行构建流程已在本机（Windows + DevEco Studio 26.0.0 + HarmonyOS SDK API 26 + hvigor 6.26.9 + JDK 17）实际执行并成功产出 HAP。**安装、启动、配对、浏览均未在真机上验收**；签名与安装章节基于 HarmonyOS 的通用要求，未经本项目实测。

- [1. 环境要求](#1-环境要求)
- [2. 工程结构与产物](#2-工程结构与产物)
- [3. 命令行构建（已验证）](#3-命令行构建已验证)
- [4. DevEco Studio 图形界面构建](#4-deveco-studio-图形界面构建)
- [5. 签名](#5-签名)
- [6. 安装到真机](#6-安装到真机)
- [7. 常见构建错误](#7-常见构建错误)
- [8. 构建验证记录](#8-构建验证记录)

---

## 1. 环境要求

### 1.1 已验证的工具链

| 组件 | 版本 | 本机路径 |
| --- | --- | --- |
| DevEco Studio | 26.0.0 | `D:\Programs\Huawei\DevEcoStudio` |
| HarmonyOS SDK | API 26 | `D:\Programs\Huawei\DevEcoStudio\sdk` |
| hvigor | 6.26.9 | `D:\Programs\Huawei\DevEcoStudio\tools\hvigor\bin\hvigorw.js` |
| Node.js（DevEco 自带） | 随 DevEco Studio 提供 | `D:\Programs\Huawei\DevEcoStudio\tools\node` |
| ohpm | 26.0.0.630 | `D:\Programs\Huawei\DevEcoStudio\tools\ohpm` |
| JDK | 17 | `E:\tools\jdk-17` |

### 1.2 工程声明的 SDK 版本

| 配置项 | 值 | 说明 |
| --- | --- | --- |
| `compatibleSdkVersion` | `5.0.0(12)` | 最低兼容 API 12；工程刻意不用 API 12 之后才有的网络 API |
| `targetSdkVersion` | `6.0.0(20)` | 目标 API 20 |
| `runtimeOS` | `HarmonyOS` | 仅面向 HarmonyOS NEXT |
| `bundleName` | `io.github.sayach.dshmobile.hmos` | 安装包唯一标识 |
| 设备类型 | `phone`、`tablet`、`2in1` | `entry/src/main/module.json5` |

> 用 API 26 的 SDK 编译、兼容 API 12 是可行且已在本机验证的组合。`build-profile.json5` 中的版本值不要随意改动：`compatibleSdkVersion` 决定了 `@ohos.net.http` 等 API 是否可用，而本项目为了在 API 12 上固定自签 CA，绕开了 `@ohos.net.http`（原因见 [ARCHITECTURE.md](ARCHITECTURE.md#为什么用-tlssocket-而不是-ohosnethttp)）。

### 1.3 依赖

工程**没有第三方 ohpm 依赖**，`oh-package.json5` 的 `dependencies` 为空，因此不需要 `ohpm install` 拉包。构建所需的 hvigor 插件由 DevEco Studio 自带。

---

## 2. 工程结构与产物

```text
dsh-mobile-harmonyos/
├── AppScope/app.json5              # bundleName、版本号、图标、应用名
├── build-profile.json5             # product 级构建配置（SDK 版本、签名引用）
├── oh-package.json5                # 工程级依赖
├── hvigor/hvigor-config.json5      # hvigor 模型版本
├── hvigorfile.ts                   # appTasks 入口
└── entry/
    ├── build-profile.json5         # module 级构建配置（stage 模式、release 选项）
    ├── hvigorfile.ts
    ├── oh-package.json5            # 模块依赖与 license
    └── src/main/
        ├── module.json5            # ability、页面、权限
        ├── ets/                    # ArkTS 源码
        └── resources/              # 资源
```

构建产物（默认路径，均由 `.gitignore` 忽略）：

| 产物 | 路径 |
| --- | --- |
| 未签名 HAP | `entry/build/default/outputs/default/entry-default-unsigned.hap` |
| 构建元数据 | `entry/build/default/outputs/default/pack.info` |
| 中间产物 | `entry/build/default/intermediates/` |
| 构建缓存与报告 | `.hvigor/` |

---

## 3. 命令行构建（已验证）

### 3.1 完整命令

在仓库根目录 `E:\aicode\dsh-hmos-mobile` 打开 PowerShell，依次执行：

```powershell
$env:DEVECO_SDK_HOME='D:\Programs\Huawei\DevEcoStudio\sdk'
$env:NODE_HOME='D:\Programs\Huawei\DevEcoStudio\tools\node'
$env:JAVA_HOME='E:\tools\jdk-17'
$env:PATH="E:\tools\jdk-17\bin;D:\Programs\Huawei\DevEcoStudio\tools\node;$env:PATH"

node 'D:\Programs\Huawei\DevEcoStudio\tools\hvigor\bin\hvigorw.js' --mode module -p product=default -p module=entry@default assembleHap --no-daemon
```

执行成功后检查产物：

```powershell
Get-Item 'entry\build\default\outputs\default\entry-default-unsigned.hap' |
  Select-Object FullName, Length, LastWriteTime
```

### 3.2 参数说明

| 参数 | 作用 |
| --- | --- |
| `node <hvigorw.js>` | 直接用 DevEco 自带 Node 运行 hvigor，避免 PATH 中缺少 `hvigorw` 或版本不一致 |
| `--mode module` | 以模块模式构建（当前工程只有 `entry` 模块） |
| `-p product=default` | 选择 `build-profile.json5` 中名为 `default` 的产品 |
| `-p module=entry@default` | 指定构建 `entry` 模块的 `default` target |
| `assembleHap` | 任务：组装 HAP（不打包 App/APP 包） |
| `--no-daemon` | 构建结束后退出 hvigor 守护进程；CI/一次性构建推荐 |

如果只需要跑某一个模块的构建任务，也可以改为 `--mode module -p module=entry@default assembleHap`（省略 product 时使用默认产品）。上面的完整形式是本机验证过的那一条。

### 3.3 全量重建

hvigor 会缓存编译结果。修改 ArkTS 源码后正常重跑上面的命令即可增量编译；若怀疑缓存导致异常（例如资源表过期、删除文件后仍报错），删除以下目录后重跑：

```powershell
Remove-Item -Recurse -Force 'entry\build'
Remove-Item -Recurse -Force '.hvigor\cache'
```

> 上述删除操作只是清理构建产物；`entry/build` 与 `.hvigor/` 都不在版本控制内。

### 3.4 构建告警与日志

- 构建日志默认写入 `.hvigor/outputs/build-logs/build.log`；
- 编译报告写入 `.hvigor/report/report-*.json`；
- ArkTS 编译错误会直接以 `ERROR` 形式出现在控制台并返回非 0 退出码。命令行的退出码是判断成败的唯一依据，不要只看“产物看起来生成了”。

---

## 4. DevEco Studio 图形界面构建

### 4.1 打开工程

1. 启动 DevEco Studio；
2. `File` → `Open...`，选择仓库根目录 `E:\aicode\dsh-hmos-mobile`（**不是** `entry/`）；
3. 等待右下角 Sync 完成。工程无第三方依赖，Sync 通常只需处理 hvigor 模型。

### 4.2 配置自动签名

> 未签名 HAP 无法安装到真机，因此图形界面构建前建议先配置自动签名。

1. `File` → `Project Structure...`；
2. 左侧选择 `Project` → `Signing Configs`；
3. 勾选 `Automatically generate signature`；
4. 登录华为账号（按 IDE 弹窗提示操作）；
5. IDE 生成调试证书与 Profile，并自动填入 `signingConfigs`；
6. 点击 `Apply`，再点击 `OK`。

完成后 `build-profile.json5` 的 `app.products[].signingConfig` 会指向自动生成的配置。

### 4.3 构建

- 只构建 HAP：菜单 `Build` → `Build Hap(s)`；
- 构建整个应用包：`Build` → `Build App(s)`（本项目只需要 HAP）；
- 或选择运行配置后点击工具栏 `Run`，IDE 会构建、签名并安装到已连接设备。

产物位置同样是 `entry/build/default/outputs/default/`，签名后的文件名通常为 `entry-default-signed.hap`（具体后缀以 IDE 生成的为准）。

### 4.4 命令行与图形界面的差异

| 场景 | 命令行 | DevEco Studio |
| --- | --- | --- |
| 编译验证 | 支持 `--no-daemon`，适合一次性验证 | 需要保持 IDE 打开 |
| 自动签名 | 需要先在 IDE 里生成 `signingConfigs`，命令行复用 | 可一键生成 |
| 安装运行 | 需要 `hdc install` | `Run` 一步完成 |
| 日志查看 | `hdc shell hilog` | Log 面板 |

---

## 5. 签名

### 5.1 为什么必须签名

HarmonyOS 安装 HAP 时会强制校验签名：校验签名证书、Profile 与设备/调试状态是否匹配。**未签名 HAP 在任何真机上都会安装失败**，这不是本项目特有的限制。命令行构建出的 `entry-default-unsigned.hap` 只用于验证编译结果。

### 5.2 方式 A：DevEco Studio 自动签名（推荐）

见 [4.2 配置自动签名](#42-配置自动签名)。自动签名适合调试：

- 证书与 Profile 由 IDE 生成并保存在本机；
- 调试 Profile 绑定了允许调试的设备；
- 换电脑或换账号后需要重新生成。

### 5.3 方式 B：手动配置签名材料

如果你有正式发布的证书与 Profile，可在 `File` → `Project Structure...` → `Signing Configs` → 取消勾选自动生成，然后手工选择：

| 材料 | 说明 |
| --- | --- |
| `.p12` / keystore 文件 | 私钥与证书链，**绝不入库** |
| store password / key alias / key password | 与 keystore 对应 |
| `.cer` 证书文件 | 签名证书，**不入库** |
| `.p7b` Profile 文件 | 绑定 bundleName 与设备/发布类型，**不入库** |
| 签名算法 | HarmonyOS 常用 `SHA256withECDSA`，以生成的 Profile 为准 |

`build-profile.json5` 中的 `signingConfigs` 由 DevEco Studio 维护；手写时注意路径引用与密码字段的格式以当前 IDE 版本生成的为准。

> **安全要求**：`*.p7b`、`*.p12`、`*.cer`、`*.pem`、`local.properties` 已被 `.gitignore` 排除。不要在 Issue、日志或截图中泄露签名材料、密码或未脱敏的 Profile 内容。

### 5.4 签名后检查

```powershell
# 查看 HAP 是否带签名材料（HAP 本质是 zip）
Get-ChildItem entry\build\default\outputs\default\*.hap
```

签名后的 HAP 才可进入下一节的安装流程。

---

## 6. 安装到真机

### 6.1 准备设备

1. 手机设置 → 关于手机 → 连续点击版本号开启「开发者模式」；
2. 设置 → 系统和更新 → 开发人员选项 → 打开「USB 调试」；
3. 用 USB 连接电脑，手机弹窗选择「允许调试」，并勾选始终允许。

### 6.2 使用 hdc

`hdc` 位于 SDK 的 toolchains 目录：

```text
D:\Programs\Huawei\DevEcoStudio\sdk\default\openharmony\toolchains\hdc.exe
```

```powershell
# 1. 确认设备可见（状态应为 device）
& 'D:\Programs\Huawei\DevEcoStudio\sdk\default\openharmony\toolchains\hdc.exe' list targets

# 2. 安装已签名的 HAP（-r 表示覆盖安装）
& 'D:\Programs\Huawei\DevEcoStudio\sdk\default\openharmony\toolchains\hdc.exe' install -r 'entry\build\default\outputs\default\entry-default-signed.hap'

# 3. 卸载（排查问题时使用）
& 'D:\Programs\Huawei\DevEcoStudio\sdk\default\openharmony\toolchains\hdc.exe' uninstall io.github.sayach.dshmobile.hmos
```

### 6.3 查看运行日志

```powershell
# 只看本项目日志（hilog tag = DshMobile，domain = 0x0D5B）
& 'D:\Programs\Huawei\DevEcoStudio\sdk\default\openharmony\toolchains\hdc.exe' shell hilog -T DshMobile

# 清空后重新抓取，便于复现单次问题
& 'D:\Programs\Huawei\DevEcoStudio\sdk\default\openharmony\toolchains\hdc.exe' shell hilog -r
```

### 6.4 安装失败的常见原因

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `signature verify failed` / 安装被拒 | 使用了 unsigned HAP，或签名与 Profile 不匹配 | 用 DevEco 自动签名重新构建；确认安装的是签名后的 HAP |
| 设备未出现在 `hdc list targets` | USB 调试未开、线材仅充电、驱动异常 | 换线/换口，重新授权调试 |
| 安装成功但无法启动 | 签名 Profile 不包含该设备（调试 Profile 设备列表） | 在 AppGallery Connect/DevEco 中把设备加入调试 Profile |
| bundleName 冲突 | 手机上已装同 bundleName 的其他版本 | `hdc uninstall io.github.sayach.dshmobile.hmos` 后重装 |
| 设备存储空间不足 | — | 清理空间后重试 |

> 换真机型号后，DevEco 自动签名通常需要重新生成 Profile（调试设备列表变化）。

---

## 7. 常见构建错误

| 错误/现象 | 原因 | 处理 |
| --- | --- | --- |
| `Cannot find the SDK` / 找不到 HarmonyOS SDK | `DEVECO_SDK_HOME` 未设置或路径错误 | 按 3.1 设置到 `...\DevEcoStudio\sdk`（不是 `...\sdk\default`） |
| `node` 不是内部或外部命令 | `NODE_HOME`/PATH 未包含 DevEco 自带 Node | 按 3.1 把 `tools\node` 加入 PATH，或直接用其绝对路径 |
| `Unsupported class file major version` / JDK 版本错误 | `JAVA_HOME` 指向了非 JDK 17 | 设置 `JAVA_HOME=E:\tools\jdk-17`，并把 `bin` 放到 PATH 最前 |
| `hvigorw` 找不到 | 依赖 PATH 中的 hvigorw | 使用 3.1 的 `node <绝对路径>\hvigorw.js` |
| ArkTS 编译错误后重新构建仍报旧错误 | 增量缓存 | 删除 `entry\build` 与 `.hvigor\cache` 后重跑 |
| `assembleHap` 成功但目录里只有 unsigned HAP | 未配置签名 | 这是正常的；签名见第 5 节 |
| 中文输出乱码 | 控制台编码 | 在 PowerShell 执行 `[Console]::OutputEncoding=[Text.Encoding]::UTF8` |
| 路径过长/权限错误 | 工程在受保护目录或路径太深 | 把仓库放到普通用户目录（如 `E:\aicode\`），避免系统目录 |
| hvigor daemon 残留导致构建卡住 | 上一次构建异常退出 | 使用 `--no-daemon`；必要时结束残留 `node` 进程后重试 |

---

## 8. 构建验证记录

| 项目 | 结果 |
| --- | --- |
| 验证日期 | 2026-11-24 |
| 验证机器 | 本项目开发机（Windows，DevEco Studio 26.0.0，SDK API 26，hvigor 6.26.9，JDK 17） |
| 执行的命令 | 3.1 节中的完整命令行（`assembleHap --no-daemon`） |
| 结果 | 命令成功结束，生成 `entry/build/default/outputs/default/entry-default-unsigned.hap` |
| 结论 | **ArkTS 源码可编译、可组装成 HAP**；产物为未签名包，不能安装 |
| 未做 | 未在真机安装、未启动应用、未做配对/浏览/证书/网络切换验收（见 [TESTING.md](TESTING.md)） |

> 该记录只覆盖“编译成 HAP”。任何关于运行时行为的描述都需要真机测试证据，不要用构建成功代替真机验收。
