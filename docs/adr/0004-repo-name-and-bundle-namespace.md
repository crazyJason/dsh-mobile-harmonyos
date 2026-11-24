# ADR-0004 仓库名与 `bundleName` 的命名空间

- 状态：已采纳
- 日期：2026-11
- 相关文件：`AppScope/app.json5`、`README.md`、`AGENTS.md`

## 背景

本仓库是上游 [dsh-mobile](https://github.com/saya-ch/dsh-mobile) 的**社区实现**（HarmonyOS NEXT 手机端），不是上游官方的一部分，也不属于 DeepSeek 或华为。

命名要同时满足三件事：

1. 不冒充上游官方发布物；
2. 与上游的配对协议、文档、截图能一一对应，方便对照；
3. 一旦有人装上，后续版本必须能覆盖安装（`bundleName` 改了就是一个新 App，旧安装既不能升级也不能迁移数据）。

## 决策

- **仓库名**：`dsh-mobile-harmonyos`。**本地目录名可能仍是 `dsh-hmos-mobile`**（历史目录），两者指的是同一个工程；仓库名以本 ADR 为准。
- **`bundleName`**：`io.github.sayach.dshmobile.hmos`
  - 前缀沿用上游 Android 客户端的 `io.github.sayach.dshmobile`，表示「同一插件的手机端实现」；
  - 结尾 `.hmos` 明确区分平台，**不会**与上游 Android 包名冲突（两者不在同一个应用市场里同名）；
  - 版本号与应用名独立维护（当前 `0.1.0`），不跟随插件版本。
- **文档措辞**：一律写明「社区实现、非官方」，不出现任何暗示官方支持的表述。

## 后果

- 已安装的测试版本可以继续覆盖安装；**不要在后续版本里改 `bundleName`**，否则等于换 App；
- 若上游将来发布官方 HarmonyOS 客户端，本项目的包名与之不同，二者可以共存；
- 代价：包名里带了他人的 GitHub 命名空间，这是刻意为之的「派生标识」，若上游要求变更，需要发新 ADR 并接受「换 App」的代价。

## 被否决的方案

| 方案 | 否决理由 |
| --- | --- |
| `com.deepseek.harness.mobile` 之类 | 冒充官方命名空间，误导用户 |
| `io.github.<本仓库作者>.dshmobile.hmos` | 与上游标识脱节，用户难以判断「这是同一个插件」 |
| 完全复用 `io.github.sayach.dshmobile`（不带平台后缀） | 与 Android 包名冲突，且无法共存 |
| 每版都换包名 | 用户每次都要卸载重装并重新配对 |

## 检查方式

`scripts/verify.ps1` 断言 `AppScope/app.json5` 的 `bundleName` 仍为 `io.github.sayach.dshmobile.hmos`。
