/**
 * One paired computer.
 *
 * A record stores only what the app needs to reconnect: the pinned origin, the DSH instance id
 * that proves the gateway identity, the long-lived device credential, and display metadata.
 * Session tokens are never persisted — they are renewed on demand.
 */
import { GatewayOrigin } from '../protocol/Origin';
import { pemToDer } from '../protocol/CertPin';

export enum DeviceStatus {
  UNKNOWN = 'UNKNOWN',
  CHECKING = 'CHECKING',
  REACHABLE = 'REACHABLE',
  UNREACHABLE = 'UNREACHABLE',
  REVOKED = 'REVOKED',
  EXPIRED = 'EXPIRED',
  ADDRESS_CHANGED = 'ADDRESS_CHANGED',
}

export enum AccessMode {
  LAN = 'LAN',
  REMOTE = 'REMOTE',
}

export class DeviceRecord {
  /** Stable local identity: instance id plus the exact origin it was paired through. */
  key: string = '';
  name: string = '';
  host: string = '';
  port: number = 443;
  instanceId: string = '';
  deviceId: string = '';
  /** Long-lived credential; persisted only in the Asset Store, never in preferences. */
  deviceToken: string = '';
  deviceExpiresAt: number = 0;
  /** Pinned CA in PEM form, or empty when the entry uses the platform trust store. */
  caPem: string = '';
  mode: AccessMode = AccessMode.LAN;
  installationId: string = '';
  status: DeviceStatus = DeviceStatus.UNKNOWN;
  lastReachableAt: number = 0;
  lastConnectedAt: number = 0;
  createdAt: number = 0;

  origin(): GatewayOrigin {
    return new GatewayOrigin(this.host, this.port);
  }

  hasPinnedCa(): boolean {
    return this.caPem.length > 0;
  }

  /** Whether this record currently holds a credential worth probing or renewing. */
  isConnectable(): boolean {
    return this.deviceToken.length > 0 && this.status !== DeviceStatus.REVOKED;
  }

  displayMode(): string {
    return this.mode === AccessMode.LAN ? '局域网' : '远程';
  }

  copy(): DeviceRecord {
    const clone: DeviceRecord = new DeviceRecord();
    clone.key = this.key;
    clone.name = this.name;
    clone.host = this.host;
    clone.port = this.port;
    clone.instanceId = this.instanceId;
    clone.deviceId = this.deviceId;
    clone.deviceToken = this.deviceToken;
    clone.deviceExpiresAt = this.deviceExpiresAt;
    clone.caPem = this.caPem;
    clone.mode = this.mode;
    clone.installationId = this.installationId;
    clone.status = this.status;
    clone.lastReachableAt = this.lastReachableAt;
    clone.lastConnectedAt = this.lastConnectedAt;
    clone.createdAt = this.createdAt;
    return clone;
  }

  /** Returns a copy with the origin, identity and credential of `other`, keeping display fields. */
  adoptIdentity(other: DeviceRecord): DeviceRecord {
    const merged: DeviceRecord = other.copy();
    merged.name = this.name.length > 0 ? this.name : other.name;
    merged.createdAt = this.createdAt;
    return merged;
  }

  static identityKey(instanceId: string, origin: GatewayOrigin): string {
    return `${instanceId}@${origin.serialized()}`;
  }

  /** Stable secret alias: never contains the origin's page state or the token itself. */
  static secretAlias(instanceId: string, origin: GatewayOrigin): string {
    return `dsh-mobile/${instanceId}/${origin.serialized()}`;
  }
}

/** Storage shape: one JSON object per record, without the secret. */
export interface DeviceRecordJson {
  key: string;
  name: string;
  host: string;
  port: number;
  instanceId: string;
  deviceId: string;
  deviceExpiresAt: number;
  caPem: string;
  mode: string;
  installationId: string;
  status: string;
  lastReachableAt: number;
  lastConnectedAt: number;
  createdAt: number;
}

export function toJson(record: DeviceRecord): string {
  const payload: DeviceRecordJson = {
    key: record.key,
    name: record.name,
    host: record.host,
    port: record.port,
    instanceId: record.instanceId,
    deviceId: record.deviceId,
    deviceExpiresAt: record.deviceExpiresAt,
    caPem: record.caPem,
    mode: record.mode,
    installationId: record.installationId,
    status: record.status,
    lastReachableAt: record.lastReachableAt,
    lastConnectedAt: record.lastConnectedAt,
    createdAt: record.createdAt
  };
  return JSON.stringify(payload);
}

function invalidRecord(): Error {
  return new Error('invalid device record');
}

function readStringField(source: Record<string, Object>, name: string): string {
  const value: Object = source[name];
  if (typeof value === 'string') {
    return value as string;
  }
  throw invalidRecord();
}

function readNumberField(source: Record<string, Object>, name: string): number {
  const value: Object = source[name];
  if (typeof value === 'number') {
    return value as number;
  }
  throw invalidRecord();
}

/** Rebuilds a record from storage; malformed entries are dropped rather than repaired. */
export function fromJson(text: string): DeviceRecord | undefined {
  try {
    const parsed: Object = JSON.parse(text);
    if (typeof parsed !== 'object' || parsed === null) {
      return undefined;
    }
    const source: Record<string, Object> = parsed as Record<string, Object>;
    const record: DeviceRecord = new DeviceRecord();
    record.key = readStringField(source, 'key');
    record.name = readStringField(source, 'name');
    record.host = readStringField(source, 'host');
    record.port = readNumberField(source, 'port');
    record.instanceId = readStringField(source, 'instanceId');
    record.deviceId = readStringField(source, 'deviceId');
    record.deviceExpiresAt = readNumberField(source, 'deviceExpiresAt');
    record.caPem = readStringField(source, 'caPem');
    record.mode = readStringField(source, 'mode') === AccessMode.REMOTE ? AccessMode.REMOTE : AccessMode.LAN;
    record.installationId = readStringField(source, 'installationId');
    record.status = DeviceStatus.UNKNOWN;
    record.lastReachableAt = readNumberField(source, 'lastReachableAt');
    record.lastConnectedAt = readNumberField(source, 'lastConnectedAt');
    record.createdAt = readNumberField(source, 'createdAt');
    if (record.key.length === 0 || record.instanceId.length === 0 || record.deviceId.length === 0) {
      return undefined;
    }
    return record;
  } catch (error) {
    return undefined;
  }
}

/** Rebuilds the pinned CA DER from the stored PEM form. */
export function caPemToDer(pem: string): Uint8Array | undefined {
  return pemToDer(pem);
}