/**
 * Certificate identity for the DSH Mobile gateway.
 *
 * The gateway publishes its self-signed pairing CA at `/mobile-access/ca.cer`. The pairing key
 * carries `instanceId`, which is the SHA-256 of that DER certificate, so the phone can check that
 * the CA it downloaded is exactly the one the desktop meant to give it. Every later request pins
 * that CA as its TLS trust anchor instead of relying on the platform trust store.
 */
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { cert } from '@kit.DeviceCertificateKit';
import { Log } from '../common/Log';

export const INSTANCE_ID_PATTERN: RegExp = new RegExp('^[a-f0-9]{64}$');

/** SHA-256 of the DER bytes as lowercase hex; the gateway's `instanceId` format. */
export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
  const blob: cryptoFramework.DataBlob = { data: bytes };
  await md.update(blob);
  const digestBlob: cryptoFramework.DataBlob = await md.digest();
  const digest: Uint8Array = digestBlob.data;
  let hex: string = '';
  for (let index = 0; index < digest.length; index++) {
    const value: number = digest[index] & 0xff;
    hex += (value < 16 ? '0' : '') + value.toString(16);
  }
  return hex;
}

/** Wraps DER bytes in a PEM certificate block accepted by the network stack. */
export function derToPem(der: Uint8Array): string {
  const base64: string = new util.Base64Helper().encodeToStringSync(der);
  let body: string = '';
  let cursor: number = 0;
  while (cursor < base64.length) {
    const end: number = Math.min(cursor + 64, base64.length);
    body += base64.substring(cursor, end);
    if (end < base64.length) {
      body += '\n';
    }
    cursor = end;
  }
  return `-----BEGIN CERTIFICATE-----\n${body}\n-----END CERTIFICATE-----\n`;
}

/** Strips an optional PEM wrapper so both wire formats can be stored the same way. */
export function pemToDer(pem: string): Uint8Array | undefined {
  try {
    const begin: string = '-----BEGIN CERTIFICATE-----';
    const end: string = '-----END CERTIFICATE-----';
    const startAt: number = pem.indexOf(begin);
    const endAt: number = pem.indexOf(end);
    if (startAt < 0 || endAt <= startAt) {
      return undefined;
    }
    const base64: string = pem.substring(startAt + begin.length, endAt).replace(new RegExp('\\s', 'g'), '');
    if (base64.length === 0) {
      return undefined;
    }
    return new util.Base64Helper().decodeSync(base64);
  } catch (error) {
    return undefined;
  }
}

/**
 * Parses an X.509 validity timestamp.
 *
 * `checkValidityWithDate` only accepts ASN.1 time text (UTCTime `YYMMDDHHMMSSZ` or
 * GeneralizedTime `YYYYMMDDHHMMSSZ`), never ISO-8601, so the bounds are compared here instead.
 */
export function parseAsn1Time(value: string): number | undefined {
  const match: RegExpMatchArray | null = value.trim().match(/^([0-9]{2}|[0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})Z$/);
  if (match === null) {
    return undefined;
  }
  let year: number = Number.parseInt(match[1], 10);
  if (match[1].length === 2) {
    year = year >= 50 ? 1900 + year : 2000 + year;
  }
  const month: number = Number.parseInt(match[2], 10);
  const day: number = Number.parseInt(match[3], 10);
  const hour: number = Number.parseInt(match[4], 10);
  const minute: number = Number.parseInt(match[5], 10);
  const second: number = Number.parseInt(match[6], 10);
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 60) {
    return undefined;
  }
  return Date.UTC(year, month - 1, day, hour, minute, Math.min(second, 59));
}

/** Whether the certificate is currently within its validity window. */
function isWithinValidity(parsed: cert.X509Cert): boolean {
  const notBefore: number | undefined = parseAsn1Time(parsed.getNotBeforeTime());
  const notAfter: number | undefined = parseAsn1Time(parsed.getNotAfterTime());
  if (notBefore === undefined || notAfter === undefined) {
    return false;
  }
  const now: number = Date.now();
  return now >= notBefore && now <= notAfter;
}

async function loadCertificate(der: Uint8Array): Promise<cert.X509Cert | undefined> {
  try {
    const blob: cert.EncodingBlob = { data: der, encodingFormat: cert.EncodingFormat.FORMAT_DER };
    return await cert.createX509Cert(blob);
  } catch (error) {
    return undefined;
  }
}

/**
 * Validates that a downloaded certificate is the self-signed, currently valid CA whose SHA-256
 * fingerprint equals the pairing key's instance id. Returns the DER bytes on success.
 */
export async function validatePairingCa(der: Uint8Array, instanceId: string): Promise<Uint8Array | undefined> {
  if (!INSTANCE_ID_PATTERN.test(instanceId)) {
    return undefined;
  }
  const fingerprint: string = await sha256Hex(der);
  if (fingerprint !== instanceId) {
    Log.warn('pairing CA fingerprint does not match the pairing key');
    return undefined;
  }
  const parsed: cert.X509Cert | undefined = await loadCertificate(der);
  if (parsed === undefined) {
    Log.warn('pairing CA: the served bytes are not a parseable X.509 certificate');
    return undefined;
  }
  try {
    // A pairing CA must be verifiable with its own key, and its fingerprint must equal the pairing
    // key's instance id, which is what binds it to the computer the desktop showed.
    //
    // `getBasicConstraints()` returns the path length, and HarmonyOS returns -1 for a CA certificate
    // that has CA:TRUE but omits the optional path-length field (verified on a Mate 60 Pro+ /
    // HarmonyOS 7). Treating -1 as "not a CA" rejects every gateway whose CA leaves that field out,
    // which is what the dsh-mobile plugin generates, so the extension is logged instead of gated:
    // the trust anchor is the fingerprint, and a non-CA anchor cannot complete a handshake anyway.
    const basicConstraints: number = parsed.getBasicConstraints();
    const withinValidity: boolean = isWithinValidity(parsed);
    Log.info(`pairing CA: basicConstraints=${basicConstraints} notBefore=${parsed.getNotBeforeTime()} ` +
      `notAfter=${parsed.getNotAfterTime()} withinValidity=${withinValidity}`);
    if (!withinValidity) {
      Log.warn('pairing CA: outside its validity window');
      return undefined;
    }
    const publicKey: cryptoFramework.PubKey = parsed.getPublicKey();
    await parsed.verify(publicKey);
    return der;
  } catch (error) {
    Log.warn('pairing CA validation failed');
    return undefined;
  }
}

/**
 * Verifies a served TLS chain against a pinned CA without consulting the platform trust store.
 * Used when the web container reports an SSL error for the paired gateway.
 */
export async function chainMatchesPinnedCa(chainDer: Uint8Array[], pinnedCaDer: Uint8Array,
  instanceId: string): Promise<boolean> {
  const pinnedFingerprint: string = await sha256Hex(pinnedCaDer);
  if (pinnedFingerprint !== instanceId) {
    return false;
  }
  if (chainDer.length === 0) {
    return false;
  }
  const ca: cert.X509Cert | undefined = await loadCertificate(pinnedCaDer);
  if (ca === undefined) {
    return false;
  }
  const leaf: cert.X509Cert | undefined = await loadCertificate(chainDer[0]);
  if (leaf === undefined) {
    return false;
  }
  try {
    await leaf.verify(ca.getPublicKey());
    return true;
  } catch (error) {
    return false;
  }
}

/** Whether any certificate in a served chain is byte-identical to the pinned CA. */
export async function chainContainsPinnedCa(chainDer: Uint8Array[], instanceId: string): Promise<boolean> {
  for (const entry of chainDer) {
    const fingerprint: string = await sha256Hex(entry);
    if (fingerprint === instanceId) {
      return true;
    }
  }
  return false;
}
