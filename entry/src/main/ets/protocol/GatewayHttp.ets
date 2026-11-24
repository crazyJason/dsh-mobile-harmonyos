/**
 * Native pairing, renewal and reachability calls against the DSH Mobile gateway.
 *
 * Response handling is deliberately strict: every field is bounded and cross-checked against the
 * origin and the expected DSH instance, so a compromised or confused gateway cannot hand the app a
 * session for a different computer.
 */
import { util } from '@kit.ArkTS';
import { Log } from '../common/Log';
import { GatewayOrigin, isPrivateNetworkHost } from './Origin';
import { derToPem, INSTANCE_ID_PATTERN } from './CertPin';
import { AuthFailure, AuthFailureKind, failureForStatus } from './AuthFailure';
import { tlsRequest, TlsRequestOptions, TlsResponse } from './TlsHttp';
import { JsonObject, parseJsonObject, readNumber, readString, keyCount, hasKey } from '../common/Json';

export const MAX_NATIVE_AUTH_RESPONSE_BYTES: number = 32 * 1024;
const MAX_NATIVE_ERROR_BYTES: number = 8 * 1024;
const DEVICE_ID_PATTERN: RegExp = new RegExp('^[a-f0-9]{32}$');
const OPAQUE_TOKEN_PATTERN: RegExp = new RegExp('^[A-Za-z0-9_-]{43}$');
const JSON_PREFIX: string = 'application/json';

/** Keeps LAN failures fast while allowing mobile networks and relays enough time to respond. */
class Timeouts {
  readonly connectMs: number;
  readonly readMs: number;

  constructor(connectMs: number, readMs: number) {
    this.connectMs = connectMs;
    this.readMs = readMs;
  }

  total(): number {
    return this.connectMs + this.readMs;
  }
}

function bootstrapTimeouts(origin: GatewayOrigin): Timeouts {
  return isPrivateNetworkHost(origin.host) ? new Timeouts(500, 1500) : new Timeouts(3000, 5000);
}

function authTimeouts(origin: GatewayOrigin): Timeouts {
  return isPrivateNetworkHost(origin.host) ? new Timeouts(3000, 5000) : new Timeouts(10000, 30000);
}

export class NativeSession {
  readonly origin: GatewayOrigin;
  readonly instanceId: string;
  readonly deviceId: string;
  readonly deviceToken: string | undefined;
  readonly deviceExpiresAt: number | undefined;
  readonly sessionToken: string;
  readonly csrfToken: string;
  readonly sessionExpiresAt: number;
  readonly installationId: string | undefined;

  constructor(origin: GatewayOrigin, instanceId: string, deviceId: string, deviceToken: string | undefined,
    deviceExpiresAt: number | undefined, sessionToken: string, csrfToken: string, sessionExpiresAt: number,
    installationId: string | undefined) {
    this.origin = origin;
    this.instanceId = instanceId;
    this.deviceId = deviceId;
    this.deviceToken = deviceToken;
    this.deviceExpiresAt = deviceExpiresAt;
    this.sessionToken = sessionToken;
    this.csrfToken = csrfToken;
    this.sessionExpiresAt = sessionExpiresAt;
    this.installationId = installationId;
  }
}

export class NativeProbe {
  readonly instanceId: string;
  readonly deviceId: string;
  readonly deviceExpiresAt: number;
  readonly installationId: string | undefined;

  constructor(instanceId: string, deviceId: string, deviceExpiresAt: number, installationId: string | undefined) {
    this.instanceId = instanceId;
    this.deviceId = deviceId;
    this.deviceExpiresAt = deviceExpiresAt;
    this.installationId = installationId;
  }
}

export class GatewayDiscovery {
  readonly deviceName: string;
  readonly origin: GatewayOrigin;
  readonly instanceId: string;

  constructor(deviceName: string, origin: GatewayOrigin, instanceId: string) {
    this.deviceName = deviceName;
    this.origin = origin;
    this.instanceId = instanceId;
  }
}

export class GatewayMetadata {
  readonly version: number;
  readonly pluginVersion: string;
  readonly minimumAppVersion: string;
  readonly discoveryProtocol: number;

  constructor(version: number, pluginVersion: string, minimumAppVersion: string, discoveryProtocol: number) {
    this.version = version;
    this.pluginVersion = pluginVersion;
    this.minimumAppVersion = minimumAppVersion;
    this.discoveryProtocol = discoveryProtocol;
  }
}

function invalidResponse(): AuthFailure {
  return new AuthFailure(AuthFailureKind.INVALID_RESPONSE, 'unexpected gateway response');
}

function isJson(response: TlsResponse): boolean {
  return response.contentType().startsWith(JSON_PREFIX);
}

function errorCodeOf(response: TlsResponse): string | undefined {
  if (response.body.length === 0 || response.body.length > MAX_NATIVE_ERROR_BYTES) {
    return undefined;
  }
  const parsed: JsonObject | undefined = parseJsonObject(response.text());
  if (parsed === undefined) {
    return undefined;
  }
  const code: string | undefined = readString(parsed, 'error');
  return code !== undefined && code.length >= 1 && code.length <= 64 ? code : undefined;
}

function throwForStatus(response: TlsResponse): void {
  const kind: AuthFailureKind = failureForStatus(response.status, errorCodeOf(response));
  throw new AuthFailure(kind, `gateway answered HTTP ${response.status}`);
}

function requiredString(source: JsonObject, name: string, pattern: RegExp): string {
  const value: string | undefined = readString(source, name);
  if (value === undefined || !pattern.test(value)) {
    throw invalidResponse();
  }
  return value;
}

function requiredFutureEpoch(source: JsonObject, name: string, now: number): number {
  const value: number | undefined = readNumber(source, name);
  if (value === undefined || !Number.isFinite(value) || !Number.isInteger(value) || value <= now) {
    throw invalidResponse();
  }
  return value;
}

function optionalInstallationId(source: JsonObject): string | undefined {
  if (!hasKey(source, 'installationId')) {
    return undefined;
  }
  return requiredString(source, 'installationId', INSTANCE_ID_PATTERN);
}

/** Whether the response carries exactly the expected keys plus the optional installation hint. */
function hasExactKeys(source: JsonObject, expected: string[]): boolean {
  for (const key of expected) {
    if (!hasKey(source, key)) {
      return false;
    }
  }
  const actual: number = keyCount(source) - (hasKey(source, 'installationId') ? 1 : 0);
  return actual === expected.length;
}

function sessionBody(source: JsonObject, expectedInstanceId: string, requireDeviceCredential: boolean,
  origin: GatewayOrigin): NativeSession {
  const now: number = Date.now();
  const instanceId: string = requiredString(source, 'instanceId', INSTANCE_ID_PATTERN);
  if (instanceId !== expectedInstanceId) {
    throw invalidResponse();
  }
  const deviceId: string = requiredString(source, 'deviceId', DEVICE_ID_PATTERN);
  const sessionToken: string = requiredString(source, 'sessionToken', OPAQUE_TOKEN_PATTERN);
  const csrfToken: string = requiredString(source, 'csrfToken', OPAQUE_TOKEN_PATTERN);
  const sessionExpiresAt: number = requiredFutureEpoch(source, 'sessionExpiresAt', now);
  let deviceToken: string | undefined = undefined;
  let deviceExpiresAt: number | undefined = undefined;
  if (requireDeviceCredential) {
    deviceToken = requiredString(source, 'deviceToken', OPAQUE_TOKEN_PATTERN);
    deviceExpiresAt = requiredFutureEpoch(source, 'deviceExpiresAt', now);
    if (deviceExpiresAt < sessionExpiresAt) {
      throw invalidResponse();
    }
  }
  return new NativeSession(origin, instanceId, deviceId, deviceToken, deviceExpiresAt, sessionToken, csrfToken,
    sessionExpiresAt, optionalInstallationId(source));
}

function parseSession(response: TlsResponse, origin: GatewayOrigin, expectedInstanceId: string,
  requireDeviceCredential: boolean): NativeSession {
  if (!INSTANCE_ID_PATTERN.test(expectedInstanceId) || !isJson(response)
    || response.body.length > MAX_NATIVE_AUTH_RESPONSE_BYTES) {
    throw invalidResponse();
  }
  const parsed: JsonObject | undefined = parseJsonObject(response.text());
  if (parsed === undefined) {
    throw invalidResponse();
  }
  const expected: string[] = requireDeviceCredential
    ? ['instanceId', 'deviceId', 'deviceToken', 'deviceExpiresAt', 'sessionToken', 'csrfToken', 'sessionExpiresAt']
    : ['instanceId', 'deviceId', 'sessionToken', 'csrfToken', 'sessionExpiresAt'];
  if (!hasExactKeys(parsed, expected)) {
    throw invalidResponse();
  }
  return sessionBody(parsed, expectedInstanceId, requireDeviceCredential, origin);
}

function parseProbe(response: TlsResponse, expectedInstanceId: string): NativeProbe {
  if (!INSTANCE_ID_PATTERN.test(expectedInstanceId) || !isJson(response)
    || response.body.length > MAX_NATIVE_AUTH_RESPONSE_BYTES) {
    throw invalidResponse();
  }
  const parsed: JsonObject | undefined = parseJsonObject(response.text());
  if (parsed === undefined || !hasExactKeys(parsed, ['instanceId', 'deviceId', 'deviceExpiresAt'])) {
    throw invalidResponse();
  }
  const instanceId: string = requiredString(parsed, 'instanceId', INSTANCE_ID_PATTERN);
  if (instanceId !== expectedInstanceId) {
    throw invalidResponse();
  }
  const deviceId: string = requiredString(parsed, 'deviceId', DEVICE_ID_PATTERN);
  const deviceExpiresAt: number = requiredFutureEpoch(parsed, 'deviceExpiresAt', Date.now());
  return new NativeProbe(instanceId, deviceId, deviceExpiresAt, optionalInstallationId(parsed));
}

function jsonHeaders(origin: GatewayOrigin): Map<string, string> {
  const headers: Map<string, string> = new Map<string, string>();
  headers.set('content-type', 'application/json');
  headers.set('accept', 'application/json');
  headers.set('x-dsh-mobile-capabilities', 'installation-id');
  headers.set('origin', origin.serialized());
  headers.set('sec-fetch-site', 'same-origin');
  return headers;
}

function jsonBytes(value: string): Uint8Array {
  return new util.TextEncoder('utf-8').encodeInto(value);
}

/** Builds one small JSON body without relying on a structural cast of an object literal. */
function jsonPair(firstName: string, firstValue: string, secondName: string, secondValue: string): string {
  return `{"${firstName}":${JSON.stringify(firstValue)},"${secondName}":${JSON.stringify(secondValue)}}`;
}

function jsonSingle(name: string, value: string): string {
  return `{"${name}":${JSON.stringify(value)}}`;
}

export class GatewayClient {
  /** Downloads the pairing CA; `undefined` means an explicit 404 (public-trust entry). */
  static async fetchPairingCa(origin: GatewayOrigin): Promise<Uint8Array | undefined> {
    const timeouts: Timeouts = bootstrapTimeouts(origin);
    const response: TlsResponse = await tlsRequest(origin, 'GET', '/mobile-access/ca.cer',
      TlsRequestOptions.bootstrap(timeouts.total()), undefined, new Map<string, string>());
    if (response.status === 404) {
      return undefined;
    }
    if (response.status !== 200) {
      throwForStatus(response);
    }
    if (response.body.length === 0 || response.body.length > 16 * 1024) {
      throw invalidResponse();
    }
    return response.body;
  }

  /** Untrusted compatibility metadata; only used to report discovery results before pairing. */
  static async fetchDiscovery(origin: GatewayOrigin): Promise<GatewayDiscovery | undefined> {
    const timeouts: Timeouts = bootstrapTimeouts(origin);
    const response: TlsResponse = await tlsRequest(origin, 'GET', '/mobile-access/discovery',
      TlsRequestOptions.bootstrap(timeouts.total()), undefined, new Map<string, string>());
    if (response.status !== 200) {
      return undefined;
    }
    const parsed: JsonObject | undefined = parseJsonObject(response.text());
    if (parsed === undefined || keyCount(parsed) !== 5) {
      return undefined;
    }
    const protocol: number | undefined = readNumber(parsed, 'protocol');
    const instanceId: string | undefined = readString(parsed, 'instanceId');
    const deviceName: string | undefined = readString(parsed, 'deviceName');
    const advertised: string | undefined = readString(parsed, 'origin');
    const port: number | undefined = readNumber(parsed, 'port');
    if (protocol === undefined || protocol !== 1 || instanceId === undefined
      || !INSTANCE_ID_PATTERN.test(instanceId) || deviceName === undefined || deviceName.length === 0
      || deviceName.length > 63 || advertised === undefined || port === undefined) {
      return undefined;
    }
    if (port !== origin.port || advertised !== origin.serialized()) {
      return undefined;
    }
    return new GatewayDiscovery(deviceName, origin, instanceId);
  }

  /** Optional compatibility metadata; a 404 means a legacy gateway. */
  static async fetchMetadata(origin: GatewayOrigin, pinnedCaDer: Uint8Array): Promise<GatewayMetadata | undefined> {
    const timeouts: Timeouts = bootstrapTimeouts(origin);
    const response: TlsResponse = await tlsRequest(origin, 'GET', '/mobile-access/metadata',
      TlsRequestOptions.pinned(timeouts.total(), derToPem(pinnedCaDer)), undefined, new Map<string, string>());
    if (response.status === 404) {
      return undefined;
    }
    if (response.status !== 200) {
      throwForStatus(response);
    }
    const parsed: JsonObject | undefined = parseJsonObject(response.text());
    if (parsed === undefined) {
      return undefined;
    }
    const version: number | undefined = readNumber(parsed, 'version');
    const pluginVersion: string | undefined = readString(parsed, 'pluginVersion');
    const minimumApp: string | undefined = readString(parsed, 'minimumAndroidAppVersion');
    const protocol: number | undefined = readNumber(parsed, 'discoveryProtocol');
    if (version === undefined || version < 1 || pluginVersion === undefined || pluginVersion.length === 0
      || pluginVersion.length > 64 || minimumApp === undefined || minimumApp.length === 0
      || minimumApp.length > 64 || protocol === undefined || protocol < 1) {
      return undefined;
    }
    return new GatewayMetadata(version, pluginVersion, minimumApp, protocol);
  }

  static async pair(origin: GatewayOrigin, token: string, label: string, pinnedCaDer: Uint8Array,
    expectedInstanceId: string): Promise<NativeSession> {
    const timeouts: Timeouts = authTimeouts(origin);
    const payload: string = jsonPair('token', token, 'label', label);
    const response: TlsResponse = await tlsRequest(origin, 'POST', '/mobile-access/auth/native-pair',
      TlsRequestOptions.pinned(timeouts.total(), derToPem(pinnedCaDer)), jsonBytes(payload), jsonHeaders(origin));
    if (response.status < 200 || response.status > 299) {
      throwForStatus(response);
    }
    return parseSession(response, origin, expectedInstanceId, true);
  }

  static async renew(origin: GatewayOrigin, deviceToken: string, pinnedCaDer: Uint8Array,
    expectedInstanceId: string): Promise<NativeSession> {
    const timeouts: Timeouts = authTimeouts(origin);
    const payload: string = jsonSingle('deviceToken', deviceToken);
    const response: TlsResponse = await tlsRequest(origin, 'POST', '/mobile-access/auth/native-renew',
      TlsRequestOptions.pinned(timeouts.total(), derToPem(pinnedCaDer)), jsonBytes(payload), jsonHeaders(origin));
    if (response.status < 200 || response.status > 299) {
      throwForStatus(response);
    }
    return parseSession(response, origin, expectedInstanceId, false);
  }

  static async probe(origin: GatewayOrigin, deviceToken: string, pinnedCaDer: Uint8Array,
    expectedInstanceId: string): Promise<NativeProbe> {
    const timeouts: Timeouts = authTimeouts(origin);
    const payload: string = jsonSingle('deviceToken', deviceToken);
    const response: TlsResponse = await tlsRequest(origin, 'POST', '/mobile-access/auth/native-probe',
      TlsRequestOptions.pinned(timeouts.total(), derToPem(pinnedCaDer)), jsonBytes(payload), jsonHeaders(origin));
    if (response.status < 200 || response.status > 299) {
      throwForStatus(response);
    }
    return parseProbe(response, expectedInstanceId);
  }

  /** Public-CA remote entry: the platform trust store validates the gateway certificate. */
  static async pairWithSystemTrust(origin: GatewayOrigin, token: string, label: string,
    expectedInstanceId: string): Promise<NativeSession> {
    const timeouts: Timeouts = authTimeouts(origin);
    const payload: string = jsonPair('token', token, 'label', label);
    const response: TlsResponse = await tlsRequest(origin, 'POST', '/mobile-access/auth/native-pair',
      TlsRequestOptions.system(timeouts.total()), jsonBytes(payload), jsonHeaders(origin));
    if (response.status < 200 || response.status > 299) {
      throwForStatus(response);
    }
    return parseSession(response, origin, expectedInstanceId, true);
  }

  static async renewWithSystemTrust(origin: GatewayOrigin, deviceToken: string,
    expectedInstanceId: string): Promise<NativeSession> {
    const timeouts: Timeouts = authTimeouts(origin);
    const payload: string = jsonSingle('deviceToken', deviceToken);
    const response: TlsResponse = await tlsRequest(origin, 'POST', '/mobile-access/auth/native-renew',
      TlsRequestOptions.system(timeouts.total()), jsonBytes(payload), jsonHeaders(origin));
    if (response.status < 200 || response.status > 299) {
      throwForStatus(response);
    }
    return parseSession(response, origin, expectedInstanceId, false);
  }

  static async probeWithSystemTrust(origin: GatewayOrigin, deviceToken: string,
    expectedInstanceId: string): Promise<NativeProbe> {
    const timeouts: Timeouts = authTimeouts(origin);
    const payload: string = jsonSingle('deviceToken', deviceToken);
    const response: TlsResponse = await tlsRequest(origin, 'POST', '/mobile-access/auth/native-probe',
      TlsRequestOptions.system(timeouts.total()), jsonBytes(payload), jsonHeaders(origin));
    if (response.status < 200 || response.status > 299) {
      throwForStatus(response);
    }
    return parseProbe(response, expectedInstanceId);
  }
}

/** Converts any thrown value into a classified failure without leaking transport details. */
export function asAuthFailure(error: Object): AuthFailure {
  if (error instanceof AuthFailure) {
    return error;
  }
  Log.warn('unclassified gateway failure');
  return new AuthFailure(AuthFailureKind.NETWORK, 'gateway transport failure');
}
