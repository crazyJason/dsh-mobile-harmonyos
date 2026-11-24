# ADR-0001 自定义 CA 的请求走 `TLSSocket`，不用 `@ohos.net.http`

- 状态：已采纳
- 日期：2026-11
- 相关文件：`entry/src/main/ets/protocol/TlsHttp.ets`、`entry/src/main/ets/protocol/GatewayHttp.ets`

## 背景

`dsh-mobile` 插件在局域网与自签名 FRP 入口上使用**插件自己签发的配对 CA**，不是公共 CA。手机必须把这个 CA 当作唯一信任锚，才能向网关发送配对令牌和设备凭据；系统信任库对这类证书一律拒绝。

HarmonyOS 的 `@ohos.net.http` 提供两个可用开关：

| 能力 | 起始 API |
| --- | --- |
| `caPath`（沙箱内 PEM 文件作为信任锚） | 10 |
| `remoteValidation`（`'skip'` 或自定义校验回调） | 18 |
| `caData`（PEM 字符串） | 20 |

首次配对必须走「**先不信任、拿到 CA 后再验证指纹**」的 bootstrap 链路（见 ADR-0002）：此时还没有任何 CA 可用于 `caPath`，只能用 `remoteValidation: 'skip'` 或 `'system'`。

本项目的 `compatibleSdkVersion` 是 **API 12**（HarmonyOS NEXT 5.0 首发版本）。若改用 `@ohos.net.http`，bootstrap 需要 API 18，等于把最低兼容版本提高两个大版本。

## 决策

**所有携带自定义 CA 的请求都通过 `protocol/TlsHttp.ets` 的 `TLSSocket` 实现，禁止改回 `@ohos.net.http`。**

`TlsHttp.ets` 是一个最小 HTTPS/1.1 客户端，只服务于插件的几个 JSON 控制接口（`ca.cer`、`discovery`、`metadata`、`native-pair`、`native-renew`、`native-probe`），不承载页面流量：

- 三档信任模式 `TrustMode.SYSTEM` / `PINNED` / `SKIP`；
- `PINNED` 时把固定 CA 放进 `secureOptions.ca`，**替换**系统信任库（而不是追加）；
- `SKIP` 只用于 bootstrap，其响应在指纹校验通过前不被信任；
- 只读 `Content-Length` 或 `Transfer-Encoding: chunked`，超过 64 KiB 直接失败；
- 连接、读取、解析各阶段都有超时，错误映射到 `AuthFailureKind`。

页面流量（含 WebSocket、SSE）仍由 ArkWeb 承载，SSL 错误由 `BrowserView` 单独裁决。

## 后果

- 最低兼容版本保持在 API 12；
- 信任锚由我们自己指定，比系统信任库更严格；
- 代价：需自己维护 HTTP/1.1 解析（只覆盖本项目需要的子集），没有连接复用、没有 gzip；
- 代价：`@ohos.net.http` 的系统代理、DoH 等能力不可用（本项目不需要）。

## 被否决的方案

| 方案 | 否决理由 |
| --- | --- |
| `@ohos.net.http` + `caPath` + `remoteValidation: 'skip'` | bootstrap 需要 API 18，破坏 API 12 兼容承诺 |
| `@ohos.net.http` + `remoteValidation` 自定义校验回调 | 同上（API 18），且回调形式的 hostname 校验语义需要额外验证 |
| 只用 `remoteValidation: 'skip'` 不做固定 | 任何能劫持网络的第三方都能拿到配对令牌和设备凭据 |
| 自建 TCP + 手写 TLS | 平台已提供 `TLSSocket`，自己实现握手没有收益且更容易出错 |
| 让用户手动信任证书（系统设置里安装 CA） | 需要用户改系统信任库，侵入性强、不可撤销、且在鸿蒙上体验极差 |

## 检查方式

`scripts/verify.ps1` 的「协议守卫」一节会扫描 `entry/src/main/ets`，出现 `@ohos.net.http` / `http.createHttp` 即判失败。
