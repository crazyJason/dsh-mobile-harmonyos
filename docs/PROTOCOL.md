# DSH Mobile 原生配对协议（实现者规范）

本文档描述 `dsh-mobile` 插件对外暴露的**原生手机客户端配对协议**，作为 `dsh-mobile-harmonyos` 的实现依据，也供其他平台的客户端实现者参考。

> **事实来源**：协议由上游仓库 [`saya-ch/dsh-mobile`](https://github.com/saya-ch/dsh-mobile) 定义，本文只是对它的整理与解释。若本文与上游代码/文档冲突，**以上游为准**，并在本仓库修正文档。
>
> 覆盖范围：配对链接、网关身份（CA 固定）、6 个控制接口、浏览会话 Cookie、局域网发现、错误分类、常量。不覆盖 DSH Web 前端自身的 API。

- [1. 角色与术语](#1-角色与术语)
- [2. 传输、Origin 与 TLS 信任](#2-传输origin-与-tls-信任)
- [3. 配对链接与配对密钥](#3-配对链接与配对密钥)
- [4. instanceId 与网关身份](#4-instanceid-与网关身份)
- [5. 控制接口](#5-控制接口)
- [6. 浏览会话 Cookie](#6-浏览会话-cookie)
- [7. 局域网发现](#7-局域网发现)
- [8. 错误分类](#8-错误分类)
- [9. 常量与正则速查](#9-常量与正则速查)
- [10. 版本兼容与上游对照](#10-版本兼容与上游对照)

---

## 1. 角色与术语

| 术语 | 含义 |
| --- | --- |
| Gateway（网关） | `dsh-mobile` 插件在电脑上启动的 HTTPS 服务，默认端口 **3443**，所有控制接口位于路径前缀 `/mobile-access` 下 |
| Entry（入口） | 网关的一种对外暴露方式：局域网直连、自签名 FRP、公网隧道（Cloudflare/Cpolar/Tailscale）、反向代理等 |
| Pairing link（配对链接） | 电脑端生成的一次性链接，格式 `https://<host>:<port>/mobile-access/pair#<fragment>`，片段里携带配对密钥 |
| Pairing key（配对密钥） | 由 `instanceId` 与一次性 token 组成，指明「要连哪台电脑」以及「用什么凭证换取授权」 |
| `instanceId` | 网关身份标识。对于提供配对 CA 的入口，它是该 CA 证书 DER 的 SHA-256（64 位小写十六进制） |
| Pairing CA | 网关自签的配对 CA 证书，通过 `/mobile-access/ca.cer` 下载；手机把它固定为 TLS 信任锚 |
| Device credential（设备凭据） | `native-pair` 成功后下发的长期凭据 `deviceToken`（43 字符），用于 `native-renew` / `native-probe` |
| Session（会话） | 短期浏览凭据，包含 `sessionToken` 与 `csrfToken`，用于让 Web 容器以已授权设备身份浏览 DSH 页面 |
| Label | 配对时提交的设备名称，供电脑端设备列表展示 |
| `installationId` | 可选的安装实例标识，仅在客户端声明能力并获网关确认后出现 |
| Origin | 规范化的 HTTPS 源，形如 `https://host[:port]`；本协议只接受 HTTPS |

文中的 `MUST` / `MUST NOT` / `SHOULD` 表示对客户端实现的强制/建议程度。

---

## 2. 传输、Origin 与 TLS 信任

### 2.1 基本约束

- 所有控制接口只支持 **HTTPS**，不支持明文 HTTP；手机客户端 MUST 拒绝任何 `http://` 输入。
- 默认端口 **3443**（自定义端口时以链接中的端口为准）。HTTPS 端口 443 在序列化时省略。
- 路径前缀固定为 `/mobile-access`。
- 控制接口的请求体与响应体均为 JSON（`application/json`），`ca.cer` 除外（DER）。
- 请求使用 HTTP/1.1；网关支持 `Connection: close` 语义（每次请求可独立建连）。
- 所有时间戳字段均为 **epoch 毫秒**（`Date.now()` 语义），不是秒。
- 十六进制字段一律**小写**。

### 2.2 Origin 规范化

客户端在保存、比较 origin 前 MUST 规范化：

| 规则 | 合法 | 非法（拒绝而不是修复） |
| --- | --- | --- |
| scheme | `https` | `http`、`ws`、`file`、opaque URI、协议相对 URL |
| userinfo | 无 | `https://user:pass@host/` |
| query / fragment | 裸 origin 中无 | `https://host:3443/?a=1`、`https://host:3443/#x` |
| path | 空或 `/` | `/mobile-access/...`（裸 origin 只允许根路径） |
| 端口 | 缺省 → 443；1–65535 | `0`、`65536`、非数字、空 `:` |
| host | 小写 ASCII | 非 ASCII、空、含 `%`（IPv6 zone id）、超过 253 字符、首尾点 |
| IPv4 字面量 | `a.b.c.d`，每段 0–255 | 越界、前导非数字、`1.2.3` |
| IPv6 字面量 | `[...]`，至少 2 个冒号，仅 `0-9a-f`、`:`、`.` | 缺少方括号、zone id、非法字符 |
| 主机名 | 每个 label 1–63 字符，以字母数字开头结尾，中间可含 `-` | 空 label、连续点、首尾 `-`、下划线 |

规范化后的序列化形式：

```text
https://<host>            # 端口为 443 时省略
https://<host>:<port>     # 其他端口
https://[<ipv6>]:<port>   # IPv6 字面量加方括号
```

示例：

```text
输入: HTTPS://192.168.1.5:3443/    → 规范: https://192.168.1.5:3443   → 端口 3443
输入: https://example.com          → 规范: https://example.com        → 端口 443
输入: https://[fe80::1]:3443/      → 规范: https://[fe80::1]:3443     → 端口 3443
输入: https://example.com:3443/path → 拒绝（裸 origin 不允许非根路径）
输入: http://example.com           → 拒绝（只允许 https）
```

### 2.3 配对 URL 的例外

配对 URL 是唯一允许带路径与片段的形态：

```text
https://<host>:<port>/mobile-access/pair#<fragment>
```

- 路径 MUST 恰好是 `/mobile-access/pair`；
- MUST 没有 query、没有 userinfo；
- fragment 可选，但一旦存在 MUST 匹配 [3.2](#32-三种配对密钥格式) 的格式；
- 手机客户端 MUST NOT 把 fragment 发送给服务器（浏览器不会发送，原生客户端也必须遵守）。

### 2.4 同源与固定 authority

- **同源（same-origin）**：协议为 `https`，host 与 port 与已配对 origin 完全一致（默认 port 归一化为 443）。
- **固定 authority（pinned authority）**：协议为 `https` 或 `wss`，host 与 port 与已配对 origin 一致。WebSocket 的证书错误在 WebView/ArkWeb 中通常以 `wss:` URL 上报，因此证书续接判断必须允许 `https`/`wss` 两种 scheme，但 host/port 仍必须精确匹配。
- 页面内导航、下载、WebSocket 都应限制在固定 authority 内；其他 HTTPS 链接可交给系统浏览器，其他 scheme 一律不自动打开。

### 2.5 TLS 信任模式

客户端对网关的 TLS 信任分三种模式：

| 模式 | 使用的信任锚 | 适用场景 |
| --- | --- | --- |
| `BOOTSTRAP` | **不校验**服务端证书（`skipRemoteValidation`），但响应必须通过指纹校验后才可信任 | 首次读取 `/mobile-access/discovery`、`/mobile-access/ca.cer` |
| `PINNED` | 只信任配对 CA（替换系统信任库，而不是追加） | 已校验 CA 后的所有控制接口、Web 容器 |
| `SYSTEM` | 平台信任库（公共 CA） | 仅公网证书**远程**入口（密钥不要求 CA）且 `ca.cer` 明确返回 404 时 |

关键规则：

1. **bootstrap 不是“先信任”**：读取 CA 后 MUST 校验 `SHA-256(DER) == instanceId`、CA 基本约束、自签名与有效期，任一失败立即中止，不能继续发凭据。
2. **固定 CA 是替换而非追加**：把 CA PEM 传给 TLS 层的自定义信任锚时，不能把它“加入”系统信任库，否则系统里任意 CA 都能冒充网关。
3. **dsh2 禁止降级**：`dsh2` 入口 MUST 提供 CA；`ca.cer` 404 或指纹不匹配是硬失败（identity mismatch），不得回退到系统信任库。
4. **远程已固定 CA 不得被不要求 CA 的密钥降级**：同一台电脑之前以远程模式固定过 CA，再次配对时即使拿到不要求 CA 的密钥（`dsh1` 裸密钥 / legacy 片段）也仍 MUST 要求 CA（`preserveRemotePin` 规则）。

---

## 3. 配对链接与配对密钥

### 3.1 链接结构

```text
https://<host>:<port>/mobile-access/pair#<fragment>
                          └──────────────┘ └────────┘
                           固定路径           片段：只在手机本地解析
```

片段从不进入 HTTP 请求，因此不会出现在网关访问日志或代理日志中。电脑端把这个完整链接编码成二维码，或直接展示给用户复制。

### 3.2 三种配对密钥格式

`dsh1` / `dsh2` 是**密钥格式**（也是插件 `pairing/open` 返回的 `appKey` 形式）；是否把它们放进 URL 片段由上游的入口类型决定：`dsh2` 会出现在 `#key=...` 片段中，`dsh1` 不会出现在 URL 里。第三种是旧版 legacy 片段。

| 格式 | 示例 | 上游是否写入 URL 片段 | 含义 | CA 要求 |
| --- | --- | --- | --- | --- |
| `dsh2` | `key=dsh2.<64hex>.<43char>` | **是**（自签 CA 入口） | 入口提供自签 CA（典型：自签名 FRP、非 discovery 的自建入口） | **必须**提供 CA |
| `dsh1` | `dsh1.<64hex>.<43char>` | **否**（作为 appKey 返回，可作裸密钥使用） | 入口使用**公共 CA 签发**的证书 | 可以没有 CA（404 合法） |
| legacy | `instance=<64hex>&token=<43char>` | **是**（局域网 / 公网证书 / 旧版） | 不编码 CA 需求 | LAN 模式仍必须校验网关 CA |

正则（完整匹配，`^...$`）：

```text
配对密钥:      ^dsh([12])\.([a-f0-9]{64})\.([A-Za-z0-9_-]{43})$
dsh2 片段:     ^key=dsh2\.[a-f0-9]{64}\.[A-Za-z0-9_-]{43}$
旧版片段:      ^instance=([a-f0-9]{64})&token=([A-Za-z0-9_-]{43})$
通用片段:      ^(?:instance=[a-f0-9]{64}&token=[A-Za-z0-9_-]{43}|key=dsh2\.[a-f0-9]{64}\.[A-Za-z0-9_-]{43})$
```

字段约束：

| 字段 | 约束 |
| --- | --- |
| `instanceId` | 64 个**小写**十六进制字符（`[a-f0-9]{64}`），即 32 字节 SHA-256 |
| `token` | 43 个字符，字符集 `[A-Za-z0-9_-]`（base64url 无填充的 32 字节随机数），大小写敏感 |
| 前缀数字 | `1` = 公网证书入口；`2` = 提供自签 CA 的入口 |

> 注意：
>
> - `dsh1` / `dsh2` 中的数字是**入口的信任模型**，不是协议版本；两种格式的字段长度完全一致。
> - `#key=dsh1...` **不是合法的配对链接片段**：上游只为需要自签 CA 的入口生成 `#key=dsh2...`，其余入口生成 legacy 片段。Android 客户端同样只接受 `#key=dsh2...`（`PairingKey.parse(...)?.takeIf { it.requiresCa }`），拒绝 `#key=dsh1...` 是与上游一致的行为，不是客户端缺陷。
> - `dsh1` 裸密钥需要配合主机地址使用（见 [3.4](#34-解析规则)）。

### 3.3 CA 要求矩阵

| 场景 | 密钥来源 | 是否下载 `/ca.cer` | `ca.cer` 返回 404 时 |
| --- | --- | --- | --- |
| 局域网直连 | legacy 片段（常见） | 是（LAN 网关总是提供配对 CA） | 失败：身份无法验证 |
| 自签名 FRP / 自建入口 | `#key=dsh2...` 片段 | 是 | 失败（硬失败，禁止回退系统信任） |
| 公网证书入口（Cloudflare/Cpolar/Tailscale/自有域名） | legacy 片段，或 `dsh1` 裸密钥 + 地址 | 可以先尝试；404 表示无自签 CA | 允许，使用平台信任库 |
| 同一台远程电脑再次配对（曾固定 CA） | 任意不要求 CA 的密钥 | 是，保持 CA 强制 | 失败（防止降级攻击） |

上表的实现要点：

- **LAN 模式**：配对时必须先下载并校验 CA，再用该 CA 发起 `native-pair`；不能因为链接是 legacy 格式就跳过 CA。
- **远程模式**：先尝试 `/ca.cer`。有 CA → 校验并固定；明确 404 → 仅当 `target.remote === true` 且密钥不要求 CA（公网证书入口）时使用系统信任库；其他错误（网络、TLS、5xx）应当**向上抛出**，不能当作 404 处理。私网入口即使密钥不要求 CA，404 也必须失败。
- **降级保护**：若本地已有同一 `instanceId` 且保存了 CA 的远程记录，新的配对必须把 `requiresCa` 置为 true（即使新密钥不要求 CA）。

> 实现注记：本仓库的 HarmonyOS 客户端与上游 `PairingTrust.selectTrustAnchor` 保持一致——私网（LAN）入口必须提供并校验 `ca.cer`，缺失即按身份不匹配失败；只有公网证书远程入口（密钥不要求 CA 且 `ca.cer` 明确 404）才允许使用平台信任库。判定入口类型的规则见 [ARCHITECTURE.md](ARCHITECTURE.md#15-已知缺口与后续工作)。

### 3.4 解析规则

客户端解析输入时：

1. 先 `trim()` 首尾空白；
2. 先尝试按**裸 origin** 解析；成功则得到一个可浏览的 origin（不含配对 key）；
3. 否则按**配对 URL** 解析：scheme 必须 `https`、无 userinfo/query、路径恰好 `/mobile-access/pair`、fragment 可选且匹配 3.2 的正则；
4. 从 fragment 提取配对密钥：
   - 以 `key=` 开头：MUST 是 `dsh2`。`#key=dsh1...` 不是上游会生成的格式，按上游规则拒绝（Android 的 `GatewayUrlPolicy.pairingKey` 同样要求 `requiresCa`）；
   - 否则 MUST 是完整的 `instance=...&token=...`；
5. 如果输入是**裸密钥**（`dsh1.*` 或 `dsh2.*`，没有 origin）：由用户通过局域网扫描选择电脑或手填地址，配对目标 = 该地址的 origin + 裸密钥（直接构造配对目标，不重新拼 `#key=...` URL）；
6. 校验通过后，持久化的只有**规范化 origin**；token 只在内存中使用，配对成功后丢弃。

实现差异（客户端行为，不是协议要求）：

- 上游 Android 客户端的配对入口来自二维码扫描，因此只接受完整 URL（扫码得到的就是完整配对链接）；
- 本仓库的 HarmonyOS 客户端没有扫码，支持两种输入：
  - **完整链接**（`#key=dsh2...` 或 `#instance=...&token=...`）；
  - **裸密钥** + 地址（局域网扫描或手填 `host:port`，缺省补 3443）；
- **公网证书入口**使用裸 `dsh1` 密钥 + 地址配对（或直接粘贴该入口的 legacy 完整链接）；`#key=dsh1...` 被拒绝是上游一致行为，不是缺陷；
- 使用发现结果提供地址时，客户端会校验发现的 `instanceId` 与裸密钥一致，避免把 token 发给另一台电脑。

### 3.5 示例

合法的完整链接：

```text
https://192.168.1.23:3443/mobile-access/pair#instance=4f3c9a...（64位小写hex）...&token=Qm9...（43位）...
https://dsh.example.com/mobile-access/pair#key=dsh2.4f3c9a...（64位小写hex）....Qm9...（43位）...
https://dsh.example.com:3443/mobile-access/pair#key=dsh2.<64hex>.<43char>
```

合法的裸密钥（需配合地址）：

```text
dsh2.<64hex>.<43char>       # 自签 CA 入口
dsh1.<64hex>.<43char>       # 公网证书入口：ca.cer 404 → 平台信任库
```

非法输入（应拒绝）：

| 输入 | 原因 |
| --- | --- |
| `http://192.168.1.23:3443/mobile-access/pair#...` | 非 HTTPS |
| `https://192.168.1.23:3443/mobile-access/pair` | 没有 fragment / 没有 key（无法配对，只可浏览） |
| `https://192.168.1.23:3443/mobile-access/pair#key=dsh2.<63hex>.<43char>` | instanceId 长度错误 |
| `https://192.168.1.23:3443/mobile-access/pair#key=dsh2.<64HEX>.<43char>` | 大写十六进制 |
| `https://192.168.1.23:3443/mobile-access/pair#key=dsh1.<64hex>.<43char>` | 上游不生成 `#key=dsh1...`；按上游规则拒绝 |
| `https://user@192.168.1.23:3443/mobile-access/pair#...` | 不允许 userinfo |
| `https://192.168.1.23:3443/other/path#...` | 路径必须是 `/mobile-access/pair` |

---

## 4. instanceId 与网关身份

### 4.1 定义

对于**提供配对 CA 的入口**：

```text
instanceId = SHA-256(配对 CA 证书的 DER 编码)  → 64 位小写十六进制
```

也就是说，`instanceId` 不是随机 ID，而是**证书指纹**。这带来一个关键性质：手机从网关下载 `ca.cer` 后，只要算出它的 SHA-256 并与链接中的 `instanceId` 比较，就能确认「下载到的 CA」就是「生成链接的那台电脑的 CA」。

> 上游对**公网证书入口**（无配对 CA）使用网关自身的安装身份作为 `instanceId`。此时没有 CA 可供指纹绑定，身份由公共 CA + 配对响应回显共同确认；客户端仍 MUST 校验响应中的 `instanceId` 与链接一致。

### 4.2 CA 校验步骤

下载到 `/mobile-access/ca.cer` 的 DER 后，客户端 MUST 依次校验：

1. 长度在合理范围内（建议 ≤ 16 KiB），能被解析为 X.509 证书；
2. `SHA-256(DER)` 等于配对链接中的 `instanceId`；
3. 是 CA 证书：BasicConstraints 的 `cA` 为 true（basic constraints >= 0）；
4. 自签名：subject == issuer，且能用自身公钥验签成功；
5. 当前时间在证书有效期内。

任一步失败 → 视为**网关身份不匹配**，MUST 中止配对，不得继续发送 token。

### 4.3 响应回显校验

`native-pair` / `native-renew` / `native-probe` 的响应都带 `instanceId`。客户端 MUST：

- 校验响应中的 `instanceId` 格式合法（64 位小写十六进制）；
- 校验它**等于**这次请求预期的 `instanceId`（来自配对链接或本地已保存记录）；
- 不相等 → 视为异常响应，不得保存/使用其中的凭据。

这可以防止一个能完成 TLS 但被错误路由的网关把「别人的 session」塞给客户端。

### 4.4 发现结果不可信

`/mobile-access/discovery`、UDP 广播、DNS-SD 里的 `instanceId` 与 `deviceName` 都只是**提示**（hint）：

- 用于在列表里展示、去重（按 `instanceId`）；
- 不能作为身份依据；
- 真正的身份校验发生在配对时（CA 指纹 + 响应回显）。

---

## 5. 控制接口

所有接口路径以 `/mobile-access` 为前缀。JSON 响应带 `Content-Type: application/json`（可能带 charset）。错误响应体统一为：

```json
{ "error": "<error_code>" }
```

`<error_code>` 为长度受限的小写 snake_case 字符串（客户端应做长度/字符集校验后再展示或映射）。

### 5.1 `GET /mobile-access/discovery`

**用途**：在配对前探测网关，展示设备名，并确认对方确实是 DSH Mobile 网关。无需认证。

请求：

```http
GET /mobile-access/discovery HTTP/1.1
Host: 192.168.1.23:3443
Connection: close
```

响应 `200`（**恰好 5 个键**）：

```json
{
  "deviceName": "MacBook-Pro",
  "origin": "https://192.168.1.23:3443",
  "port": 3443,
  "protocol": 1,
  "instanceId": "4f3c9a…（64 位小写十六进制）"
}
```

字段约束：

| 字段 | 类型 | 约束 |
| --- | --- | --- |
| `deviceName` | string | 非空、去空白后非空、长度 ≤ 63；来自电脑主机名，控制字符已被上游剔除 |
| `origin` | string | 规范化 HTTPS origin，必须等于请求者实际访问的 origin |
| `port` | number | 整数，等于监听端口，且等于 `origin` 的端口 |
| `protocol` | number | 必须为 `1` |
| `instanceId` | string | `^[a-f0-9]{64}$` |

客户端校验：

- 响应键集合必须**恰好**为上述 5 个（多键/少键都视为不合规）；
- `port` 必须等于实际访问端口，`origin` 必须等于实际访问的 origin（防止公告里塞入第三台主机）；
- `protocol` 不匹配 → 不兼容，放弃；
- 任何解析失败 → 该候选不是有效网关。

> 该接口的内容在配对前不可信，不要仅凭它做信任决策。

### 5.2 `GET /mobile-access/ca.cer`

**用途**：下载配对 CA（DER）。无需认证。

请求：

```http
GET /mobile-access/ca.cer HTTP/1.1
Host: 192.168.1.23:3443
Connection: close
```

响应（提供 CA 的入口）：

```http
HTTP/1.1 200 OK
Content-Type: application/pkix-cert
Content-Length: 812
Cache-Control: no-store
```

响应体是**裸 DER**（不是 PEM）。客户端按 [4.2](#42-ca-校验步骤) 校验。

响应（不提供 CA 的公网证书入口）：

```http
HTTP/1.1 404 Not Found
Content-Type: application/json
```

```json
{ "error": "not_found" }
```

规则：

- `200`：必须校验指纹后才可使用；
- `404`：仅当密钥**不要求 CA**（`dsh1` 裸密钥 / 公网证书入口的 legacy 密钥）时允许改用平台信任库；否则是身份不匹配；
- 其他状态：按错误分类处理，不能当 404；
- 响应体过大（建议上限 16 KiB）→ 视为异常。

### 5.3 `GET /mobile-access/metadata`

**用途**：可选兼容性信息。旧网关可能没有该接口（404）。

请求：

```http
GET /mobile-access/metadata HTTP/1.1
Host: 192.168.1.23:3443
Connection: close
```

响应 `200`：

```json
{
  "version": 1,
  "pluginVersion": "0.9.0",
  "minimumAndroidAppVersion": "0.8.0",
  "discoveryProtocol": 1
}
```

字段约束：

| 字段 | 类型 | 约束 |
| --- | --- | --- |
| `version` | number | 整数 ≥ 1（元数据版本） |
| `pluginVersion` | string | 非空、≤ 64 字符（插件版本） |
| `minimumAndroidAppVersion` | string | 非空、≤ 64 字符。字段名沿用 Android 客户端的叫法；其他平台客户端应把它理解为「最低客户端版本」 |
| `discoveryProtocol` | number | 整数 ≥ 1，当前为 1 |

客户端行为：

- `404` → 旧网关，继续配对流程；
- `200` → 可用于提示「插件版本/客户端版本不匹配」；
- 该接口不是配对的必需步骤。

### 5.4 `POST /mobile-access/auth/native-pair`

**用途**：用一次性 token 换取设备凭据与浏览会话。无需认证。

请求头：

```http
POST /mobile-access/auth/native-pair HTTP/1.1
Host: 192.168.1.23:3443
Content-Type: application/json
Accept: application/json
X-DSH-Mobile-Capabilities: installation-id
Origin: https://192.168.1.23:3443
Sec-Fetch-Site: same-origin
Connection: close
```

请求体（token 必填；label 可选）：

```json
{ "token": "Qm9…（43 位 [A-Za-z0-9_-]）", "label": "DeepSeek Harness HarmonyOS" }
```

- `token`：来自配对密钥，MUST 校验格式；
- `label`：设备显示名，建议带平台名（例如 `DeepSeek Harness Android` / `DeepSeek Harness HarmonyOS`）；
- 上游对 body 的检查是「`token` 必须是 string；`label` 若存在必须是 string」，客户端只应发送这两个键。

TLS 信任：

- `dsh2` / LAN：使用已校验的固定 CA；
- 不要求 CA 的密钥（`dsh1` 裸密钥，或公网证书入口的 legacy 密钥）且 `ca.cer` 返回 404：使用平台信任库。

响应 `201 Created`（7 个必需键，`installationId` 可选）：

```json
{
  "instanceId": "4f3c9a…（64 位小写十六进制）",
  "deviceId": "9b2e…（32 位小写十六进制）",
  "deviceToken": "Zk1…（43 位）",
  "deviceExpiresAt": 1798761600000,
  "sessionToken": "aQ7…（43 位）",
  "csrfToken": "mB3…（43 位）",
  "sessionExpiresAt": 1798675200000
}
```

若请求带了 `X-DSH-Mobile-Capabilities: installation-id` 且网关配置了安装身份，则多一个键：

```json
{ "installationId": "…（64 位小写十六进制）" }
```

**验证规则（客户端）**：

| 校验 | 规则 |
| --- | --- |
| 键集合 | 必需 7 键齐全；允许恰好一个可选 `installationId`；出现其他键视为不合规 |
| `instanceId` | 64 位小写十六进制，且必须等于预期值 |
| `deviceId` | 32 位小写十六进制 |
| `deviceToken` / `sessionToken` / `csrfToken` | 均匹配 `^[A-Za-z0-9_-]{43}$` |
| `deviceExpiresAt` | 整数、有限、**> 当前时间**（毫秒） |
| `sessionExpiresAt` | 整数、有限、**> 当前时间**（毫秒） |
| 相对关系 | 建议要求 `deviceExpiresAt >= sessionExpiresAt`（设备凭据不应比会话先过期） |
| `installationId`（若存在） | 64 位小写十六进制 |

失败响应：

| 状态 | 含义 |
| --- | --- |
| `400` | 请求体不合法（缺少 token、类型错误等） |
| `401` / `403` | 配对 token 失效/已被使用，或设备/来源网络不被允许 |
| `409` | 设备数量达到上限 |
| `429` | 触发频率限制（同一设备并发/时间窗内重复请求） |
| `5xx` | 网关内部错误 |

### 5.5 `POST /mobile-access/auth/native-renew`

**用途**：用设备凭据换取新的浏览会话（`deviceToken` 不变）。无需认证头。

请求头同 5.4。请求体：

```json
{ "deviceToken": "Zk1…（43 位）" }
```

响应 `200`（5 个必需键 + 可选 `installationId`）：

```json
{
  "instanceId": "4f3c9a…（64 位小写十六进制）",
  "deviceId": "9b2e…（32 位小写十六进制）",
  "sessionToken": "aQ7…（43 位）",
  "csrfToken": "mB3…（43 位）",
  "sessionExpiresAt": 1798675200000
}
```

规则：

- 不返回新的 `deviceToken`；设备凭据保持不变；
- 客户端 MUST 校验 `instanceId` 回显与本地记录一致；
- 会话过期或收到 `401` 时应重新 `native-renew`（或提示重新配对）；不要无限重试；
- 频繁续期会触发 `429`，客户端应做退避与去重（本仓库客户端对续期/探活做串行化）。

### 5.6 `POST /mobile-access/auth/native-probe`

**用途**：只验证设备凭据是否仍有效以及网关可达，不创建浏览会话。

请求体：

```json
{ "deviceToken": "Zk1…（43 位）" }
```

响应 `200`（3 个必需键 + 可选 `installationId`）：

```json
{
  "instanceId": "4f3c9a…（64 位小写十六进制）",
  "deviceId": "9b2e…（32 位小写十六进制）",
  "deviceExpiresAt": 1798761600000
}
```

规则：

- 用来刷新设备列表的「可达/已吊销/已过期」状态；
- 收到 `device_revoked` / `401` 时，客户端应把该设备标记为已撤销并提示重新配对；
- 与 `native-renew` 一样需要限流与去重。

### 5.7 其他端点（非配对必需）

| 端点 | 说明 |
| --- | --- |
| `GET /mobile-access/health` | 返回 `{"ok":true}`，可用于最基础连通性检查 |
| `POST /mobile-access/auth/pair` / `POST /mobile-access/auth/renew` | 浏览器配对/续期入口，使用 Cookie 而不是原生凭据，原生客户端不使用 |
| `/mobile-access/pair` 页面 | 手机浏览器访问的配对页面；原生客户端不加载它 |

---

## 6. 浏览会话 Cookie

### 6.1 为什么需要客户端注入

`native-pair` / `native-renew` 只返回 JSON，**不会设置 `Set-Cookie`**。浏览器完成配对时 Cookie 由配对页面写入；原生客户端必须自己把会话装进 Web 容器，否则 ArkWeb/WebView 打开 DSH 页面时会以未授权身份被拒。

### 6.2 Cookie 列表与属性

| Cookie | 值 | 属性 |
| --- | --- | --- |
| `dsh_ma_session` | `sessionToken` | `Path=/`；`Secure`；`HttpOnly`；`SameSite=Strict` |
| `dsh_ma_csrf` | `csrfToken` | `Path=/`；`Secure`；`SameSite=Strict`（**不带 HttpOnly**，页面脚本需要读取） |
| `__Host-dsh_ma_session` | `sessionToken` | 同上（含 `HttpOnly`） |
| `__Host-dsh_ma_csrf` | `csrfToken` | 同上（不带 `HttpOnly`） |

共同规则：

- **host-only**：不带 `Domain`，只对已配对的那个主机生效；端口不参与 Cookie 作用域；
- 只在 HTTPS 下出现（`Secure`）；
- `__Host-` 前缀要求：`Secure`、`Path=/`、**无 `Domain`**；
- `SameSite=Strict`：跨站请求不携带，符合网关的 CSRF 防护模型；
- 浏览器侧还存在 `dsh_ma_device`（设备凭据的浏览器版本）与 `__Host-dsh_ma_device_id`（非密钥的设备标识），原生客户端**不需要**注入它们。

### 6.3 安装方式

Web 容器按**精确的配对 origin** 写入 Cookie，例如：

```text
URL:  https://192.168.1.23:3443
Cookie: dsh_ma_session=<sessionToken>; Path=/; Secure; HttpOnly; SameSite=Strict
```

- Android：`CookieManager.setCookie(originUrl, cookie)`；
- HarmonyOS：`WebCookieManager.configCookieSync(originUrl, cookie, incognito, includeHttpOnly)`。`HttpOnly` 项需要 `includeHttpOnly` 能力；API 14 之前的实现可能无法覆盖已有 HttpOnly Cookie，此时的降级策略（本仓库客户端）是先尝试带 HttpOnly，失败后去掉 `HttpOnly` 再写一次，并记录告警。

### 6.4 生命周期

- 会话在 `sessionExpiresAt` 到期；到期前应重新 `native-renew` 并重装 Cookie；
- 页面加载前应确保持有有效会话（先 renew 再挂载 Web 容器）；
- 设备凭据在 `deviceExpiresAt` 到期后必须重新配对（`native-renew` 会失败）；
- 退出/删除设备时应清理这 4 个 Cookie（至少 `Path=/` 同名覆盖过期）。

---

## 7. 局域网发现

局域网发现是**可选**增强：没有发现结果时，用户仍可粘贴配对链接。三条发现路径可以并行，结果按 `instanceId` 去重。

### 7.1 UDP 广播

| 项目 | 值 |
| --- | --- |
| 协议 | UDP（IPv4 广播） |
| 端口 | **3443**（与 HTTPS 端口相同） |
| 查询报文 | ASCII 字符串 `DSH_MOBILE_DISCOVER_V1`（22 字节，无换行） |
| 查询方式 | 向 `255.255.255.255` 以及各子网的定向广播地址发送 |
| 应答 | 网关向查询来源回送一个 5 键 JSON 公告（与 5.1 的响应体相同） |
| 主动广播 | 网关每 **3 秒**向广播地址发送同样的 JSON 公告 |
| 编码 | UTF-8 JSON |

公告示例（UDP 载荷，无 HTTP 头）：

```json
{"deviceName":"MacBook-Pro","origin":"https://192.168.1.23:3443","port":3443,"protocol":1,"instanceId":"4f3c9a…（64位小写hex）"}
```

客户端校验（用于过滤伪造/错位公告）：

1. JSON 恰好 5 个键；
2. `protocol == 1`；
3. `instanceId` 匹配 `^[a-f0-9]{64}$`；
4. `deviceName` 非空、长度 ≤ 63；
5. `origin` 能解析为合法 HTTPS origin；
6. `port` == `origin.port`；
7. **`origin.host` == UDP 发送方地址**：公告必须描述发送者自己，不能指向第三台机器；
8. 用 `instanceId` 去重。

客户端实现可选择绑定 UDP 3443 以同时收到主动广播；绑定失败不影响“只发查询”的路径。

### 7.2 DNS-SD（mDNS）

| 项目 | 值 |
| --- | --- |
| 服务类型 | `_dsh-mobile._tcp` |
| 服务实例名 | `<deviceName> (<instanceId 前 8 位>)`（上游生成方式，仅展示用途） |
| SRV 端口 | 网关 HTTPS 端口（默认 3443） |
| 主机名 | `<清洗后的主机名>-<instanceId 前 8 位>.local` |
| TXT | `deviceName`、`origin`、`instanceId`、`protocol` |

TXT 值均为 UTF-8 文本。`protocol` 为字符串 `"1"`。

客户端校验：

- `protocol` 必须解析为 1；
- `instanceId` 必须匹配 64 位小写十六进制；
- `deviceName` 非空且 ≤ 63；
- `origin` 合法，且 SRV 端口（若可见）与 `origin.port` 一致；
- 多个发现结果按 `instanceId` 合并（DNS-SD 与 UDP 可能同时报告同一台电脑）。

### 7.3 HTTPS 子网扫描（兜底）

当 UDP 与 DNS-SD 都没有结果时，可对本地私有 IPv4 /24 子网逐个主机尝试：

```text
GET https://<subnet>.<host>:3443/mobile-access/discovery
```

- 只扫描本机所在的私有网段（每张网卡一个 /24，最多数个）；
- 跳过自己的地址；
- 有界并发（例如 24–32 路），单个探测超时要短；
- 只有返回 5 键合法 `discovery` 文档的主机才算候选；
- 扫描是**兜底**，不应在被动发现已有结果时执行。

### 7.4 发现结果的使用

- 列表中展示 `deviceName` 与 origin；
- 选择某台电脑后，仍必须用配对链接里的 token 完成 `native-pair`，发现本身不产生授权；
- 发现的 `instanceId` 可用于与已配对记录匹配（例如提示“地址已变化”）。

---

## 8. 错误分类

客户端应把网关失败映射为可解释的类别，而不是统一报“网络错误”。

| HTTP | 响应体 `error` | 类别 | 含义 | 客户端动作 |
| --- | --- | --- | --- | --- |
| `401` / `403` | 任意 | 配对失效 / 已撤销 | 配对 token 过期或设备凭据失效 | 提示重新生成配对链接 / 重新配对 |
| `401` / `403` | `device_revoked` | 设备已撤销 | 电脑端撤销了该设备 | 标记记录为已撤销，删除并重新配对 |
| `401` / `403` | `device_expired` | 设备已过期 | 设备凭据超过有效期 | 重新配对 |
| `403` | `source_network_untrusted` | 来源网络不被信任 | 请求来源不在网关允许网段 | 更换网络或由电脑端调整受信网段 |
| `409` | 任意 | 设备数已满 | 达到网关的配对设备上限 | 在电脑端删除旧设备 |
| `429` | `rate_limited` | 被限流 | 频率/并发超过限制 | 退避后重试，避免并发重试 |
| `5xx` | 任意 | 网关不可用 | 插件内部错误/重启中 | 提示检查电脑端移动访问面板，稍后重试 |
| 其他 | 任意 | 响应不合规 | 字段缺失、键集合错误、时间戳非法等 | 视为协议不兼容，提示升级插件/客户端 |

网络层失败还应区分：

| 类别 | 判定 |
| --- | --- |
| `TIMEOUT` | 连接/读取超时 |
| `TLS` | TLS 握手失败、证书链不被固定 CA 接受 |
| `NETWORK` | DNS 失败、连接被拒、网络不可用 |
| `INVALID_RESPONSE` | 状态码 2xx 但响应体/字段不符合协议 |

**安全提示**：错误响应体可能包含不可信字符串；客户端应限制长度（例如 8 KiB）、校验字符集，不要直接把服务器文本拼进 UI 或日志。

---

## 9. 常量与正则速查

### 9.1 网络与路径

| 常量 | 值 |
| --- | --- |
| 默认 HTTPS 端口 | `3443` |
| HTTPS 缺省端口 | `443` |
| 路径前缀 | `/mobile-access` |
| 配对页面 | `/mobile-access/pair` |
| 发现 | `/mobile-access/discovery` |
| CA | `/mobile-access/ca.cer` |
| 元数据 | `/mobile-access/metadata` |
| 原生配对 | `/mobile-access/auth/native-pair` |
| 原生续期 | `/mobile-access/auth/native-renew` |
| 原生探活 | `/mobile-access/auth/native-probe` |
| 健康检查 | `/mobile-access/health` |

### 9.2 正则

```text
INSTANCE_ID            ^[a-f0-9]{64}$
DEVICE_ID              ^[a-f0-9]{32}$
OPAQUE_TOKEN           ^[A-Za-z0-9_-]{43}$
PAIRING_KEY            ^dsh([12])\.([a-f0-9]{64})\.([A-Za-z0-9_-]{43})$
LEGACY_PAIR_FRAGMENT   ^instance=([a-f0-9]{64})&token=([A-Za-z0-9_-]{43})$
PAIR_FRAGMENT          ^(?:instance=[a-f0-9]{64}&token=[A-Za-z0-9_-]{43}|key=dsh2\.[a-f0-9]{64}\.[A-Za-z0-9_-]{43})$
HOSTNAME_LABEL         ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$
IPV4_OCTETS            ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$   # 另需逐段 0–255
```

### 9.3 请求头

| 头 | 值 |
| --- | --- |
| `Content-Type` | `application/json` |
| `Accept` | `application/json` |
| `X-DSH-Mobile-Capabilities` | `installation-id` |
| `Origin` | 规范化后的配对 origin（不带结尾 `/`） |
| `Sec-Fetch-Site` | `same-origin` |

### 9.4 Cookie

```text
dsh_ma_session           Path=/; Secure; HttpOnly; SameSite=Strict
dsh_ma_csrf              Path=/; Secure; SameSite=Strict
__Host-dsh_ma_session    Path=/; Secure; HttpOnly; SameSite=Strict
__Host-dsh_ma_csrf       Path=/; Secure; SameSite=Strict
dsh_ma_device            浏览器侧设备凭据（原生客户端不使用/不注入）
__Host-dsh_ma_device_id  浏览器侧非密钥设备标识（原生客户端不使用）
```

### 9.5 局域网发现

| 常量 | 值 |
| --- | --- |
| UDP 查询 | `DSH_MOBILE_DISCOVER_V1`（ASCII，22 字节） |
| UDP 端口 | `3443` |
| 广播间隔 | 每 `3000 ms` 一次 |
| DNS-SD 服务类型 | `_dsh-mobile._tcp` |
| TXT 键 | `deviceName`、`origin`、`instanceId`、`protocol` |
| 发现协议版本 | `1` |

### 9.6 建议上限

| 项目 | 建议值 |
| --- | --- |
| 控制请求体 | ≤ 16 KiB（上游 `MAX_CONTROL_BODY_BYTES`） |
| 控制响应体 | ≤ 32 KiB |
| CA 响应体 | ≤ 16 KiB |
| 错误响应体 | ≤ 8 KiB |
| 发现公告 | ≤ 8 KiB |
| 设备显示名 | 1–63 字符 |
| 插件版本 / 最低客户端版本 | 1–64 字符 |

### 9.7 参考超时（客户端实现选择，不属协议常量）

上游 Android 客户端的参考值：

| 场景 | bootstrap 连接/读取 | 认证连接/读取 |
| --- | --- | --- |
| 私有网络（LAN） | 500 / 800 ms | 3000 / 5000 ms |
| 远程网络 | 3000 / 5000 ms | 10000 / 30000 ms |

本仓库的 HarmonyOS 客户端使用 LAN 500/1500 ms、远程 3000/5000 ms（bootstrap），LAN 3000/5000 ms、远程 10000/30000 ms（认证）。这些值是客户端策略，可以调整。

---

## 10. 版本兼容与上游对照

### 10.1 版本字段

| 字段 | 位置 | 说明 |
| --- | --- | --- |
| `protocol` | discovery / UDP / DNS-SD TXT | 发现协议版本，当前 `1` |
| `discoveryProtocol` | metadata | 发现协议版本，当前 `1` |
| `version` | metadata | 元数据版本（≥ 1） |
| `pluginVersion` | metadata | 插件版本 |
| `minimumAndroidAppVersion` | metadata | 最低客户端版本（字段名历史原因保留） |

兼容策略：

- discovery `protocol != 1` → 不兼容；
- metadata 缺失（404）→ 按旧网关处理，继续配对；
- `dsh2` 格式是为新客户端引入的：不理解它的旧 Android 客户端会失败关闭（fail closed），这是有意的安全取舍；
- 旧版链接（legacy）必须继续被支持。

### 10.2 上游文件对照

协议实现位于上游仓库（以实际文件为准）：

| 上游文件 | 内容 |
| --- | --- |
| `src/gateway.ts` | 路由、`discovery` / `ca.cer` / `metadata`、`native-pair` / `native-renew` / `native-probe`、UDP 与 DNS-SD 发布 |
| `src/http-security.ts` | Cookie 属性、错误响应、请求信任策略（`source_network_untrusted`） |
| `src/browser-auth-cookies.ts` | 会话/CSRF/设备 Cookie 名称与鉴权 |
| `src/access.ts` | 配对 token、设备凭据、设备数量上限与限流 |
| `src/lan-setup.ts`、`src/remote.ts` | 入口模式与配对链接生成 |
| `apps/mobile/android/.../NativeAuthClient.kt` | 客户端参考实现（请求/响应校验、失败分类） |
| `apps/mobile/android/.../PinnedTls.kt` | 客户端参考实现（CA 固定、证书链校验） |
| `apps/mobile/android/.../LanDiscovery.kt`、`NsdDiscovery.kt` | 客户端参考实现（发现） |

上游仓库：<https://github.com/saya-ch/dsh-mobile>

### 10.3 本仓库的对应实现

| 协议部分 | 实现文件 |
| --- | --- |
| Origin / 配对 URL | `entry/src/main/ets/protocol/Origin.ets` |
| 配对密钥 | `entry/src/main/ets/protocol/PairingKey.ets` |
| CA / 指纹 / 链校验 | `entry/src/main/ets/protocol/CertPin.ets` |
| TLS 传输 | `entry/src/main/ets/protocol/TlsHttp.ets` |
| 控制接口与响应校验 | `entry/src/main/ets/protocol/GatewayHttp.ets` |
| 局域网发现 | `entry/src/main/ets/protocol/Discovery.ets` |
| 失败分类 | `entry/src/main/ets/protocol/AuthFailure.ets` |
| 会话 Cookie 注入 / 配对编排 | `entry/src/main/ets/service/AppService.ets` |

架构说明见 [ARCHITECTURE.md](ARCHITECTURE.md)。
