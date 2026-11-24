/**
 * Bounded, defensive JSON helpers.
 *
 * Every gateway response is untrusted input: parse it into an object dictionary and read fields
 * with explicit type checks instead of casting the whole document.
 */
export type JsonObject = Record<string, Object>;

export function parseJsonObject(text: string): JsonObject | undefined {
  if (text.length === 0) {
    return undefined;
  }
  try {
    const parsed: Object = JSON.parse(text);
    if (typeof parsed === 'object' && parsed !== null) {
      return parsed as JsonObject;
    }
    return undefined;
  } catch (error) {
    return undefined;
  }
}

export function hasKey(source: JsonObject, key: string): boolean {
  return Object.keys(source).indexOf(key) >= 0;
}

export function keyCount(source: JsonObject): number {
  return Object.keys(source).length;
}

export function readString(source: JsonObject, key: string): string | undefined {
  if (!hasKey(source, key)) {
    return undefined;
  }
  const value: Object = source[key];
  if (typeof value === 'string') {
    return value as string;
  }
  return undefined;
}

export function readNumber(source: JsonObject, key: string): number | undefined {
  if (!hasKey(source, key)) {
    return undefined;
  }
  const value: Object = source[key];
  if (typeof value === 'number') {
    return value as number;
  }
  return undefined;
}
