/**
 * The container that hosts the dedicated DSH Mobile page.
 *
 * Responsibilities beyond a plain `Web` component:
 *  - renew the browsing session and install the gateway cookies before the first load;
 *  - continue past TLS errors only when the served chain verifies to the pinned pairing CA;
 *  - keep navigation on the paired origin, handing any other HTTPS link to the system browser.
 */
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Log';
import { Palette } from '../common/Theme';
import { DeviceRecord } from '../model/DeviceRecord';
import { AppService, describeSessionFailure, toAuthFailure } from '../service/AppService';
import { isExternalHttps, isPinnedAuthority, isSameOrigin } from '../protocol/Origin';

const SESSION_REFRESH_MS: number = 10 * 60 * 1000;

@Component
export struct BrowserView {
  @Prop record: DeviceRecord = new DeviceRecord();
  onExit: () => void = () => undefined;

  @State private url: string = '';
  @State private ready: boolean = false;
  @State private failure: string = '';
  @State private progress: number = 0;
  @State private pageTitle: string = '';
  @State private loading: boolean = true;
  private controller: webview.WebviewController = new webview.WebviewController();
  private sslConfirmed: boolean = false;
  private refreshTimer: number = -1;

  aboutToAppear(): void {
    this.open();
    this.refreshTimer = setInterval(() => {
      if (this.ready) {
        AppService.get().renewSession(this.record).catch((error: Object) => {
          Log.warn('background session renewal failed');
        });
      }
    }, SESSION_REFRESH_MS);
  }

  aboutToDisappear(): void {
    if (this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
  }

  /** Renews the session, installs cookies, then mounts the page. */
  private open(): void {
    this.failure = '';
    this.loading = true;
    AppService.get().renewSession(this.record).then(() => {
      AppService.get().markConnected(this.record).catch(() => {
        Log.warn('could not record the connection time');
      });
      this.url = `${this.record.origin().serialized()}/`;
      this.ready = true;
    }).catch((error: Object) => {
      this.failure = describeSessionFailure(toAuthFailure(error));
      this.loading = false;
    });
  }

  private retry(): void {
    this.ready = false;
    this.sslConfirmed = false;
    this.open();
  }

  /**
   * ArkWeb reports every resource that fails certificate validation. The paired gateway uses a
   * private CA, so the request continues only after the served chain is proven to belong to that
   * CA; anything else is cancelled.
   */
  private handleSslError(event: SslErrorEvent): void {
    if (this.sslConfirmed) {
      event.handler.handleConfirm();
      return;
    }
    const chain: Uint8Array[] = event.certChainData === undefined ? [] : event.certChainData;
    if (chain.length === 0) {
      event.handler.handleCancel();
      return;
    }
    // ArkWeb reports WebSocket handshake failures with a `wss:` URL, so the secure scheme family
    // must be accepted while host and port still have to match exactly.
    if (!isPinnedAuthority(this.record.origin(), event.url)) {
      event.handler.handleCancel();
      return;
    }
    AppService.get().shouldContinueSslError(this.record, chain).then((trusted: boolean) => {
      if (trusted) {
        this.sslConfirmed = true;
        event.handler.handleConfirm();
      } else {
        event.handler.handleCancel();
        this.failure = '网关证书与配对信息不一致，已阻止连接';
        this.loading = false;
      }
    }).catch(() => {
      event.handler.handleCancel();
    });
  }

  /** Keeps the container on the paired origin and hands other HTTPS links to the browser. */
  private handleLoadIntercept(event: OnLoadInterceptEvent): boolean {
    const target: string = event.data.getRequestUrl();
    if (isSameOrigin(this.record.origin(), target)) {
      return false;
    }
    if (isExternalHttps(target)) {
      const context: common.UIAbilityContext | undefined = AppService.get().abilityContext();
      if (context !== undefined) {
        context.startAbility({
          action: 'ohos.want.action.viewData',
          entities: ['entity.system.browsable'],
          uri: target
        }).catch((error: BusinessError) => {
          Log.warn(`could not hand ${target} to the browser`);
        });
      }
      return true;
    }
    return false;
  }

  @Builder
  topBar() {
    Row({ space: 10 }) {
      Button('‹')
        .fontSize(20)
        .width(38)
        .height(38)
        .backgroundColor(Palette.surfaceRaised)
        .fontColor(Palette.textPrimary)
        .borderRadius(12)
        .onClick(() => this.onExit())
      Column({ space: 2 }) {
        Text(this.pageTitle.length > 0 ? this.pageTitle : this.record.name)
          .fontSize(14)
          .fontColor(Palette.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.record.origin().serialized().replace('https://', ''))
          .fontSize(11)
          .fontColor(Palette.textMuted)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Button('⟳')
        .fontSize(17)
        .width(38)
        .height(38)
        .backgroundColor(Palette.surfaceRaised)
        .fontColor(Palette.textPrimary)
        .borderRadius(12)
        .onClick(() => {
          if (!this.ready) {
            this.retry();
            return;
          }
          try {
            this.controller.refresh();
          } catch (error) {
            promptAction.showToast({ message: '页面尚未就绪' });
          }
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor(Palette.background)
  }

  @Builder
  failureOverlay() {
    Column({ space: 14 }) {
      Text('无法打开电脑端页面')
        .fontSize(16)
        .fontColor(Palette.textPrimary)
        .fontWeight(FontWeight.Medium)
      Text(this.failure)
        .fontSize(13)
        .fontColor(Palette.textSecondary)
        .textAlign(TextAlign.Center)
        .lineHeight(20)
      Row({ space: 12 }) {
        Button('重试')
          .height(40)
          .layoutWeight(1)
          .backgroundColor(Palette.accent)
          .fontColor(Palette.onAccent)
          .onClick(() => this.retry())
        Button('返回列表')
          .height(40)
          .layoutWeight(1)
          .backgroundColor(Palette.surfaceRaised)
          .fontColor(Palette.textPrimary)
          .onClick(() => this.onExit())
      }
      .width('100%')
    }
    .width('100%')
    .padding(24)
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
  }

  build() {
    Column() {
      this.topBar()
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.ready) {
          Web({ src: this.url, controller: this.controller })
            .width('100%')
            .height('100%')
            .domStorageAccess(true)
            .javaScriptAccess(true)
            .fileAccess(false)
            .imageAccess(true)
            .mixedMode(MixedMode.Compatible)
            .cacheMode(CacheMode.Default)
            .darkMode(WebDarkMode.Auto)
            .horizontalScrollBarAccess(false)
            .onSslErrorEvent((event: SslErrorEvent) => {
              this.handleSslError(event);
            })
            .onLoadIntercept((event: OnLoadInterceptEvent) => this.handleLoadIntercept(event))
            .onPageBegin(() => {
              this.loading = true;
            })
            .onProgressChange((event: OnProgressChangeEvent) => {
              this.progress = event.newProgress;
            })
            .onPageEnd(() => {
              this.loading = false;
              this.progress = 0;
            })
            .onTitleReceive((event: OnTitleReceiveEvent) => {
              this.pageTitle = event.title;
            })
            .onErrorReceive((event: OnErrorReceiveEvent) => {
              if (event.request.isMainFrame() && event.error.getErrorInfo().length > 0) {
                Log.warn('page load reported an error');
              }
            })
        } else if (this.failure.length > 0) {
          this.failureOverlay()
        } else {
          Column({ space: 12 }) {
            LoadingProgress().width(32).height(32).color(Palette.accent)
            Text('正在建立安全连接…')
              .fontSize(13)
              .fontColor(Palette.textSecondary)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        }

        if (this.progress > 0 && this.progress < 100) {
          Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(2)
            .color(Palette.accent)
            .backgroundColor(Palette.surface)
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Palette.background)
  }
}
