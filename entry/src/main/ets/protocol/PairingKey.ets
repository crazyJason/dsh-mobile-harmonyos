/**
 * One-time pairing keys shown by the desktop plugin.
 *
 * Two wire formats exist:
 *  - `dsh1.<instanceId>.<token>` / `dsh2.<instanceId>.<token>` in the pairing URL fragment,
 *    where the digit marks whether the entry serves its own CA (`dsh2`) or a public one (`dsh1`);
 *  - the legacy `instance=<instanceId>&token=<token>` fragment, which never requires a CA.
 */
import { GatewayConnection, GatewayOrigin, parseConnection } from './Origin';

const PAIRING_KEY = new RegExp('^dsh([12])\\.([a-f0-9]{64})\\.([A-Za-z0-9_-]{43})$');
const LEGACY_PAIR_FRAGMENT = new RegExp('^instance=([a-f0-9]{64})&token=([A-Za-z0-9_-]{43})$');

export class PairingKey {
  readonly instanceId: string;
  readonly token: string;
  /** Whether the gateway is required to serve the CA this key is fingerprinted against. */
  readonly requiresCa: boolean;

  constructor(instanceId: string, token: string, requiresCa: boolean) {
    this.instanceId = instanceId;
    this.token = token;
    this.requiresCa = requiresCa;
  }

  /** Stable identity of the key without revealing the token. */
  identity(): string {
    return this.instanceId;
  }
}

export function parsePairingKey(source: string): PairingKey | undefined {
  const match: RegExpMatchArray | null = source.trim().match(PAIRING_KEY);
  if (match === null) {
    return undefined;
  }
  return new PairingKey(match[2], match[3], match[1] === '2');
}

/** Extracts the key carried by the plugin's fixed pairing URL (fragment is never sent to the host). */
export function pairingKeyFromUrl(rawValue: string): PairingKey | undefined {
  const connection: GatewayConnection | undefined = parseConnection(rawValue);
  if (connection === undefined) {
    return undefined;
  }
  const hashAt: number = connection.initialUrl.indexOf('#');
  if (hashAt < 0) {
    return undefined;
  }
  const fragment: string = connection.initialUrl.substring(hashAt + 1);
  if (fragment.startsWith('key=')) {
    const parsed: PairingKey | undefined = parsePairingKey(fragment.substring('key='.length));
    return parsed !== undefined && parsed.requiresCa ? parsed : undefined;
  }
  const legacy: RegExpMatchArray | null = fragment.match(LEGACY_PAIR_FRAGMENT);
  if (legacy === null) {
    return undefined;
  }
  return new PairingKey(legacy[1], legacy[2], false);
}

/** A validated pairing target: the origin to persist plus the mode implied by its host. */
export class PairingTarget {
  readonly connection: GatewayConnection;
  readonly key: PairingKey;
  readonly remote: boolean;

  constructor(connection: GatewayConnection, key: PairingKey, remote: boolean) {
    this.connection = connection;
    this.key = key;
    this.remote = remote;
  }

  origin(): GatewayOrigin {
    return this.connection.origin;
  }
}

/**
 * A saved remote CA stays mandatory when the same computer is paired again, so a stripped
 * `dsh1` key cannot downgrade an entry that previously pinned a CA.
 */
export function preserveRemotePin(remote: boolean, key: PairingKey, hasSavedCa: boolean): PairingKey {
  return remote && hasSavedCa && !key.requiresCa ? new PairingKey(key.instanceId, key.token, true) : key;
}
