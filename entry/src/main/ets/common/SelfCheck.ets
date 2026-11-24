/**
 * Device-side protocol self-check.
 *
 * These are the pure parsing and validation rules the client depends on. Running them on the phone
 * proves the installed build enforces the same protocol contract as the desktop plugin without
 * needing a reachable computer, which makes "it installs but misbehaves" diagnosable.
 */
import {
  parseConnection, parseOrigin, isSameOrigin, isPinnedAuthority, isPrivateNetworkHost, parseManualAddress
} from '../protocol/Origin';
import { PairingTarget, parsePairingKey, pairingKeyFromUrl, preserveRemotePin } from '../protocol/PairingKey';
import { parseAsn1Time } from '../protocol/CertPin';
import { PairingInput, interpretPairingInput } from '../service/AppService';

export class SelfCheckResult {
  readonly passed: string[];
  readonly failed: string[];
  readonly skipped: string[];

  constructor(passed: string[], failed: string[], skipped: string[]) {
    this.passed = passed;
    this.failed = failed;
    this.skipped = skipped;
  }

  ok(): boolean {
    return this.failed.length === 0;
  }
}

const INSTANCE: string = 'a'.repeat(64);
const TOKEN: string = 'b'.repeat(43);

function check(name: string, condition: boolean, result: SelfCheckResult): void {
  if (condition) {
    result.passed.push(name);
  } else {
    result.failed.push(name);
  }
}

export function runSelfCheck(): SelfCheckResult {
  const result: SelfCheckResult = new SelfCheckResult([], [], []);
  const origin = parseOrigin('https://192.168.1.20:3443');
  check('接受 HTTPS 局域网来源', origin !== undefined && origin.host === '192.168.1.20' && origin.port === 3443, result);
  check('拒绝明文 HTTP', parseOrigin('http://192.168.1.20:3443') === undefined, result);
  check('拒绝带路径的来源', parseOrigin('https://192.168.1.20:3443/admin') === undefined, result);
  check('拒绝带查询串的来源', parseOrigin('https://192.168.1.20:3443/?x=1') === undefined, result);
  check('拒绝带凭据的来源', parseOrigin('https://user:pass@192.168.1.20:3443') === undefined, result);
  check('缺省端口为 443', (parseOrigin('https://example.com')?.port ?? 0) === 443, result);
  check('同源判定包含端口', origin !== undefined && isSameOrigin(origin, 'https://192.168.1.20:3443/api') === true
    && isSameOrigin(origin, 'https://192.168.1.20:3444/api') === false, result);
  check('wss 与 https 同授权', origin !== undefined && isPinnedAuthority(origin, 'wss://192.168.1.20:3443/api') === true, result);

  // The manual field has no scheme and often no port. Defaulting a tunnel hostname to the LAN port
  // is the failure mode that looks like "remote is broken" (it just times out), and the entry-type
  // split it follows also decides timeouts and whether a missing CA is fatal, so both are exercised.
  check('公网主机名默认 443', parseManualAddress('dsh.example.com')?.port === 443, result);
  check('局域网地址默认 3443', parseManualAddress('192.168.1.10')?.port === 3443, result);
  check('显式端口不被改写', parseManualAddress('192.168.1.10:443')?.port === 443, result);
  check('172.20 与 100.64 属于局域网',
    isPrivateNetworkHost('172.20.1.5') && isPrivateNetworkHost('100.64.0.7'), result);
  check('IPv6 私网属于局域网', isPrivateNetworkHost('::1') && isPrivateNetworkHost('fd00::1'), result);
  check('公网主机名属于远程', !isPrivateNetworkHost('dsh.example.com'), result);

  const dsh2Key = `dsh2.${INSTANCE}.${TOKEN}`;
  const dsh1Key = `dsh1.${INSTANCE}.${TOKEN}`;
  check('解析 dsh2 密钥并要求 CA', parsePairingKey(dsh2Key)?.requiresCa === true, result);
  check('解析 dsh1 密钥且不要求 CA', parsePairingKey(dsh1Key)?.requiresCa === false, result);
  check('拒绝短实例号', parsePairingKey(`dsh2.${'a'.repeat(63)}.${TOKEN}`) === undefined, result);
  check('拒绝短令牌', parsePairingKey(`dsh2.${INSTANCE}.${'b'.repeat(42)}`) === undefined, result);

  const link = `https://192.168.1.20:3443/mobile-access/pair#key=${dsh2Key}`;
  const connection = parseConnection(link);
  check('解析配对链接', connection !== undefined && connection.origin.host === '192.168.1.20', result);
  const parsedKey = connection === undefined ? undefined : pairingKeyFromUrl(connection.initialUrl);
  check('从链接取出密钥', parsedKey !== undefined && parsedKey.instanceId === INSTANCE, result);
  const legacy = `https://192.168.1.20:3443/mobile-access/pair#instance=${INSTANCE}&token=${TOKEN}`;
  const legacyConnection = parseConnection(legacy);
  check('兼容旧版配对片段', legacyConnection !== undefined, result);
  check('拒绝非配对路径的链接',
    parseConnection(`https://192.168.1.20:3443/other#key=${dsh2Key}`) === undefined, result);

  // Scanning feeds the same resolver as pasting (PROTOCOL §3.4, ADR-0006): a scanned link already
  // carries its origin, a scanned bare key still needs an address, and the LAN/REMOTE label must
  // follow the origin instead of the input channel.
  const scannedLan: PairingInput = interpretPairingInput(`https://192.168.1.20:3443/mobile-access/pair#key=${dsh2Key}`);
  const scannedLanTarget: PairingTarget | undefined = scannedLan.target;
  check('扫码完整链接可直接配对', scannedLanTarget !== undefined && !scannedLanTarget.remote, result);
  const scannedRemote: PairingInput =
    interpretPairingInput(`https://dsh.example.com/mobile-access/pair#instance=${INSTANCE}&token=${TOKEN}`);
  const scannedRemoteTarget: PairingTarget | undefined = scannedRemote.target;
  check('扫码隧道链接判为远程', scannedRemoteTarget !== undefined && scannedRemoteTarget.remote, result);
  const scannedKeyOnly: PairingInput = interpretPairingInput(dsh1Key);
  check('扫码裸密钥仍要求地址', scannedKeyOnly.key !== undefined && scannedKeyOnly.target === undefined, result);

  // Certificate validity timestamps are ASN.1 time, not ISO-8601: a wrong format silently
  // rejects every LAN pairing, so the parser is exercised here.
  check('解析 UTCTime 有效期', parseAsn1Time('250101000000Z') === Date.UTC(2025, 0, 1, 0, 0, 0), result);
  check('解析 GeneralizedTime 有效期', parseAsn1Time('20510101000000Z') === Date.UTC(2051, 0, 1, 0, 0, 0), result);
  check('拒绝非 ASN.1 时间', parseAsn1Time('2025-01-01T00:00:00Z') === undefined, result);
  check('拒绝越界月份', parseAsn1Time('251301000000Z') === undefined, result);

  // Remote downgrade protection (PROTOCOL §3.3 rule 4): a stored CA outranks a key that does not
  // require one, so a stripped dsh1 key cannot move an already pinned remote entry to the platform
  // trust store.
  const noCaKey = parsePairingKey(dsh1Key);
  const caKey = parsePairingKey(dsh2Key);
  check('远程已固定 CA 时拒绝降级',
    noCaKey !== undefined && preserveRemotePin(true, noCaKey, true).requiresCa === true, result);
  check('远程无已存 CA 时允许系统信任',
    noCaKey !== undefined && preserveRemotePin(true, noCaKey, false).requiresCa === false, result);
  check('局域网不启用远程降级保护',
    noCaKey !== undefined && preserveRemotePin(false, noCaKey, true).requiresCa === false, result);
  check('dsh2 密钥始终要求 CA',
    caKey !== undefined && preserveRemotePin(true, caKey, false).requiresCa === true, result);

  return result;
}
