# AGENTS.md — 本仓库对 AI agent 的说明书

> **本文件是 agent 的唯一事实源（single source of truth）。**
> 与代码注释、旧文档、口头说明冲突时，以「本文件 + `docs/PROTOCOL.md` + 上游仓库」为准。
> 面向人类的项目介绍见 [`README.md`](README.md)；协议细节见 [`docs/PROTOCOL.md`](docs/PROTOCOL.md)。

---

## 1. 这是什么项目

**HarmonyOS NEXT 原生客户端（ArkTS / ArkUI）**，用于连接运行着 DeepSeek Harness + `dsh-mobile` 插件的电脑。

- 只实现**手机端**。不实现插件、不实现网关、不改上游。
- 协议事实源：上游 <https://github.com/saya-ch/dsh-mobile> 与 [`docs/PROTOCOL.md`](docs/PROTOCOL.md)。
- 本项目是**社区实现**，与 DeepSeek、华为均无隶属关系。

## 2. 三条命令（其余都是可选的）

```powershell
# 构建 debug HAP
pwsh -File scripts/build.ps1

# 验证：构建 + 静态校验。交付前必须退出码 0
pwsh -File scripts/verify.ps1

# 快速验证：跳过构建，秒级，只跑静态校验（改文档/配置时用）
pwsh -File scripts/verify.ps1 -SkipBuild
```

- **退出码 0 才算通过。** 不要用「看起来生成了 HAP」「控制台没报红」替代退出码。
- 安装到真机（需要先签名）：`pwsh -File scripts/install.ps1 -Hap <已签名 HAP 路径>`。

## 3. 目录地图

| 路径 | 职责 | 改之前先看 |
| --- | --- | --- |
| `entry/src/main/ets/protocol/` | **协议与 TLS 核心**：origin 解析、配对密钥、证书固定、TLSSocket 上的 HTTPS/1.1、网关调用、发现 | `docs/PROTOCOL.md`、ADR-0001/0002 |
| `entry/src/main/ets/model/` | 设备记录模型与持久化（preferences 存元数据，Asset Store 存凭据） | `docs/ARCHITECTURE.md` §6 |
| `entry/src/main/ets/service/` | 应用服务层：配对/续期/设备列表协调 | `docs/ARCHITECTURE.md` §5 |
| `entry/src/main/ets/pages/` | ArkUI 页面与 ArkWeb 容器 | `docs/ARCHITECTURE.md` §7 |
| `entry/src/main/ets/common/` | 日志、JSON、主题、设备端自检 | — |
| `AppScope/app.json5` | `bundleName`、版本、应用名 | ADR-0004 |
| `entry/src/main/module.json5` | ability、页面入口、权限 | — |
| `docs/` | BUILD / PROTOCOL / ARCHITECTURE / TESTING / ADR | 改行为的前提 |
| `scripts/` | 构建、验证、安装的 PowerShell 封装 | — |

## 4. 硬规则（违反即交付不合格）

### 4.1 仓库卫生

- **永不提交** `entry/build/`、`.hvigor/`、`oh_modules/`、`node_modules/`、`.research/`、`*.hap`。
- **永不提交**签名材料：`*.p12`、`*.p7b`、`*.keystore`、`*.pem`、`*.key`、`signing-configs/`。
- 禁止 `git add -A` 后不看清单就提交；提交前先看 `git status --porcelain`。
- `.research/` 是上游源码的本地参考副本（Apache-2.0），**不随仓库分发**——README 承诺「不包含上游代码」，这条必须守住。

### 4.2 协议与安全（最容易被「优化」掉的两条）

- **信任根只有一个**：`instanceId = SHA-256(配对 CA 证书 DER)`。CA 未通过指纹校验前，不信任任何响应内容。见 [ADR-0002](docs/adr/0002-trust-root-is-instance-id.md)。
- **带自定义 CA 的请求必须走 `protocol/TlsHttp.ets`**，禁止改回 `@ohos.net.http`（它在低版本 API 上只能用系统信任库）。见 [ADR-0001](docs/adr/0001-tlssocket-over-ohos-net-http.md)。
- 改协议字段的顺序固定：**先改 `docs/PROTOCOL.md` → 再改代码 → 再补/改 `docs/TESTING.md` 用例**。不要反过来。
- 配对密钥、`deviceToken`、会话 Cookie **不得写入日志**（`Log.ets` 会脱敏，不要绕过它）。

### 4.3 并发与协作

- **同一个工作区同一时间只允许一个 agent 写入。** 并行任务请用 `git worktree add` 开独立目录，不要共用。
- 提交时只 `git add` 你自己创建或改动的文件。**工作区里别人的未提交改动，既不要提交，也不要用 `git stash`/`checkout` 清掉**——那会直接丢掉别人的工作。

## 5. 当前状态与风险（2026-11）

| 项 | 状态 |
| --- | --- |
| 命令行构建 | ✅ 已验证（Windows 11 / DevEco Studio 26.0.0 / SDK API 26 / hvigor 6.26.9 / JDK 17） |
| 真机安装 | ✅ 已验证（2026-11-24，HUAWEI Mate 60 Pro+ / HarmonyOS 7.0.0.111 / API 26，DevEco 自动签名的 debug Profile；见 `docs/BUILD.md` §8.1）。**不带签名配置的命令行构建产物仍是 unsigned，装不上** |
| 真机启动 / 协议自检 | ✅ TC-01、TC-02 通过（自检 20 项全过）；真机上发现并修复 4 个缺陷（全角加号字形、底部导航条白条、弹窗浅色、启动日志不可见），见 `docs/TESTING.md` §11 |
| 配对 / TLS / 浏览 / 网络切换 | ⛔ 未验证：电脑端尚未安装 `dsh-mobile` 插件，拿不到配对链接。`docs/TESTING.md` 共 35 条用例，目前只有 TC-01、TC-02 与一次无插件扫描冒烟被执行 |
| 自动化测试 | ❌ 无 `ohosTest`；唯一的自动检查是 `scripts/verify.ps1` |
| 已知安全缺口 | 远程降级保护（`preserveRemotePin`）**已实现但未接入配对流程**：同一远程电脑若曾固定 CA，用不要求 CA 的密钥重配对且 `ca.cer` 返回 404 时，可能回退平台信任库。见 [ADR-0002](docs/adr/0002-trust-root-is-instance-id.md)、[ARCHITECTURE §15](docs/ARCHITECTURE.md#15-已知缺口与后续工作)、[TESTING TC-18B](docs/TESTING.md) |
| 依赖 | 无第三方 ohpm 依赖，不需要联网 `ohpm install` |

**日志与签名的两条真机结论（都踩过）**：

- ability 层也必须走 `common/Log.ets`（domain `0x0D5B`）；用 `hilog.info(0x0000, ...)` 在 HarmonyOS 7 上**一条都收不到**。`verify.ps1` 会拦直接调用 `hilog` 的文件。
- DevEco「自动生成签名」会**就地改写** `build-profile.json5`，写入本机绝对路径和加密口令。提交前必须 `git checkout -- build-profile.json5`；`verify.ps1` 会在静态校验阶段拦下带 `signingConfigs` 的版本。

**因此：任何涉及协议、证书、网络、权限的改动，都必须在该提交里写明「哪些 TC 用例需要人工复测」。** 没有这条说明的协议层改动视为未完成。

## 6. 交付定义（Definition of Done）

1. `pwsh -File scripts/verify.ps1` 退出码 **0**；
2. 相关文档同步（PROTOCOL / ARCHITECTURE / TESTING 该改的改）；
3. 提交信息符合第 7 节；
4. 协议/安全类改动：写明需人工复测的 TC 编号；
5. 若做了架构层面取舍，补一篇 `docs/adr/`。

## 7. 提交规范

Conventional Commits 子集，正文可用中文：

```
feat: 支持 dsh2 配对链接的远程模式
fix: 修正自签 CA 有效期校验的时区偏移
docs: 补充 TLSSocket 超时策略
refactor: 拆分 Discovery 的三条发现路径
test: 补充 origin 解析用例
chore: 忽略 .hvigor 缓存
build: 固定 hvigor 版本
```

- 一个任务一个提交；不要把「功能 + 无关格式化」混在一起。
- 不要伪造 `Co-authored-by` 或他人签名。

## 8. 已知坑

- **不要依赖 PATH 里的 `hvigorw`**：用 `scripts/build.ps1`，它以绝对路径调 `node <hvigorw.js>`。
- `JAVA_HOME` 必须是 **JDK 17**；`DEVECO_SDK_HOME` 指向 DevEco 的 `sdk` 目录（`build.ps1` 会自动尝试常见安装路径，也可用环境变量覆盖）。
- Windows 上工程放在受保护目录或路径过深会构建失败；`E:\aicode\` 这类普通目录是安全的。
- 文档统一 **UTF-8 + LF**（由 [`.gitattributes`](.gitattributes) 约束），不要引入 CRLF 造成假 diff。
- 仓库名是 `dsh-mobile-harmonyos`；**本地目录可能仍叫 `dsh-hmos-mobile`**（历史名称），`docs/BUILD.md` 里的绝对路径是本地路径，不是仓库名。
- `bundleName` 是 `io.github.crazyjason.dshmobile.hmos`（2026-11-24 于首次真机安装前从上游命名空间改到维护者命名空间），**再改它会等于换一个 App**（旧包无法覆盖安装，只能卸载重装并重新配对），详见 [ADR-0004](docs/adr/0004-repo-name-and-bundle-namespace.md)。

## 9. 文档索引

| 文档 | 什么时候读 |
| --- | --- |
| [`README.md`](README.md) | 第一次接触项目：定位、功能范围、与上游对应关系 |
| [`docs/BUILD.md`](docs/BUILD.md) | 环境、构建、签名、安装、常见构建错误 |
| [`docs/PROTOCOL.md`](docs/PROTOCOL.md) | **改任何协议相关代码之前必读**：URL、接口、字段、Cookie、错误码 |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | 模块划分、线程与生命周期、证书固定设计、与 Android 对照 |
| [`docs/TESTING.md`](docs/TESTING.md) | 真机验证：35 条用例（TC-01…TC-31，含 B 变体）、分级执行顺序、缺陷采集要求 |
| [`docs/adr/`](docs/adr/README.md) | 已定型的架构决策与「为什么不能那样改」 |
