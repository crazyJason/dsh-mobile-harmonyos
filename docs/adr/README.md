# 架构决策记录（ADR）

本目录记录**已经定型**的设计取舍。写 ADR 的目的不是追认现状，而是让后来者知道「为什么不能那样改」。
修改被 ADR 约束的代码前，先读对应 ADR；要推翻决策，先写一篇新的 ADR 把它取代（不要直接改旧 ADR 的结论）。

| 编号 | 标题 | 约束的代码 |
| --- | --- | --- |
| [0001](0001-tlssocket-over-ohos-net-http.md) | 自定义 CA 的请求走 `TLSSocket`，不用 `@ohos.net.http` | `protocol/TlsHttp.ets` |
| [0002](0002-trust-root-is-instance-id.md) | 信任根只有 `instanceId = SHA-256(配对 CA DER)` | `protocol/CertPin.ets`、`service/AppService.ets` |
| [0003](0003-device-credential-in-asset-store.md) | 设备凭据存 Asset Store Kit，元数据存 preferences | `model/DeviceStore.ets` |
| [0004](0004-repo-name-and-bundle-namespace.md) | 仓库名与 `bundleName` 的命名空间 | `AppScope/app.json5` |
| [0005](0005-native-rewrite-not-shell.md) | 原生 ArkTS 重写，而不是套壳 WebView / 复用 Android 客户端 | `entry/src/main/ets/` |
| [0006](0006-scan-with-system-scankit-ui.md) | 扫码用系统 Scan Kit 默认界面，不自绘取景器、不申请相机权限 | `common/Scanner.ets`、`pages/Index.ets` |

编号一旦占用就不复用；若两篇撞号，后者顺延到下一个空号（0005 即由此而来）。

## 模板

```markdown
# ADR-XXXX 标题

- 状态：已采纳 / 已取代（由 ADR-YYYY）
- 日期：YYYY-MM
- 相关文件：…

## 背景
发生了什么、受什么平台限制、为什么需要做选择。

## 决策
一句话结论 + 具体规则（可执行、可检查）。

## 后果
好处、代价、需要注意的边界。

## 被否决的方案
逐一列出，并说明否决理由。没有这一节说明决策还没想清楚。
```

## 什么时候需要写 ADR

- 改变了信任模型、凭据存储位置或网络传输方式；
- 为了绕过平台限制而手写了本可由系统 API 完成的功能；
- 引入了无法在编译期发现、只能靠真机验证的行为；
- 决定了命名空间、包名、协议版本这类「改了就回不去」的东西。
