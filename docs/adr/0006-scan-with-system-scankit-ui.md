# ADR-0006 扫码用系统 Scan Kit 默认界面，不自绘取景器

- 状态：已采纳
- 日期：2026-11
- 相关文件：`entry/src/main/ets/common/Scanner.ets`、`entry/src/main/ets/pages/Index.ets`、`scripts/verify.ps1`、[PROTOCOL §3.4](../PROTOCOL.md#34-解析规则)

## 背景

电脑端插件把配对链接编码成二维码（`/api/mobile-access/lan/pairing/open` 与 `/api/mobile-access/remote/pairing/open` 都返回 `qrSvg`），上游 Android 客户端的配对入口就是扫码。本项目早期版本没有扫码，只能把 100 多个字符的链接用聊天工具发到手机再复制粘贴——远程场景下这是最容易出错的步骤（链接被截断、复制时机不对、配对码已过期）。

实现扫码有两类做法：

1. 用系统 Scan Kit 的默认扫码界面（`@kit.ScanKit` → `scanBarcode.startScanForResult`）；
2. 自绘相机预览（`@ohos.multimedia.camera`）+ 自带或引入 QR 解码。

## 决策

扫码只做**输入通道**：调用系统默认扫码界面拿到二维码原文，交给已有的 `interpretPairingInput`，与手工粘贴走完全相同的解析、入口分类与 CA 校验路径。

- 唯一入口是 `common/Scanner.ets` 的 `scanPairingQr()`；`verify.ps1` 保证 `@kit.ScanKit` 只在该文件里被 import。
- 不申请 `ohos.permission.CAMERA`：默认界面的相机预览运行在系统进程内，系统已预授权。
- 用户取消（错误码 `1000500002`）返回 `CANCELLED`，UI 不提示错误；其他失败返回 `FAILED`，UI 提示改用粘贴。
- 二维码里只有裸密钥时，扫到后仍要求补地址：扫码无法提供地址。
- 扫到完整链接后**直接继续配对**，不再要求用户点一次「开始配对」：链接自带 origin，没有需要用户确认的字段，而配对码有效期默认只有 120 秒。

## 后果

好处：

- 零第三方依赖（「无 ohpm 依赖」的仓库约定不变）、零新权限，`module.json5` 不需要改；
- 相机预览、相册识别、暗光闪光灯提示都由系统提供，省掉整套相机生命周期与权限申请；
- 扫到的字符串与粘贴的字符串完全一致，因此信任模型没有新增分支，[ADR-0002](0002-trust-root-is-instance-id.md) 的信任根不受影响。

代价与边界：

- 扫码界面外观由系统决定，无法定制文案与品牌（API 6.1.0(23) 之前标题固定为「扫描二维码或条形码」）；
- 依赖设备上的 HMS Scan 服务（`com.huawei.hms.scanservice`）；缺失时调用失败，所以粘贴路径必须永久保留——它是扫码不可用时的兜底；
- 扫码结果的原文是凭据（二维码里带着配对 token）：只在内存里流转，不写日志，`Log.ets` 的脱敏只是第二道防线；
- 引入了一个只能在真机上验证的行为（系统 UI、HMS 依赖），按 [AGENTS §5](../../AGENTS.md#5-当前状态与风险2026-11) 的要求必须写明需要人工复测的 TC 用例。

## 被否决的方案

| 方案 | 否决理由 |
| --- | --- |
| 自绘相机预览 + 第三方 QR 解码库 | 需要 `ohos.permission.CAMERA`（用户侧多一次授权弹窗）、要引入 ohpm 依赖（违反「无第三方依赖」），还要自己处理预览帧、旋转、对焦与页面生命周期；换来的只有 UI 定制 |
| 自绘相机预览 + Scan Kit 的 `detectBarcode.decodeImage` | 同样需要 CAMERA 权限与自己的预览实现；`decodeImage` 面向静态图，实时识别还得自己抽帧 |
| 单独做「从相册选图识别」 | 默认界面已带相册入口（`enableAlbum`），单独做一条路径只增加代码，不增加能力 |
| 扫码后只填表单、不自动配对 | 配对码默认 120 秒有效，多一次点击就多一次「配对码已失效」；链接自带的 origin 不需要用户确认 |
