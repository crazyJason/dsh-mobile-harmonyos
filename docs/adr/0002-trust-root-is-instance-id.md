# ADR-0002 信任根只有 `instanceId = SHA-256(配对 CA DER)`

- 状态：已采纳
- 日期：2026-11
- 相关文件：`entry/src/main/ets/protocol/CertPin.ets`、`entry/src/main/ets/protocol/PairingKey.ets`、`entry/src/main/ets/service/AppService.ets`

## 背景

配对链接的片段里带着 `instanceId`（64 位小写 hex）。它不是随机的电脑标识，而是**电脑端配对 CA 证书 DER 的 SHA-256**。上游在启动网关时会校验这一点：

```ts
// src/gateway.ts
if (!certificate.ca || certificate.subject !== certificate.issuer
  || !certificate.verify(certificate.publicKey) || fingerprint !== this.config.instanceId) {
  throw new Error('pairingCaFile must be the self-signed CA identified by instanceId')
}
```

手机端因此拿到了一条**离线可验证的绑定**：链接里的 `instanceId` ↔ 电脑上那张自签 CA。信任链上没有任何第三方（没有公共 CA、没有域名、没有系统信任库）。

## 决策

**先把 `instanceId` 当作唯一信任根；在 CA 指纹校验通过之前，不信任网关返回的任何内容。**

具体规则：

1. **bootstrap 阶段不信任任何证书**：`/mobile-access/ca.cer` 走 `TrustMode.SKIP` 拉取。
2. **CA 必须同时满足**：`SHA-256(DER) == instanceId`、`basicConstraints >= 0`（是 CA）、自签名可验（用自身公钥验签）、当前时间在有效期内。任一不满足立即中止，且**不得**退回系统信任库。
3. **`dsh2` 密钥强制 CA**：`ca.cer` 返回 404 是硬失败，不允许降级。
4. **私网（LAN）入口同样强制 CA**：与上游 `PairingTrust.selectTrustAnchor` 一致；只有公网证书远程入口在明确 404 时才使用系统信任库。
5. **配对响应必须回带同一个 `instanceId`**：`GatewayHttp.ets` 校验响应键集合、字段格式、`instanceId === expected`、过期时间在未来且为整数，任何一项不符即 `INVALID_RESPONSE`。
6. **凭据只发往已确定的信任锚**：`native-pair` / `native-renew` / `native-probe` 一律在 CA 固定后才发送。
7. **ArkWeb 的 SSL 错误只在能证明链属于固定 CA 时续接**：`chainContainsPinnedCa`（字节相等）或 `chainMatchesPinnedCa`（叶子证书由固定 CA 验签）二者之一成立才 `handleConfirm()`，否则 `handleCancel()`。

## 后果

- 手机不需要公共 CA、DNS 或证书透明度就能识别「这是不是那台电脑」；
- 换电脑、重装插件会生成新的 `instanceId`，必须重新配对（这是预期行为，不提供迁移捷径）；
- 代价：`instanceId` 一旦泄露不构成风险（它是公钥材料的指纹），但**配对令牌**是秘密，见 `Log.ets` 的脱敏；
- 代价：CA 有效期依赖电脑时钟；证书过期后会以「证书校验失败」表现，需要重新配对。

## 被否决的方案

| 方案 | 否决理由 |
| --- | --- |
| 只校验 TLS 握手成功 | 自签证书场景下任何自签证书都能通过，等价于不校验 |
| 让用户肉眼比对指纹 | 手机上比对 64 位 hex 不可行，且二维码里已可机器校验 |
| 首次配对后改用 TOFU（首次信任后固定） | 首次配对正是攻击窗口，插件已经提供了可验证的绑定，没有理由放弃 |
| 妥协：校验失败时允许「仍然继续」 | 一个「继续」按钮会摧毁整条信任链，且用户无法判断风险 |

## 检查方式

`scripts/verify.ps1` 会确认 `CertPin.ets` 仍包含指纹比对；`common/SelfCheck.ets` 在设备端断言密钥与链接解析规则。真机用例见 `docs/TESTING.md` 的安全负向用例（伪造 CA、错误 `instanceId`、过期密钥）。
