/**
 * Visual system for the app.
 *
 * A single dark-first palette with one accent gradient keeps the client visually distinct from the
 * web page it hosts, which matters because the container chrome and the page load at different
 * times and must never be confused with each other.
 */
export class Palette {
  static readonly background: string = '#0B0E14';
  static readonly surface: string = '#141924';
  static readonly surfaceRaised: string = '#1B2230';
  static readonly stroke: string = '#242C3B';
  static readonly textPrimary: string = '#F2F5FA';
  static readonly textSecondary: string = '#98A2B3';
  static readonly textMuted: string = '#6B7686';
  static readonly accent: string = '#3B82F6';
  static readonly accentSoft: string = '#1E3A5F';
  static readonly success: string = '#34D399';
  static readonly warning: string = '#FBBF24';
  static readonly danger: string = '#F87171';
  static readonly onAccent: string = '#FFFFFF';
}

export class StatusStyle {
  readonly label: string;
  readonly color: string;

  constructor(label: string, color: string) {
    this.label = label;
    this.color = color;
  }
}

/** Formats a millisecond timestamp as a short relative age for list subtitles. */
export function formatRelative(epochMillis: number): string {
  if (epochMillis <= 0) {
    return '从未连接';
  }
  const delta: number = Date.now() - epochMillis;
  if (delta < 60 * 1000) {
    return '刚刚';
  }
  if (delta < 60 * 60 * 1000) {
    return `${Math.floor(delta / (60 * 1000))} 分钟前`;
  }
  if (delta < 24 * 60 * 60 * 1000) {
    return `${Math.floor(delta / (60 * 60 * 1000))} 小时前`;
  }
  return `${Math.floor(delta / (24 * 60 * 60 * 1000))} 天前`;
}
