//! 输入注入（§3.2）：归一化坐标 → enigo 本地注入。

use enigo::{Axis, Button, Coordinate, Direction, Enigo, Keyboard, Mouse, Settings};
use uu_proto::InputEvent;

use crate::error::{InputError, Result};
use crate::vk::{mods_to_keys, vk_to_key};

fn to_abs(n: f64, size: u32) -> i32 {
    let max = size.saturating_sub(1) as f64;
    (n.clamp(0.0, 1.0) * max).round() as i32
}

fn btn_of(btn: u8) -> Button {
    match btn {
        1 => Button::Left,
        2 => Button::Right,
        3 => Button::Middle,
        4 => Button::Back,
        5 => Button::Forward,
        _ => Button::Left,
    }
}

/// enigo 注入器（被控端使用）
pub struct InputInjector {
    enigo: Enigo,
}

impl InputInjector {
    pub fn new() -> Result<Self> {
        let enigo = Enigo::new(&Settings::default())
            .map_err(|e| InputError::Init(e.to_string()))?;
        Ok(Self { enigo })
    }

    /// 应用一条 §3.2 input 事件；screen_w/h 为被控画面像素尺寸
    pub fn apply(&mut self, ev: &InputEvent, screen_w: u32, screen_h: u32) -> Result<()> {
        match ev {
            InputEvent::Move { x, y } => self.move_norm(*x, *y, screen_w, screen_h),
            InputEvent::Down { x, y, btn } => {
                self.move_norm(*x, *y, screen_w, screen_h)?;
                self.button(btn_of(*btn), true)
            }
            InputEvent::Up { x, y, btn } => {
                self.move_norm(*x, *y, screen_w, screen_h)?;
                self.button(btn_of(*btn), false)
            }
            InputEvent::Scroll { x, y, dx, dy } => {
                self.move_norm(*x, *y, screen_w, screen_h)?;
                let vx = (dx * 3.0).round() as i32;
                let vy = (dy * 3.0).round() as i32;
                if vx != 0 {
                    self.enigo
                        .scroll(vx, Axis::Horizontal)
                        .map_err(|e| InputError::Inject(e.to_string()))?;
                }
                if vy != 0 {
                    self.enigo
                        .scroll(vy, Axis::Vertical)
                        .map_err(|e| InputError::Inject(e.to_string()))?;
                }
                Ok(())
            }
            InputEvent::Key { key_code, action, mods } => self.key(*key_code, action, *mods),
            InputEvent::Text { s } => {
                self.enigo
                    .text(s)
                    .map_err(|e| InputError::Inject(e.to_string()))
            }
            // touch 仅手机被控场景，PC 注入不适用
            InputEvent::Touch { .. } => Ok(()),
        }
    }

    pub fn move_norm(&mut self, nx: f64, ny: f64, w: u32, h: u32) -> Result<()> {
        let (x, y) = (to_abs(nx, w), to_abs(ny, h));
        self.enigo
            .move_mouse(x, y, Coordinate::Abs)
            .map_err(|e| InputError::Inject(e.to_string()))
    }

    pub fn button(&mut self, b: Button, down: bool) -> Result<()> {
        let d = if down { Direction::Press } else { Direction::Release };
        self.enigo
            .button(b, d)
            .map_err(|e| InputError::Inject(e.to_string()))
    }

    /// VK 码按键：down 按住 mods+键，up 释放，press 点按后释放 mods
    pub fn key(&mut self, vk: u32, action: &str, mods: u32) -> Result<()> {
        let key = vk_to_key(vk);
        let mod_keys = mods_to_keys(mods);
        match action {
            "down" => {
                for m in &mod_keys {
                    self.enigo
                        .key(*m, Direction::Press)
                        .map_err(|e| InputError::Inject(e.to_string()))?;
                }
                self.enigo
                    .key(key, Direction::Press)
                    .map_err(|e| InputError::Inject(e.to_string()))
            }
            "up" => {
                self.enigo
                    .key(key, Direction::Release)
                    .map_err(|e| InputError::Inject(e.to_string()))?;
                for m in mod_keys.iter().rev() {
                    self.enigo
                        .key(*m, Direction::Release)
                        .map_err(|e| InputError::Inject(e.to_string()))?;
                }
                Ok(())
            }
            "press" => {
                for m in &mod_keys {
                    self.enigo
                        .key(*m, Direction::Press)
                        .map_err(|e| InputError::Inject(e.to_string()))?;
                }
                self.enigo
                    .key(key, Direction::Click)
                    .map_err(|e| InputError::Inject(e.to_string()))?;
                for m in mod_keys.iter().rev() {
                    self.enigo
                        .key(*m, Direction::Release)
                        .map_err(|e| InputError::Inject(e.to_string()))?;
                }
                Ok(())
            }
            other => Err(InputError::Invalid(format!("unknown key action {other}"))),
        }
    }
}
