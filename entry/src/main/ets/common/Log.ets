import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0D5B;

/** Thin hilog wrapper so every module logs under one tag. */
export class Log {
  static info(message: string): void {
    hilog.info(DOMAIN, 'DshMobile', '%{public}s', message);
  }

  static warn(message: string): void {
    hilog.warn(DOMAIN, 'DshMobile', '%{public}s', message);
  }

  static error(message: string): void {
    hilog.error(DOMAIN, 'DshMobile', '%{public}s', message);
  }
}
