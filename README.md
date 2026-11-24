# DSH Mobile · HarmonyOS NEXT 原生客户端

面向 [DeepSeek Harness](https://github.com/saya-ch/dsh-mobile) 社区插件 **dsh-mobile** 的 HarmonyOS NEXT（ArkTS / ArkUI）原生手机客户端。它复刻上游 Android 客户端的配对与浏览能力，让 HarmonyOS 手机可以连接运行着 DeepSeek Harness + dsh-mobile 插件的电脑。

> **English summary.** `dsh-mobile-harmonyos` is a native HarmonyOS NEXT (ArkTS/ArkUI) client for the community DeepSeek Harness plugin [`dsh-mobile`](https://github.com/saya-ch/dsh-mobile). The upstream project ships an Android WebView shell that cannot be installed on HarmonyOS NEXT, because HarmonyOS NEXT no longer runs Android APKs. This project reimplements the phone-side client natively: it parses the plugin's one-time pairing link, pins the gateway's self-signed pairing CA against the SHA-256 `instanceId` carried in that link, calls the plugin's `native-pair` / `native-renew` / `native-probe` control endpoints over a hand-written `TLSSocket` HTTP/1.1 client, stores the long-lived device credential in the Asset Store Kit, and loads the DSH mobile page in an ArkWeb container with the paired session cookies installed. The project has been compiled into a HAP on the development machine described below; **it has not been accepted on a real phone yet**, so treat device behaviour as untested.

> **项目状态**
>
> - ✅ 已在本机（DevEco Studio 26.0.0 / HarmonyOS SDK API 26 / hvigor 6.26.9 / JDK 17）用命令行完整编译，产物为 `entry/build/default/outputs/default/entry-default-unsigned.hap`。
> - ⛔ 未签名 HAP 无法安装到真机；签名需要 DevEco Studio 自动签名（登录华为账号）或自备签名材料。
> - ⛔ 尚未在真机上做任何配对、浏览、TLS 或网络切换验收；所有真机行为以潜在缺陷看待，见 [docs/TESTING.md](docs/TESTING.md)。
> - 上游是协议的事实来源（source of truth），本项目与它的对应关系见 [docs/PROTOCOL.md](docs/PROTOCOL.md)。

---

## 这是什么

`dsh-mobile` 是一个 DeepSeek Harness 社区插件：在电脑上的 DSH 旁边启动一个网关（默认 HTTPS 端口 **3443**，路径前缀 `/mobile-access`），把 DSH 的移动端网页暴露给同一局域网或受信任的远程入口，并通过一次性配对链接把手机变成已授权设备。

上游为手机端提供了一个 **Android 客户端**（Kotlin + WebView 外壳）。本项目是同一角色在 **HarmonyOS NEXT** 上的原生实现：

- 用 ArkTS 重写配对链接解析、网关身份校验、证书固定、局域网发现、设备凭据存储；
- 用 ArkWeb 承载 DSH 移动端页面；
- 不使用 Android 兼容层（HarmonyOS NEXT 并不运行 Android APK），也不依赖 WebView 的任何 Android 私有 API。

本项目是**社区实现，非官方**：既不是 DeepSeek Harness 官方仓库的一部分，也不是华为官方示例。协议、字段名和错误码均以上游 `dsh-mobile` 仓库为准。

## 为什么需要

1. **HarmonyOS NEXT 不能安装 Android APK。** 上游客户端打包为 `.apk`，依赖 Android 的 `WebView`、`NsdManager`、`SharedPreferences` 等组件。HarmonyOS NEXT 移除了 Android 运行时兼容层，APK 无法安装，更无法运行。
2. **手机浏览器直接打开网关地址并不能完成配对。** 配对密钥放在 URL 片段（`#...`）中，片段不会被发送到服务器；网页端也没有“把设备凭据交给系统”的能力。原生客户端需要自己解析片段、下载并校验 CA、调用 `native-*` 接口，再把会话 Cookie 装进 Web 容器。
3. **局域网自签证书需要证书固定。** 局域网与自签名 FRP 入口使用插件自签的配对 CA，系统信任库不会信任它。必须在应用内把 CA 固定为信任锚，并证明它确实属于扫描/粘贴的那台电脑——`instanceId` 就是该 CA 证书 DER 的 SHA-256，这是整个信任链的根。

## 功能范围

**已实现（代码层面）**

| 能力 | 说明 |
| --- | --- |
| 配对链接解析 | 接受上游实际生成的两种片段：`key=dsh2.<64hex>.<43char>`（提供自签 CA 的入口）与 `instance=...&token=...`（局域网 / 公网证书 / 旧版）。`#key=dsh1...` 不是上游会写入 URL 的格式，客户端按上游规则拒绝；公网证书入口用 `dsh1` **裸密钥** + 扫描/手填地址配对 |
| 网关身份校验 | 下载 `/mobile-access/ca.cer`，校验「CA 基本约束 + 自签名 + 有效期 + SHA-256 == instanceId」 |
| 原生配对 | `POST /mobile-access/auth/native-pair`，拿到 `deviceToken` / `sessionToken` / `csrfToken` |
| 会话续期与探活 | `native-renew`、`native-probe`，用于恢复连接与判断设备是否被吊销 |
| 局域网发现 | UDP 广播 + DNS-SD（`_dsh-mobile._tcp`）+ HTTPS 子网扫描兜底 |
| 已配对设备管理 | 元数据存 `@ohos.data.preferences`，设备凭据存 **Asset Store Kit**，列表、重命名、删除 |
| 网页浏览 | ArkWeb 容器加载已配对 origin 的 DSH 移动端页面，注入 `dsh_ma_*` 会话 Cookie |
| 失败分类 | 401/403、409、429、`device_revoked` / `device_expired` / `source_network_untrusted` 等给出可读提示 |
| 设备端协议自检 | 空列表可运行「协议自检」：校验 origin 解析/拒绝、`dsh1`/`dsh2` 密钥、配对 URL 与 legacy 片段、同源 vs `wss:` 固定 authority、ASN.1 证书有效期解析；用于确认安装的构建与协议文档一致 |

**未实现（有意延后或受平台限制）**

| 限制 | 影响 |
| --- | --- |
| 无原生扫码 | 需要把电脑上显示的配对链接/密钥**复制/粘贴**到手机；未申请相机权限（manifest 只声明 `INTERNET` / `GET_NETWORK_INFO`），扫码 UI 未实现 |
| 无原生桥 `window.dshMobileNative` | 页面按上游支持的“浏览器模式”运行；原生能力相关 UI（原生分享、文件选择等）不可用 |
| 无推送 | 没有 `mobile-push` 注册，后台任务完成/需要确认时不会收到系统通知 |
| 无 iroh 传输 | 仅支持 HTTPS 直连（局域网 / 自签名 FRP / 公网证书入口），不支持 iroh 点对点通道 |
| 无原生文件选择器桥接 | Web 页面里触发文件选择时依赖 ArkWeb 默认行为，未做上传/下载策略桥接 |
| 无应用内更新、无画中画、无后台服务 | 上游 Android 的这些外围功能未移植 |

## 与上游 Android 客户端的对应关系

| 上游 Android（`apps/mobile/android/.../io/github/sayach/dshmobile/`） | 本项目 HarmonyOS | 说明 |
| --- | --- | --- |
| `GatewayUrlPolicy.kt`（`GatewayOrigin`、`GatewayConnection`） | `protocol/Origin.ets` | HTTPS origin 解析、配对 URL 解析、同源与固定 authority 判定 |
| `PairingTrust.kt`、`PairingScanPolicy.kt` | `protocol/PairingKey.ets` | 配对 key 解析、`dsh2` 必须带 CA、`preserveRemotePin` 降级保护（已实现，尚未接入配对流程） |
| `PairingTrust.kt`、`PinnedTls.kt`（证书部分） | `protocol/CertPin.ets` | DER↔PEM、SHA-256 指纹、配对 CA 校验、服务端证书链校验 |
| `NativeAuthClient.kt` | `protocol/GatewayHttp.ets` | `discovery` / `ca.cer` / `metadata` / `native-pair` / `native-renew` / `native-probe` |
| `PinnedTls.kt`（OkHttp / `SSLSocketFactory`） | `protocol/TlsHttp.ets` | 基于 `TLSSocket` 的手写 HTTPS/1.1 客户端，按请求传入固定 CA |
| `LanDiscovery.kt`、`NsdDiscovery.kt` | `protocol/Discovery.ets` | UDP 广播查询 + DNS-SD 监听 + HTTPS 子网扫描 |
| `PairedDeviceStore.kt`、`DeviceCredentialStore.kt` | `model/DeviceRecord.ets` + `model/DeviceStore.ets` | 设备记录模型；preferences 存元数据，系统密钥库（Asset Store）存凭据 |
| `MainActivity.kt`（WebView 外壳） | `pages/`（设备列表、添加设备、ArkWeb 容器） | 页面容器、SSL 错误续接、会话 Cookie 注入 |
| `NativeBridge.kt`、`NativeBridgePolicy.kt` | **未实现** | 页面检测不到 `window.dshMobileNative`，按浏览器模式运行 |
| `QrDecoder.kt`、`ScanActivity.kt` | **未实现** | 无扫码入口，改为粘贴配对链接或裸密钥 |

更完整的模块级说明见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 环境要求

以下版本是本项目实际验证过的组合（Windows + PowerShell）：

| 组件 | 版本 / 路径 |
| --- | --- |
| DevEco Studio | 26.0.0 |
| HarmonyOS SDK | API 26，安装于 `D:\Programs\Huawei\DevEcoStudio\sdk` |
| hvigor | 6.26.9（随 DevEco Studio 提供） |
| ohpm | 26.0.0.630 |
| JDK | 17（本机 `E:\tools\jdk-17`） |

工程构建参数：

| 配置 | 值 |
| --- | --- |
| `compatibleSdkVersion` | `5.0.0(12)`（最低兼容 API 12） |
| `targetSdkVersion` | `6.0.0(20)` |
| `bundleName` | `io.github.sayach.dshmobile.hmos` |
| 设备类型 | `phone` / `tablet` / `2in1` |
| 模块 | `entry`（Stage 模型） |

> 说明：工程用 API 26 的 SDK 编译，但 `compatibleSdkVersion` 固定为 API 12。这是刻意的：`@ohos.net.http` 的自定义 CA / `remoteValidation` 能力直到 API 18/20 才出现，而本项目定位是 API 12 起可用，所以改用 `TLSSocket` 自行完成 TLS，详见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 构建步骤

完整说明（含 DevEco Studio 图形界面、签名、安装、常见错误）见 **[docs/BUILD.md](docs/BUILD.md)**。命令行的最小可用流程如下（PowerShell）：

```powershell
$env:DEVECO_SDK_HOME='D:\Programs\Huawei\DevEcoStudio\sdk'
$env:NODE_HOME='D:\Programs\Huawei\DevEcoStudio\tools\node'
$env:JAVA_HOME='E:\tools\jdk-17'
$env:PATH="E:\tools\jdk-17\bin;D:\Programs\Huawei\DevEcoStudio\tools\node;$env:PATH"
node 'D:\Programs\Huawei\DevEcoStudio\tools\hvigor\bin\hvigorw.js' --mode module -p product=default -p module=entry@default assembleHap --no-daemon
```

在仓库根目录执行，成功后的产物是：

```text
entry/build/default/outputs/default/entry-default-unsigned.hap
```

注意：

- 这是 **unsigned**（未签名）HAP，只能证明编译通过，不能直接安装。
- 不要用 `hvigorw assembleHap` 依赖 PATH 里恰好存在的 `hvigorw`；使用上面给出的 `node <hvigorw.js>` 绝对路径最稳。
- 工程没有第三方 ohpm 依赖，不需要联网执行 `ohpm install`（首次构建 hvigor 会自行准备工具链）。
- 仓库还提供 `scripts/build.ps1`（构建，已在本机验证）与 `scripts/install.ps1`（通过 `hdc install -r` 安装/卸载，需要已签名 HAP）两个封装脚本，详见 [docs/BUILD.md](docs/BUILD.md#35-仓库内辅助脚本)。

**交付前验证**（退出码 0 才算通过）：

```powershell
# 构建 + 静态校验（必需文件、配置、行尾、无签名材料、协议守卫、文档链接）
pwsh -File scripts/verify.ps1

# 只跑静态校验，跳过构建（秒级，改文档/配置时用）
pwsh -File scripts/verify.ps1 -SkipBuild
```

## 签名与真机安装

HarmonyOS 对安装包强制执行签名校验，**未签名 HAP 无法安装到任何真机**。

**方式 A：DevEco Studio 自动签名（推荐，需要登录华为账号）**

1. DevEco Studio → `File` → `Project Structure` → `Project` → `Signing Configs`；
2. 勾选 `Automatically generate signature`；
3. 按提示登录华为账号，IDE 会自动生成调试证书、Profile 并回填 `signingConfig`；
4. 点击 `Apply` / `OK`，再执行 `Build` → `Build Hap(s)`。

自动签名会改写 `build-profile.json5` 中的 `signingConfigs`，并生成本地签名材料。**签名材料（`*.p7b`、`*.p12`、`*.cer`、`*.pem`、`local.properties`）绝对不能提交到仓库**，本项目 `.gitignore` 已全部忽略。

**方式 B：命令行签名**

先在 DevEco Studio 中完成一次自动签名，让 IDE 生成 `signingConfigs`；之后命令行 `assembleHap` 会沿用同一份签名配置。产物同样是 `entry/build/default/outputs/default/` 下的 HAP（签名后文件名不再带 `-unsigned`）。

**安装到真机**

```powershell
# 确认设备已连接且已授权调试
hdc list targets

# 安装已签名的 HAP（把文件名替换为实际产物）
hdc install -r entry\build\default\outputs\default\entry-default-signed.hap
```

前置条件：手机开启「开发者模式」与「USB 调试」，并在弹窗中允许该电脑调试；`hdc` 来自 `D:\Programs\Huawei\DevEcoStudio\sdk\default\openharmony\toolchains\hdc.exe`（或 DevEco Studio 自带的 sdk toolchains 目录）。

安装后的冒烟检查：先打开 App，在空设备列表点击「运行协议自检」，**期望全部通过**；未通过时先不要进入配对流程（见 [docs/TESTING.md](docs/TESTING.md) 的 TC-02）。

## 配对使用流程

前置：电脑已安装 DeepSeek Harness，并在其中安装、启用 `dsh-mobile` 插件，且插件已启动网关。

1. **在电脑上生成配对链接。** 打开插件的手机访问入口/二维码页面，得到形如
   `https://<host>:3443/mobile-access/pair#key=dsh2.<64位十六进制>.<43位token>` 的链接（自签 CA 入口），
   或 `https://<host>:3443/mobile-access/pair#instance=<64位十六进制>&token=<43位token>`（局域网 / 公网证书 / 旧版插件）。
   上游**不会**生成 `#key=dsh1...` 片段；`dsh1.<...>` 是插件返回的 appKey 形式，可作为裸密钥使用。
2. **把链接复制到手机。** 当前版本没有原生扫码：用聊天工具/剪贴板把整条链接发到手机并复制。
3. **在 App 里粘贴并配对。**
   - 粘贴**完整链接**：App 直接从链接得到 origin 与配对 key；
   - 只粘贴**裸密钥**（`dsh2.*` 或 `dsh1.*`）：先点「扫描局域网」选中对应电脑，或在「手动填写」输入 `host:port`（未写端口时补默认 3443）；App 用该地址与裸密钥组成配对目标，并校验扫描结果的 `instanceId` 与密钥一致；
   - 对**公网证书远程入口**使用 `dsh1` 裸密钥 + 地址：`/mobile-access/ca.cer` 返回 404 时改用平台信任库；局域网/私网入口即使 404 也必须失败（自签入口必须提供并通过指纹校验）。

   App 随后会：
   - 严格解析 origin（只接受 `https`，拒绝 userinfo/query/端口越界等）与配对 key；
   - 通过未认证的 bootstrap 通道读取 `/mobile-access/discovery` 与 `/mobile-access/ca.cer`；
   - 校验 CA 的 SHA-256 等于 `instanceId`，再把该校验过的 CA 作为固定信任锚（仅公网证书远程入口无 CA 时走系统信任库）；
   - 调用 `native-pair` 换取设备凭据与会话。
4. **开始浏览。** 回到设备列表，点选刚配对的电脑，App 用 ArkWeb 打开该 origin 的 DSH 移动端页面，并把 `dsh_ma_session` / `dsh_ma_csrf`（以及 `__Host-` 变体）注入为 host-only Cookie。
5. **再次使用。** 设备记录保存在本地；重新打开 App 或切换网络后，App 用 `native-renew` / `native-probe` 恢复会话，不需要重新配对（除非设备被吊销或凭据过期）。

配对失败时 App 会给出分类原因（配对码过期、设备数已满、被限流、证书不匹配、网络不可达等），见下方排障表。

## 安全设计

| 设计 | 目的 |
| --- | --- |
| 只接受 HTTPS | `Origin.ets` 拒绝 `http`、opaque URI、userinfo、query、fragment（除固定的配对路径外）、越界端口；不做“自动修复” |
| 配对密钥不进入 HTTP 请求 | URL 片段不会被浏览器/客户端发送给服务器；裸密钥只在本机内存中使用，配对成功后 token 即丢弃 |
| `instanceId` = CA 证书指纹 | `instanceId` 是配对 CA 证书 DER 的 SHA-256（小写十六进制）。手机校验「下载到的 CA」与「链接里承诺的 CA」是同一张证书，局域网中无法被替换 |
| 初始连接不信任任何证书 | bootstrap 请求使用 `skipRemoteValidation` 拉起 TLS，但下载到的 CA 必须先通过「SHA-256 == instanceId + 自签名 + 有效期」校验才会被信任；校验失败立即中止，之后才发送任何凭据 |
| 固定 CA 作为唯一信任锚 | 后续请求把 CA PEM 传入 `TLSSocket` 的 `secureOptions.ca`（**替换**系统信任库而不是追加），避免系统里任意根证书签发的证书冒充网关 |
| Web 容器 SSL 续接 | ArkWeb 报告 SSL 错误时，用固定的 CA 校验服务端证书链（`chainMatchesPinnedCa` / `chainContainsPinnedCa`），通过才允许继续加载 |
| 凭据不进 preferences | `deviceToken` 只写 **Asset Store Kit**（`asset.add`，`DEVICE_UNLOCKED` 可访问性）；preferences 里只有展示用元数据与 CA PEM |
| 会话令牌不落盘 | `sessionToken` / `csrfToken` 只存在于内存并注入 Cookie，重启后重新 `native-renew` |
| 会话 Cookie 最小暴露 | host-only、`Path=/`、`Secure`、`SameSite=Strict`，会话名为 `HttpOnly`；不带 `Domain`，不会被其他主机读到 |
| 同源校验 | 页面内跳转与 WebSocket 只允许已固定 authority（`https`/`wss` 同 host:port），防止配对后被导流到第三方面板 |
| 严格响应校验 | 控制接口响应必须携带精确的键集合、未来时间戳（epoch 毫秒）、`deviceId` 为 32 位小写十六进制、`instanceId` 回显必须等于本地记录 |

威胁模型与取舍详见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 已知限制

1. **无真机验收**：本仓库的构建只在本机编译层面通过；配对、浏览、证书续接、网络切换均**未在真机验证**。
2. **无原生扫码**：必须复制/粘贴配对链接或裸密钥；**未申请相机权限**（`module.json5` 只声明 `INTERNET` / `GET_NETWORK_INFO`），扫码 UI 未实现。
3. **无推送**：没有 `mobile-push` 注册，后台任务完成/需要确认时不会收到系统通知。
4. **无 iroh**：上游 Android 的 iroh 点对点传输未移植；仅支持 HTTPS 直连入口（局域网、自签名 FRP、公网证书）。
5. **无 `window.dshMobileNative`**：页面运行在上游的浏览器模式，依赖原生能力的增强功能不可用。
6. **无原生文件选择器桥接**：网页内的文件上传走 ArkWeb 默认行为，未实现下载路径策略、分享与保存。
7. **未移植外围功能**：应用内更新、后台常驻服务、画中画、草稿传输、启动缓存等 Android 侧功能。
8. **只支持一对一网关的 HTTPS 浏览**：不代理 DSH 的其他端口，也不做本地反向代理。
9. **签名材料需要自备**：仓库不含任何证书、Profile 或密钥。
10. **删除本地记录不会主动清除 ArkWeb 会话 Cookie**：旧 Cookie 可能保留到会话过期（仍受 host-only / HTTPS / SameSite=Strict 约束，且只属于同一台电脑）；重新配对成功后会覆盖同名 Cookie。

## 排障

| 现象 | 可能原因 | 处理 |
| --- | --- | --- |
| 粘贴链接后提示格式错误 | 链接被截断、被聊天工具改写成 `http`、端口缺失或片段丢失 | 复制完整链接，确认是 `https://.../mobile-access/pair#...`；可由电脑重新生成配对码 |
| 提示证书/指纹不匹配 | 电脑换了配对 CA、链接来自另一台电脑、或中间人替换 | **不要**重试忽略；在电脑上重新生成配对链接后重新配对 |
| `dsh2` 链接提示缺少 CA（404） | 入口不是自签 CA 模式（公网证书入口才会 404），或端口指向了错误的网关 | 确认电脑上插件的入口类型；公网证书入口用 `dsh1` 裸密钥 + 地址配对，或直接粘贴插件生成的 `#instance=...&token=...` 链接 |
| `HTTP 401/403` | 配对码已过期/已被使用，或设备被吊销 | 在电脑上重新生成配对码；若设备列表里已无此设备，先删除本地记录再配对 |
| `HTTP 409` | 电脑端设备数量达到上限 | 在电脑端 dsh-mobile 设备管理里删除旧设备后重试 |
| `HTTP 429` | 触发配对/续期频率限制 | 等待一段时间再试；不要连续重试 |
| `source_network_untrusted` | 网关配置了受信任网段，当前网络不在其中 | 换到允许的 Wi-Fi/网络，或由电脑端调整受信任网段 |
| 局域网发现不到电脑 | 不在同一子网、电脑防火墙拦截 UDP 3443、路由器开启 AP 隔离 | 直接用配对链接；确认电脑与手机同一网段并允许入站 UDP/TCP 3443 |
| 网页白屏 / SSL 错误 | 固定 CA 与服务端证书链不匹配，或设备时间偏差过大 | 检查电脑时间与证书有效期；重新配对；查看 hilog 中 `DshMobile` 标签日志 |
| `hdc install` 失败 | HAP 未签名、签名与设备不匹配、设备未授予调试 | 用 DevEco 自动签名重新构建；`hdc list targets` 确认设备状态 |
| 构建报 `DEVECO_SDK_HOME` 未设置 | 未按命令行环境变量执行 | 按[构建步骤](#构建步骤)导出环境变量后重试 |

日志：`hilog` 中 domain `0x0D5B`、tag `DshMobile`。抓取方式：

```powershell
hdc shell hilog -T DshMobile
```

## 目录结构

```text
dsh-mobile-harmonyos/
├── AppScope/                       # 应用级配置（bundleName、版本、图标、应用名）
├── entry/
│   ├── build-profile.json5         # entry 模块构建配置（stage 模式、release 混淆关闭）
│   ├── hvigorfile.ts
│   ├── oh-package.json5
│   └── src/main/
│       ├── module.json5            # ability、页面入口、权限声明
│       ├── ets/
│       │   ├── entryability/       # UIAbility 生命周期入口
│       │   ├── common/             # Log、Json、Theme、SelfCheck
│       │   ├── protocol/           # 协议与 TLS 核心
│       │   │   ├── Origin.ets      # HTTPS origin / 配对 URL 解析，同源判定
│       │   │   ├── PairingKey.ets  # dsh1/dsh2/legacy 配对 key 解析
│       │   │   ├── CertPin.ets     # DER↔PEM、SHA-256、CA 与证书链校验
│       │   │   ├── TlsHttp.ets     # TLSSocket 上的最小 HTTPS/1.1 客户端
│       │   │   ├── GatewayHttp.ets # discovery/ca.cer/metadata/native-*
│       │   │   ├── Discovery.ets   # UDP + DNS-SD + HTTPS 子网扫描
│       │   │   └── AuthFailure.ets # 网关失败分类
│       │   ├── model/              # 已配对设备记录与持久化
│       │   ├── service/            # 应用服务层（配对/续期/设备列表协调）
│       │   └── pages/              # ArkUI 页面（列表、添加设备、ArkWeb 容器）
│       └── resources/              # 字符串、颜色、图标、页面路由表
├── hvigor/                         # hvigor 版本与构建缓存配置
├── build-profile.json5             # 产品级构建配置（SDK 版本、bundle 信息）
├── oh-package.json5                # 工程依赖（无第三方依赖）
├── scripts/                        # 构建、验证与安装的 PowerShell 封装
│   ├── build.ps1                   # 命令行构建 HAP
│   ├── install.ps1                 # 通过 hdc 安装/卸载已签名 HAP
│   └── verify.ps1                  # 构建 + 静态校验（交付门槛，退出码 0）
├── docs/                           # 构建、协议、架构、测试与 ADR 文档
├── AGENTS.md                       # 仓库对 AI agent 的规则说明
├── README.md
├── .gitattributes
└── .gitignore
```

`build/`、`.hvigor/`、`oh_modules/`、`node_modules/` 等均为构建产物/缓存，不进版本库。

## 协议与上游一致性

本客户端实现的是上游 `dsh-mobile` 已经文档化的**原生配对协议**：

- 配对链接：`https://<host>:<port>/mobile-access/pair#<fragment>`。上游只生成 `key=dsh2.<64hex>.<43char>`（自签 CA 入口）或旧版 `instance=<64hex>&token=<43char>`（局域网 / 公网证书）；`dsh1.<64hex>.<43char>` 是 appKey 形式，作为裸密钥配合主机地址使用；
- 网关身份：`instanceId = SHA-256(配对 CA 证书 DER)`，小写十六进制；
- 控制接口：`GET /mobile-access/discovery`、`GET /mobile-access/ca.cer`、`GET /mobile-access/metadata`、`POST /mobile-access/auth/native-pair|native-renew|native-probe`；
- 浏览鉴权：会话 Cookie `dsh_ma_session` / `dsh_ma_csrf` / `__Host-dsh_ma_session` / `__Host-dsh_ma_csrf`；
- 局域网发现：UDP 3443 上的 `DSH_MOBILE_DISCOVER_V1` 查询与 DNS-SD `_dsh-mobile._tcp`。

逐字段的请求/响应示例、校验规则与常量见 **[docs/PROTOCOL.md](docs/PROTOCOL.md)**。上游仓库是协议的事实来源：<https://github.com/saya-ch/dsh-mobile>。如果上游变更了字段、错误码或路径，以该仓库为准，本项目文档会跟随更新。

与上游 Android 客户端相比，本项目**有意未实现**的协议面：iroh 点对点传输、`mobile-push` 推送注册、原生桥 `window.dshMobileNative` 的各类消息。未实现的部分不会伪造：页面检测不到原生桥时按浏览器模式运行，这是上游支持的降级路径。

## 许可证

本项目以 **Apache License 2.0** 发布（见仓库根目录 [LICENSE](LICENSE) 与 `entry/oh-package.json5` 的 `license` 字段）。

- 这是**社区实现，非官方实现**，与 DeepSeek、DeepSeek Harness 官方以及华为均无隶属关系；
- `dsh-mobile` 插件、其协议、Android 客户端及相关商标归上游作者所有，以[上游仓库](https://github.com/saya-ch/dsh-mobile)的声明为准；
- 本项目仅通过公开协议对接上游网关，不包含上游代码；协议字段名与常量属于互操作所必需的接口事实。

## 文档

| 文档 | 内容 |
| --- | --- |
| [docs/BUILD.md](docs/BUILD.md) | 环境、DevEco Studio 图形构建、命令行构建、签名与安装、常见构建错误 |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | 原生配对协议实现者规范：URL、接口、字段、Cookie、发现、错误码、常量 |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 模块划分、线程与生命周期、证书固定设计、与 Android 组件对照 |
| [docs/TESTING.md](docs/TESTING.md) | 真机手工测试计划（**尚未执行**）、缺陷报告模板 |
| [docs/adr/](docs/adr/README.md) | 架构决策记录：TLSSocket 取舍、信任根、原生重写等已定型的决策 |
| [AGENTS.md](AGENTS.md) | 仓库对 AI agent 的规则：可执行命令、目录地图、硬规则、提交与交付定义 |
