/**
 * LAN discovery for computers running the DSH Mobile plugin.
 *
 * Three independent paths run concurrently and results are merged by DSH instance id:
 *  - UDP broadcast: the plugin embeds a small JSON announcement on port 3443 and answers
 *    `DSH_MOBILE_DISCOVER_V1` queries with the same document;
 *  - DNS-SD (mDNS): the plugin publishes `_dsh-mobile._tcp` with the same metadata;
 *  - an HTTPS sweep of the local subnet, used only when both passive paths found nothing.
 *
 * Every announcement is treated as a hint: it must be self-consistent (the advertised origin must
 * match the peer that sent it) before it is shown. The gateway itself is authenticated later by the
 * pairing key's CA fingerprint.
 */
import { socket } from '@kit.NetworkKit';
import { connection } from '@kit.NetworkKit';
import { mdns } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Log';
import { GatewayOrigin, DEFAULT_GATEWAY_PORT, parseOrigin, isPrivateNetworkHost } from './Origin';
import { GatewayClient, GatewayDiscovery } from './GatewayHttp';
import { INSTANCE_ID_PATTERN } from './CertPin';
import { JsonObject, parseJsonObject, readNumber, readString, keyCount } from '../common/Json';

export const DISCOVERY_QUERY: string = 'DSH_MOBILE_DISCOVER_V1';
export const DISCOVERY_PROTOCOL: number = 1;
export const MDNS_SERVICE_TYPE: string = '_dsh-mobile._tcp';
const PASSIVE_TIMEOUT_MS: number = 3500;
const SWEEP_CONCURRENCY: number = 24;
const MAX_SUBNETS: number = 4;

class Subnet {
  readonly prefix: string;
  readonly ownHosts: Set<number>;

  constructor(prefix: string, ownHosts: Set<number>) {
    this.prefix = prefix;
    this.ownHosts = ownHosts;
  }

  /** Directed broadcast address for this /24-shaped subnet. */
  broadcast(): string {
    return `${this.prefix}.255`;
  }
}

/** Parses one UDP/mDNS announcement; rejects anything inconsistent with its sender. */
export function parseAnnouncement(source: string, remoteAddress: string | undefined): GatewayDiscovery | undefined {
  const body: JsonObject | undefined = parseJsonObject(source);
  if (body === undefined || keyCount(body) !== 5) {
    return undefined;
  }
  const protocol: number | undefined = readNumber(body, 'protocol');
  const instanceId: string | undefined = readString(body, 'instanceId');
  const deviceName: string | undefined = readString(body, 'deviceName');
  const rawOrigin: string | undefined = readString(body, 'origin');
  const port: number | undefined = readNumber(body, 'port');
  if (protocol === undefined || protocol !== DISCOVERY_PROTOCOL) {
    return undefined;
  }
  if (instanceId === undefined || !INSTANCE_ID_PATTERN.test(instanceId)) {
    return undefined;
  }
  if (deviceName === undefined || deviceName.trim().length === 0 || deviceName.length > 63) {
    return undefined;
  }
  if (rawOrigin === undefined || port === undefined) {
    return undefined;
  }
  const origin: GatewayOrigin | undefined = parseOrigin(rawOrigin);
  if (origin === undefined || origin.port !== port) {
    return undefined;
  }
  if (remoteAddress !== undefined && remoteAddress === '') {
    return undefined;
  }
  if (remoteAddress !== undefined && origin.host !== remoteAddress) {
    // The announcement must describe the sender, not a third computer.
    return undefined;
  }
  return new GatewayDiscovery(deviceName, origin, instanceId);
}

function mergeByInstance(found: GatewayDiscovery[]): GatewayDiscovery[] {
  const merged: Map<string, GatewayDiscovery> = new Map<string, GatewayDiscovery>();
  for (const entry of found) {
    if (!merged.has(entry.instanceId)) {
      merged.set(entry.instanceId, entry);
    }
  }
  return Array.from(merged.values());
}

/** Reads the local IPv4 /24 prefixes this device is attached to. */
function localSubnets(): Subnet[] {
  const byPrefix: Map<string, Set<number>> = new Map<string, Set<number>>();
  try {
    const handle: connection.NetHandle = connection.getDefaultNetSync();
    const properties: connection.ConnectionProperties = connection.getConnectionPropertiesSync(handle);
    for (const link of properties.linkAddresses) {
      const address: string = link.address.address;
      if (!isPrivateNetworkHost(address) || address === 'localhost') {
        continue;
      }
      const parts: string[] = address.split('.');
      if (parts.length !== 4) {
        continue;
      }
      const prefix: string = `${parts[0]}.${parts[1]}.${parts[2]}`;
      const host: number = Number.parseInt(parts[3], 10);
      const hosts: Set<number> | undefined = byPrefix.get(prefix);
      if (hosts === undefined) {
        byPrefix.set(prefix, new Set<number>([host]));
      } else {
        hosts.add(host);
      }
    }
  } catch (error) {
    Log.warn('could not read local network addresses');
  }
  const subnets: Subnet[] = [];
  byPrefix.forEach((hosts: Set<number>, prefix: string) => {
    if (subnets.length < MAX_SUBNETS) {
      subnets.push(new Subnet(prefix, hosts));
    }
  });
  return subnets;
}

function sleep(milliseconds: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => resolve(), milliseconds);
  });
}

/** Sends the discovery query to every plausible broadcast address and collects announcements. */
async function udpDiscovery(subnets: Subnet[]): Promise<GatewayDiscovery[]> {
  const found: GatewayDiscovery[] = [];
  const udpSocket: socket.UDPSocket = socket.constructUDPSocketInstance();
  try {
    udpSocket.on('message', (info: socket.SocketMessageInfo) => {
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      const text: string = decoder.decodeToString(new Uint8Array(info.message));
      const announcement: GatewayDiscovery | undefined = parseAnnouncement(text, info.remoteInfo.address);
      if (announcement !== undefined) {
        found.push(announcement);
      }
    });
    udpSocket.on('error', (error: BusinessError) => {
      Log.warn(`discovery socket error ${error.code}`);
    });
    // Binding the gateway's fixed port also receives its unsolicited announcements; if the port is
    // taken, an ephemeral port still receives the direct replies to our query.
    try {
      await udpSocket.bind({ address: '0.0.0.0', port: DEFAULT_GATEWAY_PORT, family: 1 });
    } catch (bindError) {
      await udpSocket.bind({ address: '0.0.0.0', port: 0, family: 1 });
    }
    await udpSocket.setExtraOptions({ broadcast: true, reuseAddress: true, receiveBufferSize: 16384 });
    const targets: Set<string> = new Set<string>();
    targets.add('255.255.255.255');
    targets.add('192.168.43.255');
    targets.add('172.20.10.255');
    for (const subnet of subnets) {
      targets.add(subnet.broadcast());
    }
    const query: Uint8Array = new Uint8Array(DISCOVERY_QUERY.length);
    for (let index = 0; index < DISCOVERY_QUERY.length; index++) {
      query[index] = DISCOVERY_QUERY.charCodeAt(index) & 0xff;
    }
    for (const target of targets) {
      try {
        await udpSocket.send({
          data: query.buffer as ArrayBuffer,
          address: { address: target, port: DEFAULT_GATEWAY_PORT, family: 1 }
        });
      } catch (error) {
        Log.warn(`discovery broadcast to ${target} failed`);
      }
    }
    await sleep(PASSIVE_TIMEOUT_MS);
  } catch (error) {
    Log.warn('udp discovery unavailable');
  } finally {
    try {
      await udpSocket.close();
    } catch (error) {
      Log.warn('discovery socket close failed');
    }
  }
  return found;
}

/** Reads a DNS-SD attribute as UTF-8 text. */
function attributeText(attributes: mdns.ServiceAttribute[], name: string): string | undefined {
  for (const attribute of attributes) {
    if (attribute.key === name) {
      let text: string = '';
      for (const byte of attribute.value) {
        text += String.fromCharCode(byte);
      }
      return text;
    }
  }
  return undefined;
}

function parseMdnsService(service: mdns.LocalServiceInfo): GatewayDiscovery | undefined {
  const attributes: mdns.ServiceAttribute[] = service.serviceAttribute === undefined ? [] : service.serviceAttribute;
  const protocol: string | undefined = attributeText(attributes, 'protocol');
  const instanceId: string | undefined = attributeText(attributes, 'instanceId');
  const deviceName: string | undefined = attributeText(attributes, 'deviceName');
  const rawOrigin: string | undefined = attributeText(attributes, 'origin');
  if (protocol !== '1' || instanceId === undefined || deviceName === undefined || rawOrigin === undefined) {
    return undefined;
  }
  if (!INSTANCE_ID_PATTERN.test(instanceId) || deviceName.length === 0 || deviceName.length > 63) {
    return undefined;
  }
  const origin: GatewayOrigin | undefined = parseOrigin(rawOrigin);
  if (origin === undefined) {
    return undefined;
  }
  if (service.port !== undefined && service.port !== origin.port) {
    return undefined;
  }
  return new GatewayDiscovery(deviceName, origin, instanceId);
}

async function mdnsDiscovery(context: common.Context): Promise<GatewayDiscovery[]> {
  const found: GatewayDiscovery[] = [];
  let service: mdns.DiscoveryService | undefined = undefined;
  try {
    service = mdns.createDiscoveryService(context, MDNS_SERVICE_TYPE);
    service.on('serviceFound', (info: mdns.LocalServiceInfo) => {
      const parsed: GatewayDiscovery | undefined = parseMdnsService(info);
      if (parsed !== undefined) {
        found.push(parsed);
      }
    });
    service.startSearchingMDNS();
    await sleep(PASSIVE_TIMEOUT_MS);
    service.stopSearchingMDNS();
  } catch (error) {
    Log.warn('mdns discovery unavailable');
  }
  return found;
}

/** Probes one candidate address over HTTPS; only a well-formed discovery document counts. */
async function probeHost(host: string): Promise<GatewayDiscovery | undefined> {
  const origin: GatewayOrigin | undefined = parseOrigin(`https://${host}:${DEFAULT_GATEWAY_PORT}`);
  if (origin === undefined) {
    return undefined;
  }
  try {
    return await GatewayClient.fetchDiscovery(origin);
  } catch (error) {
    return undefined;
  }
}

/** Bounded concurrency sweep of every host address in the local subnets. */
async function sweepDiscovery(subnets: Subnet[]): Promise<GatewayDiscovery[]> {
  const hosts: string[] = [];
  for (const subnet of subnets) {
    for (let host = 1; host <= 254; host++) {
      if (!subnet.ownHosts.has(host)) {
        hosts.push(`${subnet.prefix}.${host}`);
      }
    }
  }
  const found: GatewayDiscovery[] = [];
  let cursor: number = 0;
  const workers: Promise<void>[] = [];
  for (let slot = 0; slot < SWEEP_CONCURRENCY; slot++) {
    workers.push((async (): Promise<void> => {
      while (cursor < hosts.length) {
        const host: string = hosts[cursor];
        cursor++;
        const result: GatewayDiscovery | undefined = await probeHost(host);
        if (result !== undefined) {
          found.push(result);
        }
      }
    })());
  }
  await Promise.all(workers);
  return found;
}

export class LanDiscovery {
  /**
   * Runs every discovery path and merges the results.
   * @param context ability context required by DNS-SD
   * @param deepSweep whether to fall back to the HTTPS subnet sweep
   */
  static async scan(context: common.Context, deepSweep: boolean): Promise<GatewayDiscovery[]> {
    const subnets: Subnet[] = localSubnets();
    const passive: Promise<GatewayDiscovery[]>[] = [
      udpDiscovery(subnets),
      mdnsDiscovery(context)
    ];
    const results: GatewayDiscovery[][] = await Promise.all(passive);
    let merged: GatewayDiscovery[] = [];
    for (const batch of results) {
      merged = merged.concat(batch);
    }
    merged = mergeByInstance(merged);
    if (merged.length > 0 || !deepSweep || subnets.length === 0) {
      return merged;
    }
    const swept: GatewayDiscovery[] = await sweepDiscovery(subnets);
    return mergeByInstance(swept);
  }
}

