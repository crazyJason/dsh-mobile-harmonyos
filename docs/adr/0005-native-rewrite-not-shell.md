# ADR-0005 原生 ArkTS 重写，而不是套壳 WebView / 复用 Android 客户端

- 状态：已采纳
- 日期：2026-11
- 相关文件：[`README.md`](../../README.md)「为什么需要」、`entry/src/main/ets/`、[ADR-0003](0003-device-credential-in-asset-store.md)

## 背景

上游 `dsh-mobile` 提供的手机端是 **Android 客户端（Kotlin + WebView 外壳）**，打包为 `.apk`，依赖 Android 的 `WebView`、`NsdManager`、`SharedPreferences` 等组件。

目标平台是 HarmonyOS NEXT（纯血鸿蒙），它**移除了 Android 运行时兼容层**，APK 既不能安装也不能运行。

同时，用手机浏览器直接打开网关地址也完不成配对：

- 配对密钥放在 URL **片段**（`#...`）里，片段不会被发送到服务器，网页端拿不到；
- 网页没有「把设备凭据交给系统密钥库」的能力；
- 局域网自签证书需要一个系统级的信任锚注入点，网页做不到。

## 决策

用 **ArkTS / ArkUI 原生重写**手机端：

- 自己解析配对链接、校验并固定 CA、调用 `native-pair` / `native-renew` / `native-probe`；
- 设备元数据存 `@ohos.data.preferences`，**设备凭据存 Asset Store Kit**（不落 preferences、不进日志）；
- 页面部分交给 ArkWeb 容器承载（浏览 DSH 移动端网页），但不依赖任何 Android 私有 API。

## 备选方案与取舍

| 方案 | 为什么没选 |
| --- | --- |
| 打包 Android APK 给鸿蒙用 | HarmonyOS NEXT 不运行 APK，安装即失败 |
| 用鸿蒙上的 Android 兼容层 / 模拟器 | 平台已移除该能力；即使有也不是可分发方案 |
| 浏览器 + PWA（不做原生壳） | 无法读取 URL 片段、无法固定自签 CA、无法把凭据放进安全存储，配对这一步就断了 |
| 让用户在电脑端手工复制 token 再在网页里粘贴 | 破坏一次性配对的安全模型（token 会进页面/日志），且没有原生凭据存储 |

## 后果

**好处**

- 在 API 12 上就能完成配对、证书固定与安全存储；
- 不依赖 Android 兼容性，后续跟随鸿蒙 API 演进；
- 协议实现可控，能精确复刻上游的校验规则与错误码。

**代价**

- 需要**自己维护一份 ArkTS 版协议实现**，上游协议变更要人肉跟进（对照表见 README「与上游 Android 客户端的对应关系」）；
- 上游的部分外围能力（原生桥 `window.dshMobileNative`、扫码、推送、iroh、应用内更新、画中画、后台服务）**本项目有意未实现**，页面会以降级的「浏览器模式」运行；
- 上游 Android 的行为是事实来源，但代码不能直接复用，只能按协议重写。

**什么时候重新评估**

- 上游正式提供 HarmonyOS 版客户端时（本仓库可转为参考实现或归档）；
- 鸿蒙侧提供稳定的跨平台 WebView 桥与安全存储标准接口时。

> 改动提醒：不要引入「Android 兼容层 / 打包 APK」这类捷径；也不要把「未实现原生桥」当成 bug——那是与 README 一致的、有意的降级路径。
