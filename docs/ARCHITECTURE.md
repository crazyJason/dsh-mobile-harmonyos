# 架构说明

本文说明 `dsh-mobile-harmonyos` 的分层、模块职责、关键数据流、证书固定设计，以及每个模块在上游 Android 客户端中的对应物。

> **状态**：以下描述对应本仓库当前代码。应用已在本机编译为 HAP，但**没有真机运行证据**；涉及运行时行为的判断（线程调度、ArkWeb 行为、跨应用生命周期）属于设计预期，需按 [TESTING.md](TESTING.md) 在真机验证。

- [1. 设计目标与约束](#1-设计目标与约束)
- [2. 总体结构](#2-总体结构)
- [3. 模块地图](#3-模块地图)
- [4. 应用启动与生命周期](#4-应用启动与生命周期)
- [5. 线程、并发与异步](#5-线程并发与异步)
- [6. 状态管理与持久化](#6-状态管理与持久化)
- [7. 配对流程](#7-配对流程)
- [8. 浏览流程](#8-浏览流程)
- [9. 证书固定设计](#9-证书固定设计)
- [10. 响应校验策略](#10-响应校验策略)
- [11. 失败分类与用户提示](#11-失败分类与用户提示)
- [12. 局域网发现的并发模型](#12-局域网发现的并发模型)
- [13. 与上游 Android 组件的对照](#13-与上游-android-组件的对照)
- [14. 安全不变量](#14-安全不变量)
- [15. 已知缺口与后续工作](#15-已知缺口与后续工作)

---

## 1. 设计目标与约束

| 目标 | 落地方式 |
| --- | --- |
| 原生 HarmonyOS NEXT | 纯 ArkTS/ArkUI（Stage 模型），不依赖 Android 运行时、不嵌入 WebView 兼容层 |
| 最低 API 12 | `compatibleSdkVersion 5.0.0(12)`；为此避开 API 18/20 才有的 `@ohos.net.http` 自定义 CA 能力 |
| 与上游协议一致 | 配对链接/字段名/错误码照抄上游，协议文档见 [PROTOCOL.md](PROTOCOL.md) |
| 安全优先 | 只接受 HTTPS、CA 指纹固定、凭据入系统密钥库、会话不落盘、响应白名单校验 |
| 零第三方依赖 | `oh-package.json5` 无 dependencies；TLS/HTTP、JSON、证书处理全部用系统 Kit |
| 可维护 | 协议层与 UI/服务层分离；协议规则可在设备上自检（`common/SelfCheck.ets`） |

约束：

- 手机端只承担**客户端**角色：不修改 DSH 页面、不代理 DSH 的其他端口、不下载/执行远程代码。
- 页面浏览通过 ArkWeb 完成；原生代码只负责控制平面（配对、续期、探活、发现、证书续接、Cookie 注入）。
- 上游 `dsh-mobile` 是协议事实来源；本项目不复制上游实现，只实现已文档化的线协议。

## 2. 总体结构

```text
┌──────────────────────────────────────────────────────────────┐
│ EntryAbility (UIAbility)                                     │
│   onCreate: AppService.attachContext(this.context)           │
│   onWindowStageCreate: loadContent('pages/Index')            │
└───────────────┬──────────────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────────────┐
│ pages/Index.ets  — 单页面三视图（LIST / ADD / BROWSER）        │
│   ├─ 设备列表：探测状态、打开、长按管理（重命名/删除）          │
│   ├─ 添加设备：粘贴链接/密钥、局域网扫描、手填地址、开始配对     │
│   └─ BrowserView：ArkWeb 容器（会话续期、Cookie、SSL 续接）    │
└───────────────┬──────────────────────────────────────────────┘
                │（UI 只调用 AppService）
┌───────────────▼──────────────────────────────────────────────┐
│ service/AppService.ets  — 单例（配对/续期/探活/发现/SSL 决策） │
└───┬───────────────┬──────────────────┬───────────────────────┘
    │               │                  │
┌───▼─────────┐ ┌───▼────────────┐ ┌───▼───────────────────────┐
│ model/      │ │ protocol/      │ │ common/                   │
│ DeviceRecord│ │ Origin         │ │ Log / Json / Theme /      │
│ DeviceStore │ │ PairingKey     │ │ SelfCheck                 │
│             │ │ CertPin        │ └───────────────────────────┘
│             │ │ TlsHttp        │
│             │ │ GatewayHttp    │
│             │ │ Discovery      │
│             │ │ AuthFailure    │
└─────────────┘ └────────────────┘
```

分层原则：

1. **protocol/** 只依赖系统 Kit 与 common，不依赖 UI；负责线协议、校验、TLS。
2. **model/** 只描述数据与本地持久化；不发起网络请求。
3. **service/** 编排用例：配对、续期、探活、状态更新、Cookie 注入、SSL 决策；是 UI 唯一入口。
4. **pages/** 只做展示与用户交互；ArkWeb 相关的浏览器策略集中在 `BrowserView.ets`。

## 3. 模块地图

| 文件 | 职责 | 关键导出 |
| --- | --- | --- |
| `entryability/EntryAbility.ets` | UIAbility 生命周期；挂载 Ability Context；加载 `pages/Index`；设置系统栏配色 | `EntryAbility` |
| `pages/Index.ets` | 根页面。用 `view` 状态在列表 / 添加 / 浏览三视图间切换；设备探活与配对交互 | `Index` |
| `pages/BrowserView.ets` | ArkWeb 容器：会话续期 → 注入 Cookie → 加载页面；SSL 错误续接（`https`/`wss` 同 authority）；导航拦截；10 分钟定时续期 | `BrowserView` |
| `service/AppService.ets` | 用例编排：配对、续期、探活、设备 CRUD、Cookie 安装、SSL 续接决策、发现入口；失败文案；TLS 失败时记录服务端证书指纹前缀用于诊断 | `AppService`、`interpretPairingInput`、`describeFailure` |
| `model/DeviceRecord.ets` | 已配对电脑的数据模型、状态枚举、JSON 序列化/反序列化 | `DeviceRecord`、`DeviceStatus`、`AccessMode`、`toJson`、`fromJson` |
| `model/DeviceStore.ets` | 持久化：preferences 存元数据，Asset Store Kit 存设备凭据 | `DeviceStore` |
| `protocol/Origin.ets` | HTTPS origin 严格解析、配对 URL 解析、同源/固定 authority 判定、私网地址判断 | `GatewayOrigin`、`parseOrigin`、`parseConnection`、`isSameOrigin`、`isPinnedAuthority` |
| `protocol/PairingKey.ets` | 配对密钥（`dsh1`/`dsh2` 裸密钥）与 URL 片段（`dsh2`/legacy）解析；CA 要求与降级保护 | `PairingKey`、`PairingTarget`、`parsePairingKey`、`pairingKeyFromUrl`、`preserveRemotePin` |
| `protocol/CertPin.ets` | DER↔PEM、SHA-256 指纹、ASN.1 有效期解析、配对 CA 校验、服务端证书链校验。注意 `checkValidityWithDate` 只接受 ASN.1 时间文本，因此有效期由 `parseAsn1Time` 自行比较 | `sha256Hex`、`derToPem`、`pemToDer`、`parseAsn1Time`、`validatePairingCa`、`chainMatchesPinnedCa`、`chainContainsPinnedCa` |
| `protocol/TlsHttp.ets` | 基于 `TLSSocket` 的最小 HTTPS/1.1 客户端；`TrustMode` 三档信任（`SYSTEM`/`PINNED`/`SKIP`）；超时与大小上限；错误分类 | `tlsRequest`、`TrustMode`、`TlsRequestOptions`（`pinned()` / `system()` / `bootstrap()`） |
| `protocol/GatewayHttp.ets` | `discovery` / `ca.cer` / `metadata` / `native-pair|renew|probe`（含 system-trust 变体）；严格响应校验 | `GatewayClient`、`NativeSession`、`NativeProbe`、`GatewayDiscovery`、`GatewayMetadata` |
| `protocol/Discovery.ets` | 局域网发现：UDP 广播 + DNS-SD + HTTPS 子网扫描兜底 | `LanDiscovery`、`parseAnnouncement`、`DISCOVERY_QUERY`、`MDNS_SERVICE_TYPE` |
| `protocol/AuthFailure.ets` | 失败分类枚举与 HTTP 状态/错误码映射；`STORAGE` 表示设备凭据无法持久化 | `AuthFailure`、`AuthFailureKind`、`failureForStatus` |
| `common/Json.ets` | 有界、类型安全的 JSON 读取（不做整体 `as` 断言） | `parseJsonObject`、`readString`、`readNumber`、`keyCount` |
| `common/Log.ets` | hilog 封装（domain `0x0D5B`、tag `DshMobile`） | `Log` |
| `common/Theme.ets` | 深色主题调色板与相对时间格式化 | `Palette`、`formatRelative` |
| `common/SelfCheck.ets` | 设备端协议规则自检（origin 解析与拒绝规则、`dsh1`/`dsh2` 密钥、配对链接与 legacy 片段、同源与 `wss:` 固定 authority、ASN.1 有效期解析） | `runSelfCheck`、`SelfCheckResult` |

## 4. 应用启动与生命周期

1. `EntryAbility.onCreate` 把 `UIAbilityContext` 交给 `AppService.get().attachContext()`。页面不直接查 Ability，避免每个组件重复获取 context。
2. `onWindowStageCreate` 加载 `pages/Index`，随后设置状态栏/导航栏为深色，与应用深色主题一致；设置失败只记日志。
3. `Index.aboutToAppear` 调用 `AppService.initialize()`：初始化 `DeviceStore`（preferences）并读取设备列表（同时从 Asset Store 取回凭据），随后刷新每台设备状态。
4. 视图切换不做路由：`Index` 内用 `@State view` 在 `LIST` / `ADD` / `BROWSER` 之间切换，避免路由栈反复重建 ArkWeb 容器；`BrowserView` 只有在 `BROWSER` 视图存在。
5. `BrowserView.aboutToAppear` 立即续期会话并挂载 Web；`aboutToDisappear` 清除 10 分钟续期定时器。
6. 没有后台 Service、没有 `BackgroundTask`、没有推送回调；应用退到后台后不保证继续续期或保持页面状态（见 [TESTING.md](TESTING.md) 的场景 7）。

设计取舍：ArkWeb 容器与设备列表互斥显示，设备列表刷新不会重建 Web 容器；但离开浏览视图会销毁 `BrowserView`，下次进入需要重新续期并重新加载（会话由 `native-renew` 重建，不依赖页面状态）。

## 5. 线程、并发与异步

ArkTS 的 UI 与业务代码运行在应用主线程的事件循环上。本项目没有显式创建 Worker/TaskPool，所有 I/O 都是异步 API：

| 操作 | 异步机制 | 并发控制 |
| --- | --- | --- |
| TLS 请求 | `TLSSocket` + `Promise`；`withTimeout` 包装连接/发送；轮询 20 ms 收集响应 | 每次请求独立 socket，`finally` 关闭 |
| 局域网发现 | UDP `on('message')` 回调 + DNS-SD `on('serviceFound')` + `Promise` 超时 | 三路径 `Promise.all` 并发；结果按 `instanceId` 合并；UI 用 `scanBusy` 防止重复扫描 |
| 子网扫描 | 固定并发 worker（当前 24 个）共享游标 | 只在被动发现为空时执行 |
| 设备状态刷新 | 对每台设备并行 `probe` | UI 先置 `CHECKING`，回填后整体刷新列表 |
| 会话续期 | 进入浏览页前 `await`；浏览中每 10 分钟后台续期 | 续期失败仅告警，不主动踢出页面；下次进入会重试 |
| 配对 | 用户点击「开始配对」后串行执行（`busy` 标志） | 防止重复提交 token（token 一次性，重复提交会失败） |

注意事项：

- 每个网络调用都有超时（bootstrap 与认证两档），不会无限等待；
- 响应体有大小上限（头 16 KiB + 体 64 KiB），避免内存放大；
- 没有长时间占用主线程的同步计算（SHA-256 使用 `cryptoFramework` 异步接口，证书解析使用系统异步接口）；
- UI 列表更新采用「整体替换数组」的方式触发 `@State` 刷新，设备数量很少，成本可接受。

## 6. 状态管理与持久化

### 6.1 内存状态

- `AppService` 是设备记录的单一事实来源（`devices: DeviceRecord[]`）；
- `Index` 用 `@State devices` 保存列表快照，操作完成后调用 `reloadDevices()` 从 `AppService` 重新取；
- `BrowserView` 用 `@Prop record` 接收当前设备，内部维护 `ready` / `failure` / `progress` / `pageTitle` 等视图状态。

### 6.2 持久化布局

| 数据 | 存储 | 细节 |
| --- | --- | --- |
| 设备元数据 | `@ohos.data.preferences`，name `dsh_mobile_devices`，key `records` | 值为 JSON 字符串数组，每个元素是一条记录的 JSON；不含 `deviceToken` |
| 设备凭据 `deviceToken` | **Asset Store Kit**（`@ohos.security.asset`） | alias = `dsh-mobile/<instanceId>/<origin>`；`ACCESSIBILITY = DEVICE_UNLOCKED`；不写 preferences |
| 会话 token | 仅内存 | `installCookies` 写入 ArkWeb 后不持久化；重启后重新 `native-renew` |
| 固定 CA | preferences 中的 `caPem` | PEM 文本；公网证书入口为空字符串 |
| 安装标识 `installationId` | preferences | 仅用于展示/兼容，不是密钥 |

读取策略：

- `DeviceStore.load()` 逐条解析记录，`fromJson` 失败或关键字段缺失（`key`、`instanceId`、`deviceId` 为空）直接丢弃该条，**不修复**；
- 凭据读取失败（`ASSET_NOT_FOUND`）不视为列表损坏，记录仍在但 `deviceToken` 为空，UI 会提示重新配对；
- 写入凭据采用「先删后加」，避免同 alias 重复；
- 删除设备时先删除 Asset Store 中的凭据，再保存列表。

设计理由：

- preferences 是明文文件，适合元数据，不适合长期密钥；
- Asset Store 由系统密钥库保护，设备解锁后可读（`DEVICE_UNLOCKED`），备份/导出不会带出可用凭据；
- 会话凭据短命，放内存 + 浏览器 Cookie 即可，减少落盘面。

## 7. 配对流程

```text
用户粘贴链接/密钥
      │
      ▼
interpretPairingInput()                     service/AppService.ets
  ├─ parseConnection()                      protocol/Origin.ets
  ├─ pairingKeyFromUrl() / parsePairingKey() protocol/PairingKey.ets
  └─ 完整链接 → 直接得到 PairingTarget
     裸密钥   → Index 用「扫描结果」或「手填 host:port」得到 origin，
                再直接构造 PairingTarget（不重新拼 URL），
                并校验发现的 instanceId 与密钥一致
      │
      ▼
AppService.pair(target, label, displayName)
  ├─ GET /mobile-access/ca.cer（bootstrap 模式）      protocol/GatewayHttp.ets
  ├─ validatePairingCa(DER, instanceId)               protocol/CertPin.ets
  │    ├─ SHA-256(DER) == instanceId
  │    ├─ BasicConstraints CA >= 0
  │    ├─ 有效期校验
  │    └─ 自签名验签
  ├─ 无 CA 且（私网入口或密钥要求 CA）→ TLS 失败（身份不匹配）
  ├─ 无 CA 且为远程公网证书入口 → 平台信任库（system 模式）
  ├─ 有 CA → 固定 CA（pinned 模式）
  ├─ POST /mobile-access/auth/native-pair            protocol/GatewayHttp.ets
  ├─ 严格校验响应（键集合/格式/时间）
  ├─ 写 Asset Store 凭据 + 保存记录                  model/DeviceStore.ets
  └─ 返回 PairingResult
      │
      ▼
Index 回到列表视图并刷新
```

关键行为：

- **局域网/私网入口必须提供 CA**：`target.remote === false` 时，`/mobile-access/ca.cer` 404 直接以 `AuthFailureKind.TLS` 失败，不进入系统信任库；这与上游 `PairingTrust.selectTrustAnchor` 的 LAN 规则一致。
- **只有公网证书远程入口允许 404 回退**：`target.remote === true` 且密钥 `requiresCa === false` 时，404 才使用平台信任库（`pairWithSystemTrust()`）。
- **`dsh2` 强制 CA**：即使远程，`requiresCa === true` 的密钥在 404 时同样硬失败。`#key=dsh1...` 不是上游生成的片段，客户端按上游规则拒绝，属于预期行为。
- **裸密钥需要地址**：`dsh1` / `dsh2` 裸密钥本身不含 origin，需要用户扫描选择电脑或手填 `host:port`；公网证书入口就是通过 `dsh1` 裸密钥 + 地址进入 `pairWithSystemTrust()` 分支的。
- 配对成功后记录以 `instanceId + origin` 为稳定 key；同一台电脑重新配对会复用记录名（`adoptIdentity`）并更新凭据。
- 一次性 token 不写入任何持久化存储，配对结束即丢弃。
- 写凭据失败会被归类为 `STORAGE`，UI 提示本地保存失败，避免用户误以为凭据已保存。
- TLS 失败时（仅 TLS 失败），客户端会额外用 `fetchServedCertificate` 读取本次连接服务端证书的 SHA-256 前缀并写日志；日志只记录前 16 位十六进制，不包含 token/密钥，用于区分“证书不是约定的那张”与“网络问题”。

## 8. 浏览流程

```text
用户点击设备卡
      │
      ▼
BrowserView.aboutToAppear()
  ├─ AppService.renewSession(record)
  │    ├─ 检查 deviceExpiresAt（过期 → DEVICE_EXPIRED）
  │    ├─ 有固定 CA → pinned 模式；否则 system 模式
  │    ├─ POST /mobile-access/auth/native-renew
  │    └─ installCookies(origin, session) → WebCookieManager
  ├─ 记录 lastConnectedAt（markConnected）
  ├─ url = https://<host>:<port>/
  └─ 挂载 Web 组件
      │
      ▼
页面加载中
  ├─ onSslErrorEvent → shouldContinueSslError()
  │    ├─ 证书链包含固定 CA 或 leaf 能由固定 CA 验签 → handleConfirm()
  │    └─ 否则 handleCancel() 并显示“证书与配对信息不一致”
  ├─ onLoadIntercept → 同源放行；其他 HTTPS 交给系统浏览器；其他 scheme 放行给 Web 自己处理
  └─ onPageEnd → loading=false
      │
      ▼
浏览期间：每 10 分钟 renewSession（失败只记日志）
```

要点：

- 会话续期发生在 Web 首次加载**之前**；没有有效 Cookie 时不会挂载页面。
- ArkWeb 对 WebSocket 握手失败会以 `wss:` URL 上报 SSL 错误，因此 URL 判定使用 `isPinnedAuthority`（允许 `https`/`wss` 两种 scheme，host/port 必须一致），而不是严格的 `isSameOrigin`。
- SSL 错误处理是**白名单**：只有能证明链属于固定 CA 的证书才继续；公网证书入口（无固定 CA）时 `shouldContinueSslError` 返回 false，即不覆盖系统的 SSL 错误策略。
- `sslConfirmed` 在同一个 `BrowserView` 实例内缓存：一旦某次请求的链被确认，后续同类 SSL 错误直接放行，避免每张资源都做证书运算；离开页面后重置。
- 导航拦截只处理 `onLoadIntercept` 的 URL：同源（含端口）放行；其他 HTTPS 用 `startAbility(viewData)` 交给系统浏览器；非 HTTPS 不做额外处理。
- Web 组件配置：开启 JS 与 DOM Storage（DSH 前端需要），关闭文件访问（`fileAccess(false)`），混合内容用 `Compatible`（页面依赖网关同源资源），暗色模式跟随系统。

## 9. 证书固定设计

### 9.1 三种信任模式

`protocol/TlsHttp.ets` 用 `TrustMode` 表达一次请求如何验证网关，并通过 `TlsRequestOptions` 的静态构造器选择：

| 模式 | 构造器 | 实现 | 使用点 |
| --- | --- | --- | --- |
| `SKIP`（bootstrap） | `TlsRequestOptions.bootstrap(timeoutMs)` | `skipRemoteValidation: true`，不提供 CA | 读 `discovery`、`ca.cer` |
| `PINNED` | `TlsRequestOptions.pinned(timeoutMs, caPem)` | `secureOptions.ca = <CA PEM>`（**替换**平台信任库） | 所有已固定 CA 的控制请求 |
| `SYSTEM` | `TlsRequestOptions.system(timeoutMs)` | 不设 CA、不跳过校验，使用平台信任库 | 公网证书远程入口（不要求 CA 的密钥）且 `ca.cer` 404 |

### 9.2 bootstrap 链路

首次连接时手机还没有可用的信任锚，因此：

1. 用 `SKIP` 建立 TLS（此阶段不校验证书）；
2. 读取 `/mobile-access/ca.cer`（或 `/discovery`）；
3. 对 CA 做校验：`SHA-256 == instanceId`、有效期、自签名（用自己的公钥验签）；
4. 只有校验通过，才把 CA 交给后续 `PINNED` 请求。

**这是“先取证书再验证”，不是“先信任再验证”**：在 CA 通过指纹校验前，不会发送任何凭据（`native-pair` 永远在 CA 校验之后）。`discovery` 本身不携带秘密，但也会校验 origin/port 自洽。

> **CA 基本约束不能当门禁（2026-11-24 真机结论）**：HarmonyOS 的 `X509Cert.getBasicConstraints()` 返回的是**路径长度**，
> 对「CA:TRUE 但没有 pathLenConstraint」的证书返回 `-1`。`dsh-mobile` 生成的配对 CA 正好省略该可选字段，
> 因此早期把 `< 0` 判成“不是 CA”的实现会**拒掉所有这类网关**（真机上表现为配对时“网关证书与配对信息不一致”）。
> 现在只记录该值供排障，信任判定仍由指纹 + 有效期 + 自签名承担；锚点若不是 CA，后续握手也无法通过。

有效期校验不调用 `checkValidityWithDate`（该 API 只接受 ASN.1 时间文本，传 ISO-8601 会抛异常，从而误拒所有局域网配对）。`CertPin.ets` 用 `parseAsn1Time` 解析 `getNotBeforeTime()` / `getNotAfterTime()`：支持 UTCTime `YYMMDDHHMMSSZ` 与 GeneralizedTime `YYYYMMDDHHMMSSZ`，两位年份以 50 为分界（`>=50` 归 19xx，否则 20xx），再与 `Date.now()` 比较。该解析器也被设备端自检覆盖。

### 9.3 固定 CA 的 TLS 行为

- `TLSSocket.connect` 的 `secureOptions.ca` 传入 PEM 后，**信任库被替换为这一个锚点**；
- 服务端证书必须能链到该 CA（局域网网关通常直接下发该 CA 签发的叶子证书）；
- CA 不合法/过期/指纹不符时，客户端在建立连接前就失败，不会降级；
- 不做“忽略证书错误”的开关，也不提供用户可见的跳过按钮。

### 9.4 ArkWeb 的 SSL 错误续接

ArkWeb 对自签证书会触发 `onSslErrorEvent`。本项目不盲目 `handleConfirm()`，而是：

1. 取 `event.certChainData`（DER 链）与 `event.url`；
2. URL 必须与已配对 origin 的**固定 authority** 一致（`https`/`wss`，host/port 相同），否则取消；
3. 链中任意证书的 SHA-256 等于 `instanceId`，或链首证书能由固定 CA 验签 → 确认；
4. 否则取消并提示证书不匹配。

这样即使攻击者让 ArkWeb 连到错误证书，也无法通过固定 CA 校验。

### 9.5 为什么用 `TLSSocket` 而不是 `@ohos.net.http`

决定性原因：**API 12 兼容性**。

- `@ohos.net.http` 在较早版本只能使用系统信任库，不能按请求指定自定义 CA；
- 自定义 CA / `remoteValidation` 相关能力在 API 18/20 才逐步提供；
- 本工程 `compatibleSdkVersion` 是 `5.0.0(12)`，必须在 API 12 设备上工作，因此不能依赖这些新参数。

`TLSSocket` 的 `secureOptions.ca` 从早期 API 就存在，可以在 API 12 上实现“每次请求携带固定 CA”。代价是需要自己实现一个最小 HTTPS/1.1 客户端：

| 自己实现的部分 | 说明 |
| --- | --- |
| 请求构造 | 方法、路径、`Host`、`Connection: close`、`Content-Length`、自定义头 |
| 响应解析 | 状态行、头（小写归一化）、`Content-Length` / `Transfer-Encoding: chunked` |
| 边界 | 头 ≤ 16 KiB、体 ≤ 64 KiB、总大小上限、连接/读取超时 |
| 错误分类 | TLS 握手错误码 → `TLS`；连接超时 → `TIMEOUT`；其他 → `NETWORK` |
| 证书读取 | `getRemoteCertificate()`（保留给需要读取服务端证书的排查路径） |

控制接口只有 6 个、JSON 很小，这个客户端的复杂度可控；页面流量仍由 ArkWeb 处理，不需要通用浏览器能力。

## 10. 响应校验策略

所有网关响应都按“不可信输入”处理：

1. `Content-Type` 必须为 `application/json` 前缀（CA 接口除外）；
2. 响应体大小有上限（控制接口 32 KiB、错误体 8 KiB）；
3. 用 `common/Json.ets` 逐字段读取，禁止 `as SomeShape` 整体断言；
4. `native-pair` / `native-renew` / `native-probe` 校验**精确键集合**（加上可选的 `installationId`）；
5. 所有 token 字段用 `^[A-Za-z0-9_-]{43}$`、`instanceId` 用 `^[a-f0-9]{64}$`、`deviceId` 用 `^[a-f0-9]{32}$`；
6. 时间戳必须是有限的整数且**大于当前时间**；`deviceExpiresAt` 不应早于 `sessionExpiresAt`；
7. `instanceId` 必须回显预期值，否则丢弃整个响应；
8. 错误体只读取 `error` 字段，长度 ≤ 64，拒绝其他结构。

## 11. 失败分类与用户提示

`protocol/AuthFailure.ets` 定义统一失败类别，`service/AppService.ets` 的 `describeFailure()` 将其映射为中文提示：

| 类别 | 触发 | 提示 |
| --- | --- | --- |
| `PAIRING_EXPIRED` | 401/403（无特定 error code） | 配对码已失效或已被使用，请在电脑上重新生成配对链接 |
| `DEVICE_REVOKED` | `{"error":"device_revoked"}` | 这台电脑已撤销本设备的授权，请重新配对 |
| `DEVICE_EXPIRED` | `{"error":"device_expired"}` 或本地 `deviceExpiresAt` 已过 | 设备凭据已过期，请重新配对 |
| `DEVICE_LIMIT` | 409 | 配对设备数量已达上限 |
| `RATE_LIMITED` | 429 | 请求过于频繁 |
| `SOURCE_NETWORK_UNTRUSTED` | `{"error":"source_network_untrusted"}` | 电脑端可信网段不允许当前来源 |
| `TIMEOUT` | 连接/读取超时 | 连接超时 |
| `TLS` | 握手失败、CA 不匹配、证书过期 | 证书校验失败：网关证书与配对信息不一致 |
| `NETWORK` | DNS/连接被拒/网络不可用 | 无法连接电脑 |
| `SERVER_UNAVAILABLE` | 5xx | 电脑端网关暂时不可用 |
| `INVALID_RESPONSE` | 2xx 但字段/键集合不合规 | 网关响应不符合协议，可能插件版本过旧 |
| `STORAGE` | Asset Store 写入失败 | 本地保存设备凭据失败 |

设备状态（`DeviceStatus`）由探活结果驱动：`REACHABLE` / `UNREACHABLE` / `REVOKED` / `EXPIRED` / `CHECKING` / `ADDRESS_CHANGED`（后者为地址变化预留），列表用颜色与文字区分。

## 12. 局域网发现的并发模型

`protocol/Discovery.ets` 的三条路径：

1. **UDP**：绑定 `0.0.0.0:3443`（同时接收网关每 3 秒的主动广播），向 `255.255.255.255`、常见热点网段与各本机 /24 的定向广播地址发送 `DSH_MOBILE_DISCOVER_V1`，等待 3.5 秒；对每个公告校验协议版本、`instanceId`、`deviceName`、`origin`/`port` 自洽，并强制 `origin.host == 发送方地址`。
2. **DNS-SD**：`mdns.createDiscoveryService(context, '_dsh-mobile._tcp')`，监听 `serviceFound`，校验 TXT（`protocol`、`instanceId`、`deviceName`、`origin`）与 SRV 端口。
3. **HTTPS 子网扫描**：仅在被动路径没有结果、且本机有私有 IPv4 网段时执行；每台候选主机发 `GET /mobile-access/discovery`（bootstrap 模式），固定 24 个工作协程共享游标，结果同样要满足 5 键校验。

合并与展示：

- 所有路径的结果按 `instanceId` 去重（`Map`）；
- 结果只是候选，选中后仍需配对 token；
- UI 的「扫描局域网」当前只跑被动路径（`discoverLan(false)`），扫描兜底保留给手动重试或后续版本；
- 扫描时间窗口为秒级，扫描期间不阻塞 UI。

## 13. 与上游 Android 组件的对照

上游路径前缀：`apps/mobile/android/app/src/main/java/io/github/sayach/dshmobile/`。

| Android 组件 | 本项目模块 | 对应内容与差异 |
| --- | --- | --- |
| `GatewayUrlPolicy.kt`（`GatewayOrigin` / `GatewayConnection` / `GatewayUrlPolicy`） | `protocol/Origin.ets` | 同样的 HTTPS-only、origin 规范化、配对 URL 解析、同源/`wss` authority 判定。Android 用 `java.net.URI`；ArkTS 手写 `splitUrl` 以避免平台 URI 的宽松归一化 |
| `PairingTrust.kt`、`RemotePairingTrust.kt` | `protocol/PairingKey.ets` + `protocol/CertPin.ets` | Android 在 `PairingTrust` 内完成 CA 校验与 `preserveRemotePin`；ArkTS 拆成密钥解析（PairingKey）与证书校验（CertPin）。`preserveRemotePin` 已实现但当前 UI 流程未接入 |
| `PairingScanPolicy.kt` | `protocol/PairingKey.ets` | Android 由扫码结果 + 用户选择模式决定 LAN/REMOTE；ArkTS 由 origin 主机判断：`isPrivateNetworkHost`（私有 IPv4、CGNAT `100.64/10`、`localhost`）视为局域网，其余主机名/公网地址视为远程。未复刻上游对 cpolar/cloudflared/ts.net 等隧道厂商后缀的细分 |
| `PinnedTls.kt` | `protocol/TlsHttp.ets` + `protocol/CertPin.ets` | Android 用 `SSLContext` + 自定义 `TrustManagerFactory`（只含固定 CA），并校验 WebView 叶子证书（SAN、EKU、有效期）；ArkTS 用 `TLSSocket.secureOptions.ca` 完成握手信任，再由 `CertPin.ets` 做指纹与“leaf 由固定 CA 验签”的链校验，未实现 SAN/EKU 细分检查 |
| `NativeAuthClient.kt` | `protocol/GatewayHttp.ets` | 同样的接口与响应校验；Android 用 `HttpsURLConnection` + `SSLSocketFactory`，ArkTS 用手写 HTTP/1.1。Android 的超时组合更细（connect/read 分开），ArkTS 以总超时近似 |
| `LanDiscovery.kt` | `protocol/Discovery.ets`（UDP 部分） | 同样的查询串、端口、公告 5 键校验、发送方地址校验、按 instanceId 合并；Android 用 `DatagramSocket`，ArkTS 用 `UDPSocket` |
| `NsdDiscovery.kt` | `protocol/Discovery.ets`（DNS-SD 部分） | 同样的 `_dsh-mobile._tcp`、TXT 校验、SRV 端口校验；Android 需要 MulticastLock，ArkTS 由系统 mDNS 负责 |
| `PairedDeviceStore.kt`、`DeviceCredentialStore.kt` | `model/DeviceRecord.ets`、`model/DeviceStore.ets` | Android 把整行加密后存 SharedPreferences，并单独存设备凭据；ArkTS 把元数据存 preferences、凭据存 Asset Store（系统密钥库），记录模型字段对应 |
| `MainActivity.kt` | `pages/Index.ets` + `pages/BrowserView.ets` | Android 在 Activity 中管理 WebView、SSL 回调、会话恢复；ArkTS 拆成 ArkUI 页面 + ArkWeb 容器，会话续期由 `AppService` 负责 |
| `NativeSessionCookieInstaller.kt` / `NativeSessionCookies.kt` | `service/AppService.ets#installCookies` | 同样的 4 个 Cookie 名与属性；Android 写 `CookieManager`，ArkTS 写 `WebCookieManager` |
| `SecureWebViewClient.kt`（SSL 续接） | `pages/BrowserView.ets#handleSslError` + `AppService.shouldContinueSslError` | 同样的“链中固定 CA 或 leaf 可由固定 CA 验签才放行”策略 |
| `NativeBridge.kt`、`NativeBridgePolicy.kt` | **未实现** | 页面检测不到 `window.dshMobileNative`，运行在上游支持的浏览器模式 |
| `QrDecoder.kt`、`ScanActivity.kt` | **未实现** | 无扫码入口；`module.json5` 未申请相机权限（仅 `INTERNET` / `GET_NETWORK_INFO`），改为粘贴链接或裸密钥 + 地址 |
| `DeviceStatusPoller.kt` | `pages/Index.ets#refreshStatuses` + `AppService.probe` | 简化版：进入列表时逐台探活、菜单里可“立即检测”，没有周期性轮询器 |
| `IrohConnectionController.kt`、`IrohHttpsTransport.kt` 等 | **未实现** | 只支持 HTTPS 直连入口 |
| `AppUpdateChecker.kt` / `BackgroundNotificationService.kt` / `TaskNotificationPublisher.kt` | **未实现** | 无应用内更新、无后台通知 |
| 单元测试（`app/src/test/...`） | `common/SelfCheck.ets`（设备端自检） | Android 用 JVM 单测覆盖协议规则；ArkTS 目前没有单元测试框架接入，改为在设备上运行一组纯规则自检（origin/密钥/链接），不覆盖网络与证书 |

## 14. 安全不变量

以下性质在任何改动中都应保持：

1. **只接受 `https`**：`Origin.ets` 之外的任何地方都不需要处理 `http`；
2. **fragment 不外发**：配对 key 只在本机解析；
3. **配对前不发凭据**：`native-pair` 只能在 CA 校验/系统信任确定之后发送 token；
4. **CA 固定是强制的**：`dsh2` 无 CA 即失败；不能用“忽略证书错误”绕过；
5. **bootstrap 结果必须经指纹校验**：CA 未通过 `SHA-256 == instanceId` 前不信任任何内容；
6. **固定 CA 替换而非追加系统信任库**；
7. **响应白名单**：只接受协议规定的键与格式，`instanceId` 必须回显；
8. **凭据不落 preferences、不写日志**：`deviceToken` / session token 不出现在 hilog；
9. **会话 Cookie 仅 host-only、HTTPS、Strict**；
10. **Web 容器导航限制在固定 authority**，其余 HTTPS 交给系统浏览器；
11. **SSL 错误只在能证明链属于固定 CA 时续接**；
12. **签名材料不入库**（`.gitignore` 覆盖 `*.p7b`、`*.p12`、`*.cer`、`*.pem`）。

## 15. 已知缺口与后续工作

| 缺口 | 影响 | 方向 |
| --- | --- | --- |
| 远程/局域网模式判定比上游简单 | 以 `isPrivateNetworkHost` 判定：私有 IPv4、CGNAT `100.64/10`、`localhost` 为 LAN，其余主机名/公网地址为 REMOTE；不识别 cpolar/cloudflared/ts.net 等隧道厂商后缀。影响仅限超时档位、列表标签与“私网必须供 CA”的判定；证书/凭据校验本身不变 | 可选：复刻上游 `RemoteHostPolicy` 的细分规则 |
| 协议层中 `preserveRemotePin`、`fetchMetadata` 未接入主流程（`isPinnedAuthority` 已用于 SSL 续接与自检，`fetchServedCertificate` 已用于 TLS 诊断日志） | 远程降级保护、metadata 兼容性提示尚未使用 | 在配对/诊断流程中接入 |
| 删除本地设备记录时未主动清除 ArkWeb 中已注入的会话 Cookie | 旧 Cookie 可能残留到会话过期（仍受 host-only/HTTPS/Strict 约束，且只属于同一台电脑） | 在删除/重新配对时用同名 Cookie 过期（`Max-Age=0`）清理 |
| 无 `window.dshMobileNative` 原生桥 | 页面原生增强能力不可用 | 按上游 `NativeBridgePolicy` 定义消息白名单后再实现 |
| 无推送 / 无 iroh / 无扫码 / 无原生文件选择器 | 见 [README 已知限制](../README.md#已知限制) | 后续版本 |
| 无真机自动化测试、无 ArkTS 单元测试 | 协议规则只有自检 + 手工测试 | 引入 ohosTest / Hypium 或把纯规则抽到可测模块 |
| API 12 上的 HttpOnly Cookie 写入依赖降级 | 旧系统上 `HttpOnly` Cookie 可能以非 HttpOnly 形式写入（仍受 HTTPS/host-only 约束） | 跟踪 ArkWeb 能力，必要时改用 `runJavaScript` 兜底（需评估安全性） |

上述缺口不影响“编译成 HAP”，但会影响真机验收结果，测试时按 [TESTING.md](TESTING.md) 记录实际行为。
