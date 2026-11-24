/**
 * Pairing QR scan channel.
 *
 * The desktop encodes the pairing link itself into the QR code, so a scan produces exactly the
 * string a paste would produce. This module therefore does one thing only: obtain that string.
 * Parsing, host classification and every CA/pin rule stay in `interpretPairingInput` and the
 * protocol layer -- a scanned code must never bypass them (PROTOCOL §3.4, ADR-0006).
 *
 * The system scanning UI is used on purpose: it runs the camera preview inside the system process,
 * so the app neither declares `ohos.permission.CAMERA` nor renders a viewfinder of its own.
 */
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { Log } from './Log';

/** `Scan Kit` reports a user-cancelled scan with this business code (since 5.0.0(12)). */
const SCAN_CANCELLED: number = 1000500002;

export enum ScanStatus {
  SCANNED = 'SCANNED',
  CANCELLED = 'CANCELLED',
  FAILED = 'FAILED'
}

/** One scan attempt. `text` is the raw QR payload, which is a credential: never log it. */
export class ScanOutcome {
  readonly status: ScanStatus;
  readonly text: string;
  readonly detail: string;

  constructor(status: ScanStatus, text: string, detail: string) {
    this.status = status;
    this.text = text;
    this.detail = detail;
  }

  static scanned(text: string): ScanOutcome {
    return new ScanOutcome(ScanStatus.SCANNED, text, '');
  }

  static cancelled(): ScanOutcome {
    return new ScanOutcome(ScanStatus.CANCELLED, '', '');
  }

  static failed(detail: string): ScanOutcome {
    return new ScanOutcome(ScanStatus.FAILED, '', detail);
  }
}

/**
 * Opens the system scanning UI for a single QR code and returns the payload.
 *
 * Cancelling is a normal outcome, not an error: the caller must stay silent about it. Any other
 * failure (no scan service on the device, internal error) is reported so the UI can fall back to
 * "paste the link instead".
 */
export async function scanPairingQr(context: common.Context): Promise<ScanOutcome> {
  const options: scanBarcode.ScanOptions = {
    scanTypes: [scanCore.ScanType.QR_CODE],
    enableMultiMode: false,
    enableAlbum: true
  };
  try {
    const result: scanBarcode.ScanResult = await scanBarcode.startScanForResult(context, options);
    const text: string = result.originalValue.trim();
    if (text.length === 0) {
      Log.warn('scan finished without a payload');
      return ScanOutcome.failed('empty');
    }
    // Only the fact of a successful scan is logged; the payload is the pairing token.
    Log.info('pairing QR scanned');
    return ScanOutcome.scanned(text);
  } catch (error) {
    const failure: BusinessError = error as BusinessError;
    if (failure.code === SCAN_CANCELLED) {
      Log.info('scan cancelled by the user');
      return ScanOutcome.cancelled();
    }
    Log.warn(`scan failed code=${failure.code}`);
    return ScanOutcome.failed(`code=${failure.code}`);
  }
}
