import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0D5B;
const TAG: string = 'DshMobile';

const APP_KEY = new RegExp('dsh[12]\\.[a-f0-9]{64}\\.[A-Za-z0-9_-]{43}', 'g');
const CREDENTIAL_FIELD = new RegExp('(deviceToken|sessionToken|csrfToken|token)"?\\s*[=:]\\s*"?[A-Za-z0-9_-]{20,}', 'g');
const PAIRING_FRAGMENT = new RegExp('((#|&)(key|instance|token)=)[^\\s&"]+', 'g');

/** Thin hilog wrapper that scrubs credentials before anything reaches the system log. */
export class Log {
  static info(message: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', Log.sanitize(message));
  }

  static warn(message: string): void {
    hilog.warn(DOMAIN, TAG, '%{public}s', Log.sanitize(message));
  }

  static error(message: string): void {
    hilog.error(DOMAIN, TAG, '%{public}s', Log.sanitize(message));
  }

  /**
   * Removes pairing keys and session/device credentials from one log line.
   *
   * Callers should still avoid logging secrets at all; this is the second line of defence for
   * diagnostic strings that may embed a URL or a gateway response.
   */
  static sanitize(message: string): string {
    let text: string = message;
    text = text.replace(APP_KEY, 'dsh?.<redacted>');
    text = text.replace(CREDENTIAL_FIELD, '$1=<redacted>');
    text = text.replace(PAIRING_FRAGMENT, '$1<redacted>');
    return text;
  }
}
