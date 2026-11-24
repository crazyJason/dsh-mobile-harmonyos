# ADR-0003 设备凭据存 Asset Store Kit，元数据存 preferences

- 状态：已采纳
- 日期：2026-11
- 相关文件：`entry/src/main/ets/model/DeviceStore.ets`、`entry/src/main/ets/model/DeviceRecord.ets`

## 背景

配对成功后电脑会给手机一个**长期设备凭据** `deviceToken`（43 字符，`[A-Za-z0-9_-]{43}`）。它等价于「这台设备可以继续操作电脑上的 DeepSeek Harness」：持有它就能换取会话令牌。

上游 Android 客户端把它放进 `Android Keystore` 支持的加密存储（`DeviceCredentialStore.kt`），而不是明文 `SharedPreferences`。HarmonyOS 上对应的选择是：

| 方案 | 说明 |
| --- | --- |
| `@ohos.data.preferences` | 明文键值存储，落在应用沙箱 |
| **Asset Store Kit（`@ohos.security.asset`）** | 系统级凭据库，按别名存取，支持「设备解锁后可用」等访问控制 |
| HUKS（`@ohos.security.huks`）+ 自管密文 | 通用密钥库，需要自己设计信封加密 |

## 决策

**元数据与秘密分开存：**

- `DeviceRecord` 的可展示字段（名称、origin、`instanceId`、`deviceId`、自动生成的 PEM 固定 CA、时间戳、状态）序列化后存 `preferences`（文件名 `dsh_mobile_devices`）；
- **`deviceToken` 只存 Asset Store Kit**，别名 `dsh-mobile/<instanceId>/<origin>`，`Accessibility = DEVICE_UNLOCKED`；
- 会话令牌（`sessionToken` / `csrfToken`）**从不持久化**，每次进入浏览页通过 `native-renew` 重新换取，并写入 ArkWeb Cookie；
- 删除设备记录时同步删除对应别名；读取失败（`24000002` not found）按「凭据不存在」处理，不视为错误。

`DeviceRecord.deviceToken` 只是内存字段，`toJson()` 明确不序列化它。

## 后果

- 备份、`preferences` 导出、崩溃转储都不会带出可用的设备凭据；
- 设备锁屏未解锁时读不到凭据，`DeviceStore.readSecret` 返回 `undefined`，列表照常显示但标记为不可连接——这是期望行为，不是缺陷；
- 代价：跨设备迁移（换手机）必须重新配对（与上游一致）；
- 代价：Asset Store 的读写是异步的，`DeviceStore.load()` 需要逐条取秘密；记录数量是个位数，可接受。

## 被否决的方案

| 方案 | 否决理由 |
| --- | --- |
| 明文存 preferences | 备份/导出即泄露，且与上游的安全基线不一致 |
| 自己用 HUKS 加密后存 preferences | 需要信封格式、密钥轮换与迁移逻辑，Asset Store 已经覆盖该场景 |
| 不持久化设备凭据（每次重新配对） | 每次打开都要扫二维码，与上游「配对一次长期可用」的体验冲突 |
| 存进 Cookie（JS 可读位） | 页面脚本即可读出并外传，扩大攻击面 |

## 检查方式

代码审查 + `docs/TESTING.md` 中「删除记录后凭据同步删除」「锁屏未解锁时列表状态」两个用例。
