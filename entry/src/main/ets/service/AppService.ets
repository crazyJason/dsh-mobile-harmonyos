/**
 * Application service: pairing, session renewal, reachability and the ArkWeb trust decision.
 *
 * UI components talk to this singleton only; every network call is bounded and every failure is
 * translated into the classified `AuthFailure` the UI knows how to explain.
 */
import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { Log } from '../common/Log';
import { GatewayClient, GatewayDiscovery, GatewayMetadata, NativeProbe, NativeSession, asAuthFailure } from '../protocol/GatewayHttp';
import { AuthFailure, AuthFailureKind } from '../protocol/AuthFailure';
import { DeviceRecord, DeviceStatus, AccessMode, caPemToDer } from '../model/DeviceRecord';
import { DeviceStore } from '../model/DeviceStore';
import { GatewayOrigin, parseConnection } from '../protocol/Origin';
import { derToPem, sha256Hex } from '../protocol/CertPin';
import { LanDiscovery } from '../protocol/Discovery';
import { fetchServedCertificate } from '../protocol/TlsHttp';
import { PairingKey, PairingTarget, pairingKeyFromUrl, parsePairingKey } from '../protocol/PairingKey';
import { validatePairingCa, chainContainsPinnedCa, chainMatchesPinnedCa } from '../protocol/CertPin';

export class PairingResult {
  readonly record: DeviceRecord;
  readonly metadata: GatewayMetadata | undefined;

  constructor(record: DeviceRecord, metadata: GatewayMetadata | undefined) {
    this.record = record;
    this.metadata = metadata;
  }
}

/** Human-readable explanation for one classified failure. */
export function describeFailure(failure: AuthFailure): string {
  switch (failure.kind) {
    case AuthFailureKind.PAIRING_EXPIRED:
      return '配对码已失效或已被使用，请在电脑上重新生成配对链接';
    case AuthFailureKind.DEVICE_REVOKED:
      return '这台电脑已撤销本设备的授权，请重新配对';
    case AuthFailureKind.DEVICE_EXPIRED:
      return '设备凭据已过期，请重新配对';
    case AuthFailureKind.DEVICE_LIMIT:
      return '这台电脑的配对设备数量已达上限，请先在电脑端移除不用的设备';
    case AuthFailureKind.RATE_LIMITED:
      return '请求过于频繁，请稍后再试';
    case AuthFailureKind.SOURCE_NETWORK_UNTRUSTED:
      return '电脑端的可信网段不允许当前来源访问';
    case AuthFailureKind.TIMEOUT:
      return '连接超时，请确认手机与电脑在同一网络且移动访问已开启';
    case AuthFailureKind.TLS:
      return '证书校验失败：网关证书与配对信息不一致';
    case AuthFailureKind.SERVER_UNAVAILABLE:
      return '电脑端网关暂时不可用，请检查 DSH 的移动访问面板';
    case AuthFailureKind.INVALID_RESPONSE:
      return '网关响应不符合协议，可能插件版本过旧';
    case AuthFailureKind.STORAGE:
      return '无法在本机安全保存设备凭据，请检查系统存储状态';
    default:
      return '无法连接电脑，请检查网络与移动访问开关';
  }
}

/** Normalizes any thrown value into the classified failure the UI explains. */
export function toAuthFailure(error: Object): AuthFailure {
  return asAuthFailure(error);
}

/** Parses pasted input: a full pairing link, a bare pairing key, or an origin. */
export class PairingInput {
  readonly target: PairingTarget | undefined;
  readonly origin: GatewayOrigin | undefined;
  readonly key: PairingKey | undefined;
  readonly error: string;

  constructor(target: PairingTarget | undefined, origin: GatewayOrigin | undefined, key: PairingKey | undefined,
    error: string) {
    this.target = target;
    this.origin = origin;
    this.key = key;
    this.error = error;
  }
}

export function interpretPairingInput(rawValue: string): PairingInput {
  const text: string = rawValue.trim();
  if (text.length === 0) {
    return new PairingInput(undefined, undefined, undefined, '请粘贴电脑端复制的配对链接或密钥');
  }
  const connection = parseConnection(text);
  if (connection !== undefined) {
    const key: PairingKey | undefined = pairingKeyFromUrl(connection.initialUrl);
    if (key === undefined) {
      return new PairingInput(undefined, connection.origin, undefined,
        '链接里没有有效的配对密钥，请在电脑端重新生成配对链接');
    }
    const remote: boolean = !(connection.origin.host.startsWith('192.168.')
      || connection.origin.host.startsWith('10.')
      || connection.origin.host.startsWith('172.16.')
      || connection.origin.host.startsWith('127.'));
    return new PairingInput(new PairingTarget(connection, key, remote), connection.origin, key, '');
  }
  const key: PairingKey | undefined = parsePairingKey(text);
  if (key !== undefined) {
    return new PairingInput(undefined, undefined, key, '');
  }
  return new PairingInput(undefined, undefined, undefined, '无法识别的配对信息，请粘贴完整的配对链接');
}

export class AppService {
  private static instance: AppService | undefined = undefined;
  private store: DeviceStore = new DeviceStore();
  private context: common.UIAbilityContext | undefined = undefined;
  private devices: DeviceRecord[] = [];
  private initialized: boolean = false;

  static get(): AppService {
    if (AppService.instance === undefined) {
      AppService.instance = new AppService();
    }
    return AppService.instance;
  }

  /** Called once from EntryAbility so UI pages never need to look up the ability context. */
  attachContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  async initialize(): Promise<void> {
    if (this.initialized) {
      return;
    }
    const context: common.UIAbilityContext | undefined = this.context;
    if (context === undefined) {
      return;
    }
    this.initialized = true;
    await this.store.init(context);
    this.devices = await this.store.load();
  }

  abilityContext(): common.UIAbilityContext | undefined {
    return this.context;
  }

  list(): DeviceRecord[] {
    return this.devices;
  }

  find(key: string): DeviceRecord | undefined {
    for (const record of this.devices) {
      if (record.key === key) {
        return record;
      }
    }
    return undefined;
  }

  async upsert(record: DeviceRecord): Promise<void> {
    const updated: DeviceRecord[] = [];
    let replaced: boolean = false;
    for (const existing of this.devices) {
      if (existing.key === record.key) {
        updated.push(record);
        replaced = true;
      } else {
        updated.push(existing);
      }
    }
    if (!replaced) {
      updated.push(record);
    }
    this.devices = updated;
    await this.store.save(this.devices);
  }

  async remove(key: string): Promise<void> {
    const target: DeviceRecord | undefined = this.find(key);
    if (target !== undefined) {
      await this.store.deleteSecret(target);
    }
    this.devices = this.devices.filter((record: DeviceRecord) => record.key !== key);
    await this.store.save(this.devices);
  }

  async rename(key: string, name: string): Promise<void> {
    const target: DeviceRecord | undefined = this.find(key);
    if (target === undefined) {
      return;
    }
    const updated: DeviceRecord = target.copy();
    updated.name = name.trim().length > 0 ? name.trim() : updated.name;
    await this.upsert(updated);
  }

  /** Pairs one computer from a validated target and persists the resulting credential. */
  async pair(target: PairingTarget, label: string, displayName: string): Promise<PairingResult> {
    const origin: GatewayOrigin = target.origin();
    const key: PairingKey = target.key;
    const caDer: Uint8Array | undefined = await GatewayClient.fetchPairingCa(origin);
    Log.info(caDer === undefined ? 'pair: gateway served no pairing CA' : 'pair: pairing CA fetched');
    let pinned: Uint8Array;
    if (caDer === undefined) {
      // A LAN gateway is always self-signed, so it must serve its pairing CA; a missing CA there is
      // an identity failure rather than a reason to fall back to the platform trust store.
      if (key.requiresCa || !target.remote) {
        throw new AuthFailure(AuthFailureKind.TLS, 'gateway did not serve the pairing CA');
      }
      // A public-trust entry served by a real certificate authority.
      pinned = new Uint8Array(0);
    } else {
      const validated: Uint8Array | undefined = await validatePairingCa(caDer, key.instanceId);
      Log.info(validated === undefined
        ? 'pair: served CA does not match the pairing key'
        : 'pair: served CA matches the pairing key');
      if (validated === undefined) {
        throw new AuthFailure(AuthFailureKind.TLS, 'pairing CA does not match the pairing key');
      }
      pinned = validated;
    }
    let session: NativeSession;
    try {
      session = pinned.length === 0
        ? await GatewayClient.pairWithSystemTrust(origin, key.token, label, key.instanceId)
        : await GatewayClient.pair(origin, key.token, label, pinned, key.instanceId);
    } catch (pairError) {
      const failure: AuthFailure = asAuthFailure(pairError);
      Log.warn(`pair failed: ${failure.kind} ${failure.message}`);
      if (failure.kind === AuthFailureKind.TLS) {
        // A TLS rejection is the one failure where the served identity is worth recording: the
        // fingerprint tells the user which certificate the address actually answered with.
        await this.logServedCertificate(origin);
      }
      throw failure;
    }

    const record: DeviceRecord = new DeviceRecord();
    record.host = origin.host;
    record.port = origin.port;
    record.instanceId = session.instanceId;
    record.deviceId = session.deviceId;
    record.deviceToken = session.deviceToken === undefined ? '' : session.deviceToken;
    // The long-lived device credential expiry, not the short browsing session expiry.
    record.deviceExpiresAt = session.deviceExpiresAt === undefined ? 0 : session.deviceExpiresAt;
    record.caPem = pinned.length === 0 ? '' : derToPem(pinned);
    record.mode = target.remote ? AccessMode.REMOTE : AccessMode.LAN;
    record.installationId = session.installationId === undefined ? '' : session.installationId;
    record.name = displayName.trim().length > 0 ? displayName.trim() : origin.host;
    record.status = DeviceStatus.REACHABLE;
    record.lastReachableAt = Date.now();
    record.lastConnectedAt = Date.now();
    record.createdAt = Date.now();
    record.key = DeviceRecord.identityKey(session.instanceId, origin);

    try {
      await this.store.writeSecret(record, record.deviceToken);
    } catch (storageError) {
      throw new AuthFailure(AuthFailureKind.STORAGE, 'device credential could not be stored');
    }
    const existing: DeviceRecord | undefined = this.find(record.key);
    const stored: DeviceRecord = existing === undefined ? record : existing.adoptIdentity(record);
    await this.upsert(stored);
    Log.info('paired a DSH Mobile gateway');
    return new PairingResult(stored, undefined);
  }

  /** Records the certificate fingerprint a TLS failure was served with, for diagnostics only. */
  private async logServedCertificate(origin: GatewayOrigin): Promise<void> {
    const served: Uint8Array | undefined = await fetchServedCertificate(origin, 5000);
    if (served === undefined) {
      Log.warn('tls failure: the gateway served no readable certificate');
      return;
    }
    const fingerprint: string = await sha256Hex(served);
    Log.warn(`tls failure: served certificate sha256 ${fingerprint.substring(0, 16)}…`);
  }

  /** Renews the browsing session for a record and installs its cookies into ArkWeb. */
  async renewSession(record: DeviceRecord): Promise<NativeSession> {
    const origin: GatewayOrigin = record.origin();
    const caDer: Uint8Array | undefined = caPemToDer(record.caPem);
    const expiresAt: number = record.deviceExpiresAt;
    if (expiresAt > 0 && expiresAt <= Date.now()) {
      throw new AuthFailure(AuthFailureKind.DEVICE_EXPIRED, 'device credential expired');
    }
    const session: NativeSession = caDer === undefined
      ? await GatewayClient.renewWithSystemTrust(origin, record.deviceToken, record.instanceId)
      : await GatewayClient.renew(origin, record.deviceToken, caDer, record.instanceId);
    this.installCookies(origin, session);
    return session;
  }

  /** Tests reachability without creating a browsing session. */
  async probe(record: DeviceRecord): Promise<NativeProbe> {
    const origin: GatewayOrigin = record.origin();
    const caDer: Uint8Array | undefined = caPemToDer(record.caPem);
    return caDer === undefined
      ? await GatewayClient.probeWithSystemTrust(origin, record.deviceToken, record.instanceId)
      : await GatewayClient.probe(origin, record.deviceToken, caDer, record.instanceId);
  }

  /** Updates status fields for one record after a successful or failed probe. */
  async applyProbeOutcome(record: DeviceRecord, probe: NativeProbe | undefined,
    failure: AuthFailure | undefined): Promise<DeviceRecord> {
    const updated: DeviceRecord = record.copy();
    if (probe !== undefined) {
      updated.status = DeviceStatus.REACHABLE;
      updated.lastReachableAt = Date.now();
      if (updated.deviceId.length === 0) {
        updated.deviceId = probe.deviceId;
      }
    } else if (failure !== undefined) {
      switch (failure.kind) {
        case AuthFailureKind.DEVICE_REVOKED:
          updated.status = DeviceStatus.REVOKED;
          break;
        case AuthFailureKind.DEVICE_EXPIRED:
        case AuthFailureKind.PAIRING_EXPIRED:
          updated.status = DeviceStatus.EXPIRED;
          break;
        default:
          updated.status = DeviceStatus.UNREACHABLE;
          break;
      }
    }
    await this.upsert(updated);
    return updated;
  }

  async markConnected(record: DeviceRecord): Promise<DeviceRecord> {
    const updated: DeviceRecord = record.copy();
    updated.status = DeviceStatus.REACHABLE;
    updated.lastConnectedAt = Date.now();
    await this.upsert(updated);
    return updated;
  }

  /**
   * Installs the four session cookies the gateway expects.
   *
   * ArkWeb stores host-only cookies per origin, so the exact paired origin URL is used and the
   * HttpOnly aliases are written with `includeHttpOnly`.
   */
  installCookies(origin: GatewayOrigin, session: NativeSession): void {
    const url: string = origin.serialized();
    const cookies: string[] = [
      `dsh_ma_session=${session.sessionToken}; Path=/; Secure; HttpOnly; SameSite=Strict`,
      `dsh_ma_csrf=${session.csrfToken}; Path=/; Secure; SameSite=Strict`,
      `__Host-dsh_ma_session=${session.sessionToken}; Path=/; Secure; HttpOnly; SameSite=Strict`,
      `__Host-dsh_ma_csrf=${session.csrfToken}; Path=/; Secure; SameSite=Strict`
    ];
    for (const cookie of cookies) {
      try {
        // API 14+ can overwrite HttpOnly cookies; older releases fall back to a plain write.
        webview.WebCookieManager.configCookieSync(url, cookie, false, true);
      } catch (error) {
        try {
          webview.WebCookieManager.configCookieSync(url, cookie.replace('; HttpOnly', ''), false);
        } catch (fallbackError) {
          Log.warn('installing a session cookie failed');
        }
      }
    }
  }

  /**
   * Decides whether ArkWeb may continue past an SSL error for the paired gateway.
   *
   * Only a chain that contains or verifies to the pinned CA is accepted; any other certificate is
   * cancelled, which keeps a mis-issued gateway from silently taking over the session.
   */
  async shouldContinueSslError(record: DeviceRecord, chain: Uint8Array[]): Promise<boolean> {
    const caDer: Uint8Array | undefined = caPemToDer(record.caPem);
    if (caDer === undefined) {
      return false;
    }
    if (chain.length === 0) {
      return false;
    }
    if (await chainContainsPinnedCa(chain, record.instanceId)) {
      return true;
    }
    return await chainMatchesPinnedCa(chain, caDer, record.instanceId);
  }

  /** Discovery helper shared by the add-device flow. */
  async discoverLan(deepSweep: boolean): Promise<GatewayDiscovery[]> {
    const context: common.UIAbilityContext | undefined = this.context;
    if (context === undefined) {
      return [];
    }
    return LanDiscovery.scan(context as common.Context, deepSweep);
  }
}
