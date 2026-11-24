/**
 * Canonical HTTPS origin handling for the dedicated DSH Mobile web container.
 *
 * Mirrors the Android client's `GatewayOrigin`/`GatewayConnection` rules: only absolute HTTPS
 * origins or the plugin's fixed one-time pairing URL are accepted, and everything ambiguous is
 * rejected rather than repaired.
 */

export const HTTPS_PORT: number = 443;
export const DEFAULT_GATEWAY_PORT: number = 3443;
export const PAIR_PATH: string = '/mobile-access/pair';
export const AUTH_PREFIX: string = '/mobile-access';

const HOSTNAME_LABEL = '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$';
const IPV4_LITERAL = '^([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})\\.([0-9]{1,3})$';

/** A normalized HTTPS origin approved for the dedicated DSH Web container. */
export class GatewayOrigin {
  readonly host: string;
  readonly port: number;

  constructor(host: string, port: number) {
    this.host = host;
    this.port = port;
  }

  /** Canonical text persisted by the app; safe to share without page state. */
  serialized(): string {
    const renderedHost: string = this.host.indexOf(':') >= 0 ? `[${this.host}]` : this.host;
    return this.port === HTTPS_PORT ? `https://${renderedHost}` : `https://${renderedHost}:${this.port}`;
  }

  equals(other: GatewayOrigin): boolean {
    return this.host === other.host && this.port === other.port;
  }

  /** Stable storage key: never contains credentials or page state. */
  key(): string {
    return this.serialized();
  }
}

/** A safe first page plus the origin that is the only persisted value. */
export class GatewayConnection {
  readonly origin: GatewayOrigin;
  readonly initialUrl: string;

  constructor(origin: GatewayOrigin, initialUrl: string) {
    this.origin = origin;
    this.initialUrl = initialUrl;
  }
}

interface SplitUrl {
  scheme: string;
  authority: string;
  path: string;
  query: string | undefined;
  fragment: string | undefined;
}

const PAIR_FRAGMENT =
  '^(?:instance=[a-f0-9]{64}&token=[A-Za-z0-9_-]{43}|key=dsh2\\.[a-f0-9]{64}\\.[A-Za-z0-9_-]{43})$';

/** Splits an absolute URL without normalizing it, so malformed input stays detectable. */
function splitUrl(raw: string): SplitUrl | undefined {
  const trimmed: string = raw.trim();
  const schemeEnd: number = trimmed.indexOf('://');
  if (schemeEnd <= 0) {
    return undefined;
  }
  const scheme: string = trimmed.substring(0, schemeEnd).toLowerCase();
  const rest: string = trimmed.substring(schemeEnd + 3);
  let authorityEnd: number = rest.length;
  const pathStart: number = rest.indexOf('/');
  if (pathStart >= 0 && pathStart < authorityEnd) {
    authorityEnd = pathStart;
  }
  const q: number = rest.indexOf('?');
  if (q >= 0 && q < authorityEnd) {
    authorityEnd = q;
  }
  const h: number = rest.indexOf('#');
  if (h >= 0 && h < authorityEnd) {
    authorityEnd = h;
  }
  const authority: string = rest.substring(0, authorityEnd);
  const tail: string = rest.substring(authorityEnd);
  let fragment: string | undefined = undefined;
  let withoutFragment: string = tail;
  const hashAt: number = tail.indexOf('#');
  if (hashAt >= 0) {
    fragment = tail.substring(hashAt + 1);
    withoutFragment = tail.substring(0, hashAt);
  }
  let query: string | undefined = undefined;
  let path: string = withoutFragment;
  const questionAt: number = withoutFragment.indexOf('?');
  if (questionAt >= 0) {
    query = withoutFragment.substring(questionAt + 1);
    path = withoutFragment.substring(0, questionAt);
  }
  return { scheme: scheme, authority: authority, path: path, query: query, fragment: fragment };
}

function isValidIpv4(candidate: string): boolean {
  const match: RegExpMatchArray | null = candidate.match(new RegExp(IPV4_LITERAL));
  if (match === null) {
    return false;
  }
  for (let index = 1; index <= 4; index++) {
    const octet = Number.parseInt(match[index], 10);
    if (!Number.isInteger(octet) || octet < 0 || octet > 255) {
      return false;
    }
  }
  return true;
}

/** Normalizes one host fragment; returns undefined for anything a browser would reinterpret. */
function canonicalHost(rawHost: string): string | undefined {
  if (rawHost.length === 0) {
    return undefined;
  }
  for (let index = 0; index < rawHost.length; index++) {
    if (rawHost.charCodeAt(index) > 0x7f) {
      return undefined;
    }
  }
  let host: string = rawHost;
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  host = host.toLowerCase();
  if (host.length === 0) {
    return undefined;
  }
  if (host.indexOf(':') >= 0) {
    // IPv6 literal: reject zone ids and obviously truncated forms.
    if (host.indexOf('%') >= 0) {
      return undefined;
    }
    let colons: number = 0;
    for (let index = 0; index < host.length; index++) {
      const c: string = host.charAt(index);
      if (c === ':') {
        colons++;
      } else if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || c === '.')) {
        return undefined;
      }
    }
    return colons >= 2 ? host : undefined;
  }
  if (host.length > 253 || host.startsWith('.') || host.endsWith('.')) {
    return undefined;
  }
  const labels: string[] = host.split('.');
  const labelPattern = new RegExp(HOSTNAME_LABEL);
  for (const label of labels) {
    if (label.length === 0 || label.length > 63 || !labelPattern.test(label)) {
      return undefined;
    }
  }
  return host;
}

function parseAuthority(authority: string): GatewayOrigin | undefined {
  if (authority.length === 0) {
    return undefined;
  }
  if (authority.indexOf('@') >= 0) {
    return undefined;
  }
  let hostPart: string = authority;
  let portPart: string | undefined = undefined;
  if (authority.startsWith('[')) {
    const close: number = authority.indexOf(']');
    if (close < 0) {
      return undefined;
    }
    hostPart = authority.substring(0, close + 1);
    const remainder: string = authority.substring(close + 1);
    if (remainder.length > 0) {
      if (!remainder.startsWith(':')) {
        return undefined;
      }
      portPart = remainder.substring(1);
    }
  } else {
    const colon: number = authority.indexOf(':');
    if (colon >= 0) {
      hostPart = authority.substring(0, colon);
      portPart = authority.substring(colon + 1);
    }
  }
  const host: string | undefined = canonicalHost(hostPart);
  if (host === undefined) {
    return undefined;
  }
  if (portPart === undefined || portPart.length === 0) {
    return new GatewayOrigin(host, HTTPS_PORT);
  }
  if (!/^[0-9]{1,5}$/.test(portPart)) {
    return undefined;
  }
  const port: number = Number.parseInt(portPart, 10);
  if (port < 1 || port > 65535) {
    return undefined;
  }
  return new GatewayOrigin(host, port);
}

export function parseOrigin(rawValue: string): GatewayOrigin | undefined {
  const split: SplitUrl | undefined = splitUrl(rawValue);
  if (split === undefined) {
    return undefined;
  }
  if (split.scheme !== 'https') {
    return undefined;
  }
  if (split.query !== undefined || split.fragment !== undefined) {
    return undefined;
  }
  if (split.path.length > 0 && split.path !== '/') {
    return undefined;
  }
  return parseAuthority(split.authority);
}

function originFromCandidate(split: SplitUrl): GatewayOrigin | undefined {
  if (split.scheme !== 'https') {
    return undefined;
  }
  return parseAuthority(split.authority);
}

/** Accepts a bare origin or the plugin's fixed one-time pairing URL. */
export function parseConnection(rawValue: string): GatewayConnection | undefined {
  const direct: GatewayOrigin | undefined = parseOrigin(rawValue);
  if (direct !== undefined) {
    return new GatewayConnection(direct, direct.serialized());
  }
  const split: SplitUrl | undefined = splitUrl(rawValue);
  if (split === undefined) {
    return undefined;
  }
  if (split.scheme !== 'https' || split.query !== undefined || split.path !== PAIR_PATH) {
    return undefined;
  }
  if (split.fragment !== undefined && !new RegExp(PAIR_FRAGMENT).test(split.fragment)) {
    return undefined;
  }
  const origin: GatewayOrigin | undefined = originFromCandidate(split);
  if (origin === undefined) {
    return undefined;
  }
  let initialUrl: string = origin.serialized() + PAIR_PATH;
  if (split.fragment !== undefined) {
    initialUrl = `${initialUrl}#${split.fragment}`;
  }
  return new GatewayConnection(origin, initialUrl);
}

/** Default port for an address typed without one: the LAN listener runs on 3443, public entries on 443. */
export function defaultPortForHost(host: string): number {
  return isPrivateNetworkHost(host) ? DEFAULT_GATEWAY_PORT : HTTPS_PORT;
}

/** Whether the authority part already carries a port, so a missing one is the only thing defaulted. */
function authorityHasPort(authority: string): boolean {
  if (authority.startsWith('[')) {
    const close: number = authority.indexOf(']');
    return close >= 0 && authority.substring(close + 1).startsWith(':');
  }
  return authority.indexOf(':') >= 0;
}

/**
 * Parses the manual `host[:port]` field.
 *
 * A typed address carries no scheme and often no port, and the missing port cannot default to a
 * single number: the plugin's LAN listener is 3443 while every supported public tunnel serves 443.
 * Guessing the LAN port for a tunnel hostname looks exactly like "remote does not work" (the
 * connection simply times out), so the default follows the entry type. An explicit port is never
 * rewritten, including the unusual `192.168.1.10:443`.
 */
export function parseManualAddress(rawValue: string): GatewayOrigin | undefined {
  const trimmed: string = rawValue.trim();
  if (trimmed.length === 0) {
    return undefined;
  }
  const candidate: string = trimmed.indexOf('://') >= 0 ? trimmed : `https://${trimmed}`;
  const origin: GatewayOrigin | undefined = parseOrigin(candidate);
  const split: SplitUrl | undefined = splitUrl(candidate);
  if (origin === undefined || split === undefined) {
    return undefined;
  }
  if (authorityHasPort(split.authority)) {
    return origin;
  }
  return new GatewayOrigin(origin.host, defaultPortForHost(origin.host));
}

/** Returns whether an absolute candidate URL has exactly the configured origin. */
export function isSameOrigin(origin: GatewayOrigin, rawCandidate: string): boolean {
  const split: SplitUrl | undefined = splitUrl(rawCandidate);
  if (split === undefined) {
    return false;
  }
  const candidate: GatewayOrigin | undefined = originFromCandidate(split);
  return candidate !== undefined && candidate.equals(origin);
}

/**
 * Whether a URL addresses the pinned gateway over the secure scheme family.
 *
 * ArkWeb reports WebSocket certificate failures with a `wss:` URL while the pinned origin is
 * canonicalized as `https:`, so only the scheme may differ: host and port must match exactly.
 */
export function isPinnedAuthority(origin: GatewayOrigin, rawCandidate: string): boolean {
  const split: SplitUrl | undefined = splitUrl(rawCandidate);
  if (split === undefined) {
    return false;
  }
  if (split.scheme !== 'https' && split.scheme !== 'wss') {
    return false;
  }
  const candidate: GatewayOrigin | undefined = parseAuthority(split.authority);
  if (candidate === undefined) {
    return false;
  }
  const candidatePort: number = candidate.port;
  return candidate.host === origin.host && candidatePort === origin.port;
}

/** Returns whether a URL may be handed to an external browser (HTTPS only). */
export function isExternalHttps(rawCandidate: string): boolean {
  const split: SplitUrl | undefined = splitUrl(rawCandidate);
  if (split === undefined) {
    return false;
  }
  return originFromCandidate(split) !== undefined;
}

export function isIpv4Literal(host: string): boolean {
  return isValidIpv4(host);
}

/** Loopback, ULA and link-local IPv6 are reachable only from a local path, never from the internet. */
function isPrivateIpv6(host: string): boolean {
  const value: string = host.toLowerCase();
  if (value === '::1') {
    return true;
  }
  if (value.startsWith('fc') || value.startsWith('fd')) {
    return true;
  }
  return value.startsWith('fe8') || value.startsWith('fe9')
    || value.startsWith('fea') || value.startsWith('feb');
}

/** Whether the host is a loopback or private LAN address (used for timeouts and labelling). */
export function isPrivateNetworkHost(host: string): boolean {
  if (host === 'localhost') {
    return true;
  }
  if (host.indexOf(':') >= 0) {
    return isPrivateIpv6(host);
  }
  if (!isValidIpv4(host)) {
    return false;
  }
  const parts: string[] = host.split('.');
  const first: number = Number.parseInt(parts[0], 10);
  const second: number = Number.parseInt(parts[1], 10);
  if (first === 127 || first === 10) {
    return true;
  }
  if (first === 192 && second === 168) {
    return true;
  }
  if (first === 172 && second >= 16 && second <= 31) {
    return true;
  }
  if (first === 100 && second >= 64 && second <= 127) {
    return true;
  }
  return false;
}
