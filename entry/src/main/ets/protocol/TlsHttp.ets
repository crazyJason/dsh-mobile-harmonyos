/**
 * Minimal HTTPS/1.1 client over `TLSSocket`.
 *
 * The DSH Mobile gateway serves its own self-signed pairing CA for LAN (and self-signed FRP)
 * entries, so the app cannot rely on the platform trust store. Speaking TLS directly is the only
 * way to pin that CA on every supported HarmonyOS version:
 *
 *  - pinned requests pass the CA in `secureOptions.ca`, which replaces the trust store;
 *  - bootstrap requests skip remote validation, and the served certificate identity is checked
 *    against the pairing key's fingerprint before any response is trusted.
 *
 * Only the small JSON control calls use this client; page traffic goes through ArkWeb.
 */
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Log';
import { GatewayOrigin } from './Origin';
import { AuthFailure, AuthFailureKind } from './AuthFailure';

const CRLF_CRLF: string = '\r\n\r\n';
const MAX_HEADER_BYTES: number = 16 * 1024;
const MAX_BODY_BYTES: number = 64 * 1024;

export class TlsResponse {
  readonly status: number;
  readonly headers: Map<string, string>;
  readonly body: Uint8Array;

  constructor(status: number, headers: Map<string, string>, body: Uint8Array) {
    this.status = status;
    this.headers = headers;
    this.body = body;
  }

  contentType(): string {
    const value: string | undefined = this.headers.get('content-type');
    return value === undefined ? '' : value.toLowerCase();
  }

  text(): string {
    return util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(this.body);
  }
}

/** How the TLS handshake must authenticate the gateway. */
export enum TrustMode {
  /** Platform trust store: public-CA remote entries. */
  SYSTEM = 'SYSTEM',
  /** Exactly the pinned self-signed pairing CA. */
  PINNED = 'PINNED',
  /** Bootstrap reads only: the response is validated by fingerprint before it is trusted. */
  SKIP = 'SKIP',
}

export class TlsRequestOptions {
  readonly timeoutMs: number;
  readonly mode: TrustMode;
  readonly pinnedCaPem: string | undefined;

  constructor(timeoutMs: number, mode: TrustMode, pinnedCaPem: string | undefined) {
    this.timeoutMs = timeoutMs;
    this.mode = mode;
    this.pinnedCaPem = pinnedCaPem;
  }

  static pinned(timeoutMs: number, pinnedCaPem: string): TlsRequestOptions {
    return new TlsRequestOptions(timeoutMs, TrustMode.PINNED, pinnedCaPem);
  }

  static system(timeoutMs: number): TlsRequestOptions {
    return new TlsRequestOptions(timeoutMs, TrustMode.SYSTEM, undefined);
  }

  static bootstrap(timeoutMs: number): TlsRequestOptions {
    return new TlsRequestOptions(timeoutMs, TrustMode.SKIP, undefined);
  }
}

class ParsedHead {
  readonly status: number;
  readonly headers: Map<string, string>;
  readonly headerBytes: number;

  constructor(status: number, headers: Map<string, string>, headerBytes: number) {
    this.status = status;
    this.headers = headers;
    this.headerBytes = headerBytes;
  }
}

function concat(chunks: Uint8Array[]): Uint8Array {
  let total: number = 0;
  for (const chunk of chunks) {
    total += chunk.length;
  }
  const output: Uint8Array = new Uint8Array(total);
  let offset: number = 0;
  for (const chunk of chunks) {
    output.set(chunk, offset);
    offset += chunk.length;
  }
  return output;
}

function asciiToBytes(text: string): Uint8Array {
  const bytes: Uint8Array = new Uint8Array(text.length);
  for (let index = 0; index < text.length; index++) {
    bytes[index] = text.charCodeAt(index) & 0xff;
  }
  return bytes;
}

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const buffer: ArrayBuffer = new ArrayBuffer(bytes.length);
  new Uint8Array(buffer).set(bytes);
  return buffer;
}

function parseHead(buffer: Uint8Array): ParsedHead | undefined {
  let text: string = '';
  for (let index = 0; index < buffer.length; index++) {
    text += String.fromCharCode(buffer[index]);
  }
  const splitAt: number = text.indexOf(CRLF_CRLF);
  if (splitAt < 0) {
    return undefined;
  }
  const lines: string[] = text.substring(0, splitAt).split('\r\n');
  if (lines.length === 0) {
    return undefined;
  }
  const statusLine: string[] = lines[0].split(' ');
  if (statusLine.length < 2) {
    return undefined;
  }
  const status: number = Number.parseInt(statusLine[1], 10);
  if (!Number.isInteger(status) || status < 100 || status > 599) {
    return undefined;
  }
  const headers: Map<string, string> = new Map<string, string>();
  for (let index = 1; index < lines.length; index++) {
    const line: string = lines[index];
    const colon: number = line.indexOf(':');
    if (colon <= 0) {
      continue;
    }
    headers.set(line.substring(0, colon).trim().toLowerCase(), line.substring(colon + 1).trim());
  }
  return new ParsedHead(status, headers, splitAt + CRLF_CRLF.length);
}

class ChunkResult {
  readonly complete: boolean;
  readonly body: Uint8Array;

  constructor(complete: boolean, body: Uint8Array) {
    this.complete = complete;
    this.body = body;
  }
}

function decodeChunked(rest: Uint8Array): ChunkResult {
  const chunks: Uint8Array[] = [];
  let cursor: number = 0;
  while (cursor < rest.length) {
    let lineEnd: number = -1;
    for (let index = cursor; index + 1 < rest.length; index++) {
      if (rest[index] === 0x0d && rest[index + 1] === 0x0a) {
        lineEnd = index;
        break;
      }
    }
    if (lineEnd < 0) {
      return new ChunkResult(false, new Uint8Array(0));
    }
    let sizeLine: string = '';
    for (let index = cursor; index < lineEnd; index++) {
      sizeLine += String.fromCharCode(rest[index]);
    }
    const semi: number = sizeLine.indexOf(';');
    if (semi >= 0) {
      sizeLine = sizeLine.substring(0, semi);
    }
    const size: number = Number.parseInt(sizeLine.trim(), 16);
    if (!Number.isInteger(size) || size < 0) {
      return new ChunkResult(false, new Uint8Array(0));
    }
    if (size === 0) {
      return new ChunkResult(true, concat(chunks));
    }
    const start: number = lineEnd + 2;
    if (start + size > rest.length) {
      return new ChunkResult(false, new Uint8Array(0));
    }
    chunks.push(rest.slice(start, start + size));
    cursor = start + size + 2;
  }
  return new ChunkResult(false, new Uint8Array(0));
}

function decodeBody(head: ParsedHead, rest: Uint8Array): ChunkResult {
  const encoding: string | undefined = head.headers.get('transfer-encoding');
  if (encoding !== undefined && encoding.toLowerCase().indexOf('chunked') >= 0) {
    return decodeChunked(rest);
  }
  const rawLength: string | undefined = head.headers.get('content-length');
  if (rawLength === undefined) {
    return new ChunkResult(true, rest);
  }
  const length: number = Number.parseInt(rawLength, 10);
  if (!Number.isInteger(length) || length < 0 || length > MAX_BODY_BYTES) {
    return new ChunkResult(false, new Uint8Array(0));
  }
  if (rest.length < length) {
    return new ChunkResult(false, new Uint8Array(0));
  }
  return new ChunkResult(true, rest.slice(0, length));
}

function timeoutFailure(): AuthFailure {
  return new AuthFailure(AuthFailureKind.TIMEOUT, 'gateway request timed out');
}

function transportFailure(cause: string): AuthFailure {
  return new AuthFailure(AuthFailureKind.NETWORK, cause);
}

/** Handshake rejections are TLS failures; everything else is a network failure. */
function classifySocketError(error: BusinessError): AuthFailure {
  const code: number = error.code;
  if (code === 2303501 || code === 2303502 || code === 2303503 || code === 2303505) {
    return new AuthFailure(AuthFailureKind.TLS, 'gateway TLS failure');
  }
  if (code === 2303210) {
    return new AuthFailure(AuthFailureKind.TIMEOUT, 'gateway connect timed out');
  }
  return new AuthFailure(AuthFailureKind.NETWORK, 'gateway transport failure');
}

function buildHead(origin: GatewayOrigin, method: string, path: string, bodyLength: number,
  headers: Map<string, string>): string {
  const hostHeader: string = origin.port === 443 ? origin.host : `${origin.host}:${origin.port}`;
  let head: string = `${method} ${path} HTTP/1.1\r\nHost: ${hostHeader}\r\nConnection: close\r\n`;
  headers.forEach((value: string, name: string) => {
    head += `${name}: ${value}\r\n`;
  });
  head += `Content-Length: ${bodyLength}\r\n\r\n`;
  return head;
}

function sleep(milliseconds: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => resolve(), milliseconds);
  });
}

function withTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
  return new Promise<T>((resolve: (value: T) => void, reject: (error: Object) => void) => {
    let done: boolean = false;
    const timer: number = setTimeout(() => {
      if (!done) {
        done = true;
        reject(timeoutFailure());
      }
    }, timeoutMs);
    promise.then((value: T) => {
      if (!done) {
        done = true;
        clearTimeout(timer);
        resolve(value);
      }
    }).catch((error: Object) => {
      if (!done) {
        done = true;
        clearTimeout(timer);
        reject(error);
      }
    });
  });
}

async function closeQuietly(tlsSocket: socket.TLSSocket): Promise<void> {
  try {
    await tlsSocket.close();
  } catch (error) {
    Log.warn('tls close failed');
  }
}

/**
 * Performs one HTTPS request and returns the complete response.
 * @throws AuthFailure with a classified kind on transport, TLS, or timeout failures.
 */
export async function tlsRequest(origin: GatewayOrigin, method: string, path: string,
  options: TlsRequestOptions, body: Uint8Array | undefined, headers: Map<string, string>): Promise<TlsResponse> {
  if (options.mode === TrustMode.PINNED && options.pinnedCaPem === undefined) {
    throw transportFailure('refusing a pinned request without a CA');
  }
  const tlsSocket: socket.TLSSocket = socket.constructTLSSocketInstance();
  const chunks: Uint8Array[] = [];
  try {
    await tlsSocket.bind({ address: '0.0.0.0', port: 0, family: 1 });
    tlsSocket.on('error', (error: BusinessError) => {
      Log.warn(`tls socket error ${error.code}`);
    });
    tlsSocket.on('message', (info: socket.SocketMessageInfo) => {
      chunks.push(new Uint8Array(info.message));
    });
    const secureOptions: socket.TLSSecureOptions = {};
    if (options.mode === TrustMode.PINNED && options.pinnedCaPem !== undefined) {
      // Passing a CA replaces the platform trust store with exactly this anchor.
      secureOptions.ca = options.pinnedCaPem;
    }
    const connectOptions: socket.TLSConnectOptions = {
      address: { address: origin.host, port: origin.port, family: 1 },
      secureOptions: secureOptions,
      skipRemoteValidation: options.mode === TrustMode.SKIP
    };
    await withTimeout(tlsSocket.connect(connectOptions), options.timeoutMs);

    const bodyLength: number = body === undefined ? 0 : body.length;
    const head: string = buildHead(origin, method, path, bodyLength, headers);
    const headBytes: Uint8Array = asciiToBytes(head);
    if (body === undefined) {
      await withTimeout(tlsSocket.send(toArrayBuffer(headBytes)), options.timeoutMs);
    } else {
      const payload: Uint8Array = new Uint8Array(headBytes.length + body.length);
      payload.set(headBytes, 0);
      payload.set(body, headBytes.length);
      await withTimeout(tlsSocket.send(toArrayBuffer(payload)), options.timeoutMs);
    }

    const deadline: number = Date.now() + options.timeoutMs;
    while (Date.now() < deadline) {
      const combined: Uint8Array = concat(chunks);
      if (combined.length > MAX_HEADER_BYTES + MAX_BODY_BYTES) {
        throw new AuthFailure(AuthFailureKind.INVALID_RESPONSE, 'gateway response too large');
      }
      const parsed: ParsedHead | undefined = parseHead(combined);
      if (parsed !== undefined) {
        const decoded: ChunkResult = decodeBody(parsed, combined.slice(parsed.headerBytes));
        if (decoded.complete) {
          return new TlsResponse(parsed.status, parsed.headers, decoded.body);
        }
      }
      await sleep(20);
    }
    throw timeoutFailure();
  } catch (error) {
    if (error instanceof AuthFailure) {
      throw error;
    }
    const business: BusinessError = error as BusinessError;
    if (typeof business.code === 'number') {
      // The socket code is the only clue when a handshake dies on the device; record it before the
      // failure is collapsed into a user-facing category.
      Log.warn(`tls ${method} ${path} failed: code ${business.code} ${business.message}`);
      throw classifySocketError(business);
    }
    throw transportFailure('gateway transport failure');
  } finally {
    await closeQuietly(tlsSocket);
  }
}

/**
 * Reads the certificate the gateway serves during the TLS handshake.
 *
 * Used for bootstrap requests only: the returned DER is compared with the pairing CA fingerprint
 * before the paired credential is ever sent.
 */
export async function fetchServedCertificate(origin: GatewayOrigin, timeoutMs: number): Promise<Uint8Array | undefined> {
  const tlsSocket: socket.TLSSocket = socket.constructTLSSocketInstance();
  try {
    await tlsSocket.bind({ address: '0.0.0.0', port: 0, family: 1 });
    const connectOptions: socket.TLSConnectOptions = {
      address: { address: origin.host, port: origin.port, family: 1 },
      secureOptions: {},
      skipRemoteValidation: true
    };
    await withTimeout(tlsSocket.connect(connectOptions), timeoutMs);
    const raw: socket.X509CertRawData = await withTimeout(tlsSocket.getRemoteCertificate(), timeoutMs);
    return new Uint8Array(raw.data);
  } catch (error) {
    return undefined;
  } finally {
    await closeQuietly(tlsSocket);
  }
}
