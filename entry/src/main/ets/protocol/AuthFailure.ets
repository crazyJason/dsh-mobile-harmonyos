/**
 * Classified gateway failures.
 *
 * Kept in its own module so the TLS transport and the gateway client can both use it without a
 * circular import.
 */

export enum AuthFailureKind {
  PAIRING_EXPIRED = 'PAIRING_EXPIRED',
  DEVICE_REVOKED = 'DEVICE_REVOKED',
  DEVICE_EXPIRED = 'DEVICE_EXPIRED',
  DEVICE_LIMIT = 'DEVICE_LIMIT',
  RATE_LIMITED = 'RATE_LIMITED',
  /** The gateway answered 403 because this peer network is outside its trusted ranges. */
  SOURCE_NETWORK_UNTRUSTED = 'SOURCE_NETWORK_UNTRUSTED',
  TIMEOUT = 'TIMEOUT',
  TLS = 'TLS',
  NETWORK = 'NETWORK',
  SERVER_UNAVAILABLE = 'SERVER_UNAVAILABLE',
  INVALID_RESPONSE = 'INVALID_RESPONSE',
  /** The device credential could not be persisted locally. */
  STORAGE = 'STORAGE',
}

export class AuthFailure extends Error {
  readonly kind: AuthFailureKind;

  constructor(kind: AuthFailureKind, message: string) {
    super(message);
    this.name = 'AuthFailure';
    this.kind = kind;
  }
}

/** Maps one gateway error response onto the failure the UI should explain. */
export function failureForStatus(status: number, errorCode: string | undefined): AuthFailureKind {
  if (errorCode === 'device_revoked') {
    return AuthFailureKind.DEVICE_REVOKED;
  }
  if (errorCode === 'device_expired') {
    return AuthFailureKind.DEVICE_EXPIRED;
  }
  if (errorCode === 'source_network_untrusted') {
    return AuthFailureKind.SOURCE_NETWORK_UNTRUSTED;
  }
  if (status === 401 || status === 403) {
    return AuthFailureKind.PAIRING_EXPIRED;
  }
  if (status === 409) {
    return AuthFailureKind.DEVICE_LIMIT;
  }
  if (status === 429) {
    return AuthFailureKind.RATE_LIMITED;
  }
  if (status >= 500 && status <= 599) {
    return AuthFailureKind.SERVER_UNAVAILABLE;
  }
  return AuthFailureKind.INVALID_RESPONSE;
}
