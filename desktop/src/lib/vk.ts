/** KeyboardEvent.code -> Windows VK 码（常用键） */

const SPECIAL: Record<string, number> = {
  Backspace: 0x08,
  Tab: 0x09,
  Enter: 0x0d,
  ShiftLeft: 0x10,
  ShiftRight: 0x11,
  ControlLeft: 0x11,
  ControlRight: 0x11,
  AltLeft: 0x12,
  AltRight: 0x12,
  CapsLock: 0x14,
  Escape: 0x1b,
  Space: 0x20,
  PageUp: 0x21,
  PageDown: 0x22,
  End: 0x23,
  Home: 0x24,
  ArrowLeft: 0x25,
  ArrowUp: 0x26,
  ArrowRight: 0x27,
  ArrowDown: 0x28,
  Insert: 0x2d,
  Delete: 0x2e,
  MetaLeft: 0x5b,
  MetaRight: 0x5c,
  Minus: 0xbd,
  Equal: 0xbb,
  BracketLeft: 0xdb,
  Backslash: 0xdc,
  BracketRight: 0xdd,
  Quote: 0xde,
  Semicolon: 0xba,
  Comma: 0xbc,
  Period: 0xbe,
  Slash: 0xbf,
  Backquote: 0xc0,
};

export function vkFromCode(code: string): number | null {
  if (SPECIAL[code] !== undefined) return SPECIAL[code];
  if (/^Key[A-Z]$/.test(code)) return code.charCodeAt(3); // A-Z -> 0x41-0x5A
  if (/^Digit[0-9]$/.test(code)) return code.charCodeAt(5); // 0-9 -> 0x30-0x39
  if (/^Numpad[0-9]$/.test(code)) return code.charCodeAt(6); // 0x60-0x69
  const f = /^F([1-9]|1[0-2])$/.exec(code);
  if (f) return 0x6f + parseInt(f[1], 10); // F1-F12 -> 0x70-0x7B
  return null;
}
