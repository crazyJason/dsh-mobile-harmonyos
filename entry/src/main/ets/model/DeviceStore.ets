/**
 * Durable paired-computer storage.
 *
 * Display metadata and pinned identities live in preferences; the long-lived device credential
 * lives in the Asset Store (system keystore-backed, unlocked-device accessibility), so a backup or
 * a preferences dump never exposes a usable credential.
 */
import { preferences } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Log';
import { DeviceRecord, fromJson, toJson } from './DeviceRecord';
import { GatewayOrigin } from '../protocol/Origin';

const PREF_NAME: string = 'dsh_mobile_devices';
const PREF_KEY: string = 'records';
const ASSET_NOT_FOUND: number = 24000002;

function textBytes(text: string): Uint8Array {
  return new util.TextEncoder('utf-8').encodeInto(text);
}

function bytesText(value: Uint8Array): string {
  return util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(value);
}

export class DeviceStore {
  private prefs: preferences.Preferences | undefined = undefined;

  async init(context: common.Context): Promise<void> {
    const options: preferences.Options = { name: PREF_NAME };
    this.prefs = preferences.getPreferencesSync(context, options);
  }

  /** Loads every valid record and attaches its stored credential. */
  async load(): Promise<DeviceRecord[]> {
    if (this.prefs === undefined) {
      return [];
    }
    const raw: string = this.prefs.getSync(PREF_KEY, '') as string;
    if (raw.length === 0) {
      return [];
    }
    let parsed: Object = '';
    try {
      parsed = JSON.parse(raw);
    } catch (error) {
      Log.warn('device list is unreadable; starting empty');
      return [];
    }
    if (!Array.isArray(parsed)) {
      return [];
    }
    const records: DeviceRecord[] = [];
    for (const entry of parsed as Object[]) {
      if (typeof entry !== 'string') {
        continue;
      }
      const record: DeviceRecord | undefined = fromJson(entry as string);
      if (record === undefined) {
        continue;
      }
      const secret: string | undefined = await this.readSecret(record);
      record.deviceToken = secret === undefined ? '' : secret;
      records.push(record);
    }
    return records;
  }

  async save(records: DeviceRecord[]): Promise<void> {
    if (this.prefs === undefined) {
      return;
    }
    const serialized: string[] = [];
    for (const record of records) {
      serialized.push(toJson(record));
    }
    this.prefs.putSync(PREF_KEY, JSON.stringify(serialized));
    await this.prefs.flush();
  }

  private aliasOf(record: DeviceRecord): string {
    return DeviceRecord.secretAlias(record.instanceId, new GatewayOrigin(record.host, record.port));
  }

  async writeSecret(record: DeviceRecord, token: string): Promise<void> {
    if (token.length === 0) {
      return;
    }
    const alias: string = this.aliasOf(record);
    await this.deleteSecretAlias(alias);
    try {
      const attributes: asset.AssetMap = new Map();
      attributes.set(asset.Tag.SECRET, textBytes(token));
      attributes.set(asset.Tag.ALIAS, textBytes(alias));
      attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
      await asset.add(attributes);
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      Log.error(`storing the device credential failed (${failure.code})`);
      throw new Error('device credential could not be stored');
    }
  }

  async readSecret(record: DeviceRecord): Promise<string | undefined> {
    return this.readSecretAlias(this.aliasOf(record));
  }

  private async readSecretAlias(alias: string): Promise<string | undefined> {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, textBytes(alias));
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const found: Array<asset.AssetMap> = await asset.query(query);
      if (found.length === 0) {
        return undefined;
      }
      const value: asset.Value | undefined = found[0].get(asset.Tag.SECRET);
      if (value instanceof Uint8Array) {
        return bytesText(value);
      }
      return undefined;
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      if (failure.code !== ASSET_NOT_FOUND) {
        Log.warn(`reading the device credential failed (${failure.code})`);
      }
      return undefined;
    }
  }

  async deleteSecret(record: DeviceRecord): Promise<void> {
    await this.deleteSecretAlias(this.aliasOf(record));
  }

  private async deleteSecretAlias(alias: string): Promise<void> {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, textBytes(alias));
      await asset.remove(query);
    } catch (error) {
      const failure: BusinessError = error as BusinessError;
      if (failure.code !== ASSET_NOT_FOUND) {
        Log.warn(`removing the device credential failed (${failure.code})`);
      }
    }
  }
}
