# ADR-0004 仓库名与 `bundleName` 的命名空间

- 状态：已采纳（`bundleName` 已于 2026-11-24 变更，早于首次真机安装）
- 日期：2026-11
- 相关文件：`AppScope/app.json5`、`scripts/install.ps1`、`scripts/verify.ps1`、`README.md`、`docs/BUILD.md`

## 背景

本仓库是上游 [dsh-mobile](https://github.com/saya-ch/dsh-mobile) 的**社区实现**（HarmonyOS NEXT 手机端），不是上游官方的一部分，也不属于 DeepSeek 或华为。

命名要同时满足四件事：

1. 不冒充上游官方发布物；
2. 保留与上游的派生关系（用户能看出这是同一个插件的手机端）；
3. 应用身份归属清晰——`bundleName` 不应占用上游作者的 GitHub 命名空间；
4. 一旦有人装上，后续版本必须能覆盖安装（`bundleName` 改了就是一个新 App，旧安装既不能升级也不能迁移数据）。

早期版本直接沿用了上游 Android 包名的命名空间（`io.github.sayach.dshmobile.hmos`），第 3 条不成立：应用身份被挂在上游作者名下，且若上游将来发布官方 HarmonyOS 客户端，两者有撞包风险。

## 决策

- **仓库名**：`dsh-mobile-harmonyos`。
  - 保留 `dsh-mobile-` 家族前缀，一眼能看出与上游的关系；
  - 平台名用完整单词 `harmonyos`（而不是 `hmos` / `ohos`），搜索能同时命中 `harmony`、`harmonyos` 与中文「鸿蒙」相关查询；
  - **本地目录名可能仍是 `dsh-hmos-mobile`**（历史目录），两者指同一个工程；仓库名以本 ADR 为准。
- **`bundleName`**：`io.github.crazyjason.dshmobile.hmos`
  - 前缀 `io.github.crazyjason` = 本仓库维护者的 GitHub 命名空间，应用身份归属明确；
  - 中段 `.dshmobile` 保留与上游插件的派生标识（不是 `dsh-mobile-community` 之类模糊命名）；
  - 结尾 `.hmos` 明确平台，与上游 Android 包名 `io.github.sayach.dshmobile` 不冲突，可共存；
  - 版本号与应用名独立维护（当前 `0.1.0`），不跟随插件版本。
- **文档措辞**：一律写明「社区实现、非官方」，不出现任何暗示官方支持的表述。

> 变更时机：该改名发生在**任何真机安装之前**（本仓库至今只有命令行编译产物，未签名、未上机）。一旦装机或发布，`bundleName` 就不可再改。

## 后果

- 应用身份归属本项目维护者，不再占用上游作者的命名空间；
- 与上游 Android 客户端、以及上游未来可能发布的官方鸿蒙客户端都不会撞包，可共存；
- 变更前装过旧 `bundleName` 测试包的设备需要卸载重装（当前无此情况，但换机复现时注意）；
- 代价：`bundleName` 里带维护者个人 handle，若将来迁移到组织账号（如 GitHub org）需要再来一次「换 App」级别的变更，因此**组织化必须在下次装机前决定**。

## 被否决的方案

| 方案 | 否决理由 |
| --- | --- |
| 保留 `io.github.sayach.dshmobile.hmos`（早期实现） | 应用身份挂在上游作者命名空间下，语义错误，且与上游未来官方鸿蒙版可能撞包 |
| `com.deepseek.harness.mobile` 之类 | 冒充官方命名空间，误导用户 |
| `io.github.crazyjason.dshmobile`（不带平台后缀） | 与上游 Android 包名冲突，无法共存 |
| 完全沿用上游 `io.github.sayach.dshmobile` 不加后缀 | 同上，且无法区分平台 |
| 每版都换包名 | 用户每次都要卸载重装并重新配对 |

## 检查方式

`scripts/verify.ps1` 断言 `AppScope/app.json5` 的 `bundleName` 仍为 `io.github.crazyjason.dshmobile.hmos`；任何无意的改动会让验证失败，迫使改动者先更新本 ADR 与文档示例。
