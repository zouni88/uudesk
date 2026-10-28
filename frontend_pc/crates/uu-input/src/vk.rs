//! Windows 虚拟键码（附录 A）与 mods 位掩码（§3.2）辅助。

use enigo::Key;

pub const VK_BACK: u32 = 0x08;
pub const VK_TAB: u32 = 0x09;
pub const VK_ENTER: u32 = 0x0D;
pub const VK_SHIFT: u32 = 0x10;
pub const VK_CONTROL: u32 = 0x11;
pub const VK_MENU: u32 = 0x12; // Alt
pub const VK_CAPITAL: u32 = 0x14;
pub const VK_ESCAPE: u32 = 0x1B;
pub const VK_SPACE: u32 = 0x20;
pub const VK_LEFT: u32 = 0x25;
pub const VK_UP: u32 = 0x26;
pub const VK_RIGHT: u32 = 0x27;
pub const VK_DOWN: u32 = 0x28;
pub const VK_DELETE: u32 = 0x2E;
pub const VK_LWIN: u32 = 0x5B;

/// mods 位掩码（与 uu-proto 一致）
pub const MOD_CTRL: u32 = 1;
pub const MOD_SHIFT: u32 = 2;
pub const MOD_ALT: u32 = 4;
pub const MOD_META: u32 = 8;

/// VK 码 → enigo Key。Windows 上 `Key::Other(vk)` 直接作为 wVk 注入；
/// 常用键查表用命名变体，便于跨平台。
pub fn vk_to_key(vk: u32) -> Key {
    match vk {
        VK_BACK => Key::Backspace,
        VK_TAB => Key::Tab,
        VK_ENTER => Key::Return,
        VK_SHIFT => Key::Shift,
        VK_CONTROL => Key::Control,
        VK_MENU => Key::Alt,
        VK_CAPITAL => Key::CapsLock,
        VK_ESCAPE => Key::Escape,
        VK_SPACE => Key::Space,
        VK_LEFT => Key::LeftArrow,
        VK_UP => Key::UpArrow,
        VK_RIGHT => Key::RightArrow,
        VK_DOWN => Key::DownArrow,
        VK_DELETE => Key::Delete,
        VK_LWIN => Key::Meta,
        0x2C => Key::Snapshot,   // VK_SNAPSHOT
        0x2D => Key::Insert,     // VK_INSERT
        0x24 => Key::Home,       // VK_HOME
        0x23 => Key::End,        // VK_END
        0x21 => Key::PageUp,     // VK_PRIOR
        0x22 => Key::PageDown,   // VK_NEXT
        c @ (0x70..=0x87) => {
            // VK_F1..VK_F24
            let idx = (c - 0x70) as u8;
            const FKEYS: [Key; 24] = [
                Key::F1, Key::F2, Key::F3, Key::F4, Key::F5, Key::F6, Key::F7, Key::F8, Key::F9,
                Key::F10, Key::F11, Key::F12, Key::F13, Key::F14, Key::F15, Key::F16, Key::F17,
                Key::F18, Key::F19, Key::F20, Key::F21, Key::F22, Key::F23, Key::F24,
            ];
            FKEYS[idx as usize]
        }
        other => Key::Other(other),
    }
}

/// mods 位掩码展开为按键序列（按下顺序）
pub fn mods_to_keys(mods: u32) -> Vec<Key> {
    let mut v = Vec::with_capacity(4);
    if mods & MOD_CTRL != 0 {
        v.push(Key::Control);
    }
    if mods & MOD_SHIFT != 0 {
        v.push(Key::Shift);
    }
    if mods & MOD_ALT != 0 {
        v.push(Key::Alt);
    }
    if mods & MOD_META != 0 {
        v.push(Key::Meta);
    }
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vk_mapping() {
        assert!(matches!(vk_to_key(VK_ENTER), Key::Return));
        assert!(matches!(vk_to_key(0x41), Key::Other(0x41)));
        assert!(matches!(vk_to_key(0x70), Key::F1));
        assert!(matches!(vk_to_key(0x87), Key::F24));
        assert_eq!(mods_to_keys(MOD_CTRL | MOD_ALT).len(), 2);
    }
}
