/**
 * Root screen.
 *
 * The app keeps three views in one page instead of routing: the ArkWeb container must survive
 * re-renders of the device list, and a paired session is more expensive to rebuild than a view
 * switch. `view` is the single source of navigation truth.
 */
import { promptAction } from '@kit.ArkUI';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Log';
import { Palette, formatRelative } from '../common/Theme';
import { DeviceRecord, DeviceStatus } from '../model/DeviceRecord';
import { AppService, PairingInput, describeFailure, interpretPairingInput, toAuthFailure } from '../service/AppService';
import { PairingTarget } from '../protocol/PairingKey';
import { GatewayConnection, GatewayOrigin, isPrivateNetworkHost, parseOrigin } from '../protocol/Origin';
import { GatewayDiscovery, NativeProbe } from '../protocol/GatewayHttp';
import { BrowserView } from './BrowserView';
import { SelfCheckResult, runSelfCheck } from '../common/SelfCheck';

enum ViewName {
  LIST = 'LIST',
  ADD = 'ADD',
  BROWSER = 'BROWSER'
}

/** Status text for one paired record. */
function statusLabel(record: DeviceRecord): string {
  switch (record.status) {
    case DeviceStatus.CHECKING:
      return '检测中';
    case DeviceStatus.REACHABLE:
      return '可达';
    case DeviceStatus.UNREACHABLE:
      return '暂不可达';
    case DeviceStatus.REVOKED:
      return '电脑端已移除';
    case DeviceStatus.EXPIRED:
      return '配对已过期';
    case DeviceStatus.ADDRESS_CHANGED:
      return '地址已变化';
    default:
      return '未检测';
  }
}

function statusColor(record: DeviceRecord): string {
  switch (record.status) {
    case DeviceStatus.REACHABLE:
      return Palette.success;
    case DeviceStatus.CHECKING:
      return Palette.warning;
    case DeviceStatus.REVOKED:
    case DeviceStatus.EXPIRED:
      return Palette.danger;
    default:
      return Palette.textMuted;
  }
}

@Entry
@Component
struct Index {
  @State private view: ViewName = ViewName.LIST;
  @State private devices: DeviceRecord[] = [];
  @State private activeDevice: DeviceRecord | undefined = undefined;
  @State private busy: boolean = false;
  @State private pairingError: string = '';
  @State private pairingStatus: string = '';
  @State private scanBusy: boolean = false;
  @State private discovered: GatewayDiscovery[] = [];
  @State private pairInput: string = '';
  @State private manualHost: string = '';
  @State private selectedDiscovery: GatewayDiscovery | undefined = undefined;
  @State private renameTarget: DeviceRecord | undefined = undefined;
  @State private renameValue: string = '';
  @State private showRenameSheet: boolean = false;

  aboutToAppear(): void {
    AppService.get().initialize().then(() => {
      this.reloadDevices();
    }).catch(() => {
      this.toast('读取本地配对记录失败');
    });
  }

  private reloadDevices(): void {
    this.devices = AppService.get().list().slice(0);
    this.refreshStatuses();
  }

  /** Probes every stored device in the background; each result updates only its own record. */
  private refreshStatuses(): void {
    for (const record of this.devices) {
      if (!record.isConnectable()) {
        continue;
      }
      this.applyChecking(record.key);
      AppService.get().probe(record)
        .then((probe: NativeProbe) => AppService.get().applyProbeOutcome(record, probe, undefined))
        .catch((error: Object) => AppService.get().applyProbeOutcome(record, undefined, toAuthFailure(error)))
        .then(() => {
          this.devices = AppService.get().list().slice(0);
        })
        .catch(() => {
          this.devices = AppService.get().list().slice(0);
        });
    }
  }

  private applyChecking(key: string): void {
    const updated: DeviceRecord[] = [];
    for (const record of this.devices) {
      if (record.key === key) {
        const copy: DeviceRecord = record.copy();
        copy.status = DeviceStatus.CHECKING;
        updated.push(copy);
      } else {
        updated.push(record);
      }
    }
    this.devices = updated;
  }

  private toast(message: string): void {
    promptAction.showToast({ message: message, duration: 2200 });
  }

  private readClipboard(): void {
    pasteboard.getSystemPasteboard().getData().then((data: pasteboard.PasteData) => {
      const text: string = data.getPrimaryText();
      if (text.length > 0) {
        this.pairInput = text.trim();
        this.pairingError = '';
        this.toast('已从剪贴板粘贴');
      } else {
        this.toast('剪贴板里没有文本');
      }
    }).catch((error: BusinessError) => {
      Log.warn('clipboard read unavailable');
      this.toast('无法读取剪贴板，请手动粘贴');
    });
  }

  private scanLan(): void {
    if (this.scanBusy) {
      return;
    }
    this.scanBusy = true;
    this.discovered = [];
    this.pairingError = '';
    AppService.get().discoverLan(false).then((found: GatewayDiscovery[]) => {
      this.discovered = found;
      if (found.length === 0) {
        this.toast('未发现电脑，请确认两者在同一网络');
      }
    }).catch((error: Object) => {
      this.toast('扫描失败');
    }).then(() => {
      this.scanBusy = false;
    });
  }

  private selectDiscovered(entry: GatewayDiscovery): void {
    this.selectedDiscovery = entry;
    this.manualHost = `${entry.origin.host}:${entry.origin.port}`;
    this.pairingError = '';
  }

  /** Resolves the pasted value plus the optional manual host into a pairing target. */
  private startPairing(): void {
    if (this.busy) {
      return;
    }
    this.pairingError = '';
    const parsed: PairingInput = interpretPairingInput(this.pairInput);
    const key = parsed.key;
    if (key === undefined) {
      this.pairingError = parsed.error;
      return;
    }
    let target: PairingTarget | undefined = parsed.target;
    if (target === undefined) {
      // A bare key needs an address: the discovered computer, then the manual field.
      let originText: string = '';
      if (this.selectedDiscovery !== undefined) {
        originText = this.selectedDiscovery.origin.serialized();
        if (this.selectedDiscovery.instanceId !== key.instanceId) {
          this.pairingError = '配对密钥与所选电脑不是同一台，请重新在电脑端生成配对链接';
          return;
        }
      } else if (this.manualHost.trim().length > 0) {
        const host: string = this.manualHost.trim();
        originText = host.startsWith('https://') ? host : `https://${host}`;
        if (originText.indexOf(':', 'https://'.length) < 0) {
          originText = `${originText}:3443`;
        }
      } else {
        this.pairingError = '请先扫描局域网并选择一台电脑，或填写电脑地址';
        return;
      }
      const origin: GatewayOrigin | undefined = parseOrigin(originText);
      if (origin === undefined) {
        this.pairingError = '电脑地址格式不正确';
        return;
      }
      target = new PairingTarget(new GatewayConnection(origin, origin.serialized()), key, !isPrivateNetworkHost(origin.host));
    }
    const displayName: string = this.selectedDiscovery === undefined
      ? target.origin().host
      : this.selectedDiscovery.deviceName;
    this.busy = true;
    this.pairingStatus = '正在验证电脑身份并配对…';
    AppService.get().pair(target, 'DeepSeek Harness HarmonyOS', displayName).then(() => {
      this.pairInput = '';
      this.manualHost = '';
      this.selectedDiscovery = undefined;
      this.discovered = [];
      this.pairingStatus = '';
      this.view = ViewName.LIST;
      this.reloadDevices();
      this.toast('配对成功');
    }).catch((error: Object) => {
      this.pairingError = describeFailure(toAuthFailure(error));
      this.pairingStatus = '';
    }).then(() => {
      this.busy = false;
    });
  }

  private openDevice(record: DeviceRecord): void {
    if (record.status === DeviceStatus.REVOKED || record.status === DeviceStatus.EXPIRED
      || record.deviceToken.length === 0) {
      // dsh-mobile deletes a revoked device, so the last probe reports EXPIRED rather than REVOKED;
      // both mean this credential no longer works and both need a fresh pairing.
      this.toast('这台电脑已不再信任本设备，请删除记录后重新配对');
      return;
    }
    this.activeDevice = record;
    this.view = ViewName.BROWSER;
  }

  private probeOnce(record: DeviceRecord): void {
    this.applyChecking(record.key);
    AppService.get().probe(record)
      .then((probe: NativeProbe) => AppService.get().applyProbeOutcome(record, probe, undefined))
      .catch((error: Object) => AppService.get().applyProbeOutcome(record, undefined, toAuthFailure(error)))
      .then(() => {
        this.devices = AppService.get().list().slice(0);
      });
  }

  private showDeviceActions(record: DeviceRecord): void {
    promptAction.showActionMenu({
      title: record.name,
      buttons: [
        { text: '立即检测', color: Palette.textPrimary },
        { text: '重命名', color: Palette.textPrimary },
        { text: '删除本机记录', color: Palette.danger }
      ]
    }).then((result: promptAction.ActionMenuSuccessResponse) => {
      if (result.index === 0) {
        this.probeOnce(record);
      } else if (result.index === 1) {
        this.renameTarget = record;
        this.renameValue = record.name;
        this.showRenameSheet = true;
      } else if (result.index === 2) {
        this.confirmDelete(record);
      }
    }).catch((error: BusinessError) => {
      Log.warn('action menu dismissed');
    });
  }

  private confirmDelete(record: DeviceRecord): void {
    promptAction.showDialog({
      title: '删除本地记录',
      message: `删除后本机不再保存「${record.name}」的凭据，电脑端授权不受影响。`,
      buttons: [
        { text: '取消', color: Palette.textSecondary },
        { text: '删除', color: Palette.danger }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        AppService.get().remove(record.key).then(() => {
          this.reloadDevices();
          this.toast('已删除本地记录');
        });
      }
    }).catch((error: BusinessError) => {
      Log.warn('delete dialog dismissed');
    });
  }

  /** Runs the pure protocol rules on this device and reports the outcome. */
  private showSelfCheck(): void {
    const result: SelfCheckResult = runSelfCheck();
    const title: string = result.ok() ? '协议自检通过' : '协议自检失败';
    const body: string = result.ok()
      ? `${result.passed.length} 项检查全部通过，当前安装的构建与桌面插件协议一致。`
      : `${result.failed.length} 项失败：\n${result.failed.join('\n')}`;
    promptAction.showDialog({
      title: title,
      message: body,
      buttons: [{ text: '知道了', color: Palette.accent }]
    }).catch(() => {
      Log.warn('self-check dialog dismissed');
    });
  }

  private commitRename(): void {
    const target: DeviceRecord | undefined = this.renameTarget;
    if (target === undefined) {
      return;
    }
    AppService.get().rename(target.key, this.renameValue).then(() => {
      this.showRenameSheet = false;
      this.renameTarget = undefined;
      this.reloadDevices();
    });
  }

  @Builder
  titleBlock(title: string, subtitle: string) {
    Column({ space: 4 }) {
      Text(title)
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(Palette.textPrimary)
      Text(subtitle)
        .fontSize(12)
        .fontColor(Palette.textSecondary)
    }
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  deviceCard(record: DeviceRecord) {
    Row({ space: 12 }) {
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Text(record.name)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Palette.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(record.displayMode())
            .fontSize(10)
            .fontColor(Palette.accent)
            .backgroundColor(Palette.accentSoft)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(6)
        }
        .width('100%')

        Text(record.origin().serialized().replace('https://', ''))
          .fontSize(12)
          .fontColor(Palette.textMuted)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Row({ space: 6 }) {
          Circle().width(7).height(7).fill(statusColor(record))
          Text(statusLabel(record))
            .fontSize(12)
            .fontColor(statusColor(record))
          Text(`· ${formatRelative(record.lastConnectedAt)}`)
            .fontSize(12)
            .fontColor(Palette.textMuted)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('›')
        .fontSize(22)
        .fontColor(Palette.textMuted)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Palette.surface)
    .borderRadius(16)
    .border({ width: 1, color: Palette.stroke })
    .onClick(() => this.openDevice(record))
    .gesture(LongPressGesture().onAction(() => this.showDeviceActions(record)))
  }

  @Builder
  emptyState() {
    Column({ space: 14 }) {
      Text('还没有配对的电脑')
        .fontSize(17)
        .fontColor(Palette.textPrimary)
        .fontWeight(FontWeight.Medium)
      Text('先在电脑的 DeepSeek Harness 中启用「移动访问」并生成配对链接，\n再用手机粘贴链接或扫描局域网完成配对。')
        .fontSize(13)
        .fontColor(Palette.textSecondary)
        .textAlign(TextAlign.Center)
        .lineHeight(20)
      Button('添加电脑')
        .fontSize(14)
        .height(42)
        .backgroundColor(Palette.accent)
        .fontColor(Palette.onAccent)
        .onClick(() => {
          this.pairingError = '';
          this.pairingStatus = '';
          this.view = ViewName.ADD;
        })
      Text('运行协议自检')
        .fontSize(12)
        .fontColor(Palette.textMuted)
        .padding(6)
        .onClick(() => this.showSelfCheck())
    }
    .width('100%')
    .padding({ top: 56, bottom: 56, left: 20, right: 20 })
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  listView() {
    Column() {
      Row({ space: 12 }) {
        this.titleBlock('DSH Mobile', '连接电脑上的 DeepSeek Harness')
        Blank()
        // ASCII '+' on purpose: the full-width U+FF0B has no glyph in the device font stack on
        // HarmonyOS 7 and degrades to a tiny square, so the button looked broken on a real phone.
        Button('+')
          .fontSize(24)
          .width(40)
          .height(40)
          .backgroundColor(Palette.surfaceRaised)
          .fontColor(Palette.textPrimary)
          .borderRadius(12)
          .onClick(() => {
            this.pairingError = '';
            this.pairingStatus = '';
            this.view = ViewName.ADD;
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 12 })

      Scroll() {
        Column({ space: 12 }) {
          if (this.devices.length === 0) {
            this.emptyState()
          } else {
            ForEach(this.devices, (record: DeviceRecord) => {
              this.deviceCard(record)
            }, (record: DeviceRecord) => `${record.key}:${record.status}`)
            Text('轻点连接，长按管理这台电脑')
              .fontSize(12)
              .fontColor(Palette.textMuted)
              .margin({ top: 8 })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 32 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.background)
  }

  @Builder
  discoveredRow(entry: GatewayDiscovery) {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text(entry.deviceName)
          .fontSize(15)
          .fontColor(Palette.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${entry.origin.host}:${entry.origin.port}`)
          .fontSize(12)
          .fontColor(Palette.textMuted)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text(this.selectedDiscovery !== undefined && this.selectedDiscovery.instanceId === entry.instanceId
        ? '已选择' : '选择')
        .fontSize(11)
        .fontColor(this.selectedDiscovery !== undefined && this.selectedDiscovery.instanceId === entry.instanceId
          ? Palette.accent : Palette.textSecondary)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.selectedDiscovery !== undefined && this.selectedDiscovery.instanceId === entry.instanceId
      ? Palette.surfaceRaised : Palette.surface)
    .borderRadius(14)
    .border({ width: 1, color: Palette.stroke })
    .onClick(() => this.selectDiscovered(entry))
  }

  @Builder
  addView() {
    Column() {
      Row({ space: 10 }) {
        Button('‹')
          .fontSize(20)
          .width(38)
          .height(38)
          .backgroundColor(Palette.surfaceRaised)
          .fontColor(Palette.textPrimary)
          .borderRadius(12)
          .onClick(() => {
            this.view = ViewName.LIST;
          })
        this.titleBlock('添加电脑', '粘贴配对链接或扫描局域网')
        Blank()
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 12 })

      Scroll() {
        Column({ space: 18 }) {
          Column({ space: 6 }) {
            Text('1. 在电脑端生成配对链接')
              .fontSize(13)
              .fontColor(Palette.textSecondary)
            Text('DeepSeek Harness → 移动访问 → 复制配对链接（或生成配对二维码）。局域网场景请让手机与电脑连同一个 Wi-Fi。')
              .fontSize(12)
              .fontColor(Palette.textMuted)
              .lineHeight(18)
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          Column({ space: 10 }) {
            Text('2. 粘贴配对链接或密钥')
              .fontSize(13)
              .fontColor(Palette.textSecondary)
            TextArea({ text: this.pairInput, placeholder: 'https://192.168.1.10:3443/mobile-access/pair#key=dsh2.…' })
              .height(84)
              .fontSize(12)
              .fontColor(Palette.textPrimary)
              .placeholderColor(Palette.textMuted)
              .backgroundColor(Palette.surface)
              .borderRadius(12)
              .border({ width: 1, color: Palette.stroke })
              .onChange((value: string) => {
                this.pairInput = value;
                this.pairingError = '';
              })
            Button('从剪贴板粘贴')
              .fontSize(13)
              .height(36)
              .backgroundColor(Palette.surfaceRaised)
              .fontColor(Palette.textPrimary)
              .borderRadius(10)
              .onClick(() => this.readClipboard())
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          Column({ space: 10 }) {
            Row({ space: 8 }) {
              Text('3. 选择电脑（局域网扫描）')
                .fontSize(13)
                .fontColor(Palette.textSecondary)
                .layoutWeight(1)
              Button(this.scanBusy ? '扫描中…' : '扫描局域网')
                .fontSize(12)
                .height(32)
                .backgroundColor(Palette.surfaceRaised)
                .fontColor(Palette.textPrimary)
                .borderRadius(10)
                .enabled(!this.scanBusy)
                .onClick(() => this.scanLan())
            }
            .width('100%')

            if (this.discovered.length > 0) {
              ForEach(this.discovered, (entry: GatewayDiscovery) => {
                this.discoveredRow(entry)
              }, (entry: GatewayDiscovery) => entry.instanceId)
            } else if (this.scanBusy) {
              Row({ space: 10 }) {
                LoadingProgress().width(18).height(18).color(Palette.accent)
                Text('正在搜索运行 DSH Mobile 插件的电脑…')
                  .fontSize(12)
                  .fontColor(Palette.textMuted)
              }
              .width('100%')
            }

            TextInput({ text: this.manualHost, placeholder: '或手动填写 192.168.1.10:3443' })
              .height(40)
              .fontSize(13)
              .fontColor(Palette.textPrimary)
              .placeholderColor(Palette.textMuted)
              .backgroundColor(Palette.surface)
              .borderRadius(12)
              .border({ width: 1, color: Palette.stroke })
              .onChange((value: string) => {
                this.manualHost = value;
              })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          if (this.pairingError.length > 0) {
            Text(this.pairingError)
              .fontSize(12)
              .fontColor(Palette.danger)
              .width('100%')
              .lineHeight(18)
          }

          if (this.pairingStatus.length > 0) {
            Row({ space: 10 }) {
              LoadingProgress().width(16).height(16).color(Palette.accent)
              Text(this.pairingStatus)
                .fontSize(12)
                .fontColor(Palette.textSecondary)
            }
            .width('100%')
          }

          Button(this.busy ? '配对中…' : '开始配对')
            .width('100%')
            .height(46)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .backgroundColor(this.busy ? Palette.accentSoft : Palette.accent)
            .fontColor(Palette.onAccent)
            .borderRadius(14)
            .enabled(!this.busy)
            .onClick(() => this.startPairing())

          Text('配对成功后，本机保存的设备凭据只对这台电脑有效；电脑端「设备」页面可随时撤销。')
            .fontSize(11)
            .fontColor(Palette.textMuted)
            .lineHeight(16)
            .width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 32 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.background)
  }

  @Builder
  renameSheet() {
    Column({ space: 12 }) {
      Text('重命名电脑')
        .fontSize(15)
        .fontColor(Palette.textPrimary)
      TextInput({ text: this.renameValue })
        .height(42)
        .fontSize(14)
        .fontColor(Palette.textPrimary)
        .backgroundColor(Palette.surface)
        .borderRadius(12)
        .onChange((value: string) => {
          this.renameValue = value;
        })
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .height(40)
          .backgroundColor(Palette.surface)
          .fontColor(Palette.textSecondary)
          .onClick(() => {
            this.showRenameSheet = false;
            this.renameTarget = undefined;
          })
        Button('保存')
          .layoutWeight(1)
          .height(40)
          .backgroundColor(Palette.accent)
          .fontColor(Palette.onAccent)
          .onClick(() => this.commitRename())
      }
      .width('100%')
    }
    .width('100%')
    .padding(20)
    .backgroundColor(Palette.surfaceRaised)
    .borderRadius({ topLeft: 20, topRight: 20 })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.view === ViewName.LIST) {
        this.listView()
      } else if (this.view === ViewName.ADD) {
        this.addView()
      } else if (this.view === ViewName.BROWSER && this.activeDevice !== undefined) {
        BrowserView({
          record: this.activeDevice,
          onExit: () => {
            this.view = ViewName.LIST;
            this.activeDevice = undefined;
            this.reloadDevices();
          }
        })
      }

      if (this.showRenameSheet) {
        this.renameSheet()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.background)
  }
}
