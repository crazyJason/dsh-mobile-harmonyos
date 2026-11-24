/**
 * Device-side protocol self-check.
 *
 * These are the pure parsing and validation rules the client depends on. Running them on the phone
 * proves the installed build enforces the same protocol contract as the desktop plugin without
 * needing a reachable computer, which makes "it installs but misbehaves" diagnosable.
 */
import { parseConnection, parseOrigin, isSameOrigin, isPinnedAuthority } from '../protocol/Origin';
import { parsePairingKey, pairingKeyFromUrl } from '../protocol/PairingKey';

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

  return result;
}
