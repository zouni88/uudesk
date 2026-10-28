//! 控制流 JSON 消息（§3）。信封：{"t":"<type>","id":<u32 可选>,...}
//! 坐标一律归一化 0.0–1.0。

use serde::{Deserialize, Serialize};

use crate::error::ProtoError;

/// §3.2 输入事件（input 消息的 k 子类型）
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "k", rename_all = "snake_case")]
pub enum InputEvent {
    Move { x: f64, y: f64 },
    Down { x: f64, y: f64, btn: u8 },
    Up { x: f64, y: f64, btn: u8 },
    Scroll { x: f64, y: f64, dx: f64, dy: f64 },
    Key {
        key_code: u32,
        action: String, // "down" | "up" | "press"
        #[serde(default)]
        mods: u32,
    },
    Touch {
        id: u32,
        x: f64,
        y: f64,
        action: String, // "down" | "up" | "move"
    },
    Text { s: String },
}

/// mods 位定义：bit0=ctrl bit1=shift bit2=alt bit3=meta(win)
pub const MOD_CTRL: u32 = 1;
pub const MOD_SHIFT: u32 = 2;
pub const MOD_ALT: u32 = 4;
pub const MOD_META: u32 = 8;

/// 全部控制流消息类型
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum ControlMsg {
    // §3.1 会话/握手
    Hello {
        role: String,
        device_id: String,
        name: String,
        proto: u32,
    },
    HelloAck {
        device_id: String,
        name: String,
    },
    SessionOpen {
        mode: String, // "view_pc" | "control_phone"
        #[serde(default)]
        caps: Vec<String>,
    },
    SessionClose,
    Error {
        code: u32,
        msg: String,
    },
    Ping {
        ts: u64,
        #[serde(default)]
        id: Option<u32>,
    },
    Pong {
        ts: u64,
        #[serde(default)]
        id: Option<u32>,
    },

    // §3.2 输入控制
    Input {
        #[serde(flatten)]
        ev: InputEvent,
    },
    KeyframeReq,
    ScreenCfg {
        fps: u32,
        w: u32,
        h: u32,
        bitrate_kbps: u32,
        #[serde(default)]
        preset: String,
    },
    ScreenCfgAck {
        fps: u32,
        w: u32,
        h: u32,
    },

    // §3.3 画面元数据
    ScreenMeta {
        w: u32,
        h: u32,
        scale: f64,
        rotation: u32,
        codec: String,
    },

    // §3.4 剪贴板
    ClipSet {
        text: String,
        ts: u64,
        #[serde(default)]
        id: Option<u32>,
    },
    ClipAck {
        #[serde(default)]
        id: Option<u32>,
    },

    // §3.5 手机被控指令
    CapStart,
    CapStop,
    InjectEnable,
    InjectDisable,

    // §3.6 文件传输
    FileOffer {
        id: u32,
        name: String,
        size: u64,
        #[serde(default)]
        path_hint: Option<String>,
    },
    FileAccept {
        id: u32,
    },
    FileReject {
        id: u32,
    },
    FileDone {
        id: u32,
        sha256: String,
    },

    /// 未知类型（前向兼容，仅由 decode_msg 构造）
    #[serde(other)]
    Unknown,
}

const KNOWN_TYPES: &[&str] = &[
    "hello",
    "hello_ack",
    "session_open",
    "session_close",
    "error",
    "ping",
    "pong",
    "input",
    "keyframe_req",
    "screen_cfg",
    "screen_cfg_ack",
    "screen_meta",
    "clip_set",
    "clip_ack",
    "cap_start",
    "cap_stop",
    "inject_enable",
    "inject_disable",
    "file_offer",
    "file_accept",
    "file_reject",
    "file_done",
];

/// 从裸 JSON 字节解析消息；未知 `t` 归入 `Unknown` 以保持前向兼容。
pub fn decode_msg(json: &[u8]) -> Result<ControlMsg, ProtoError> {
    let v: serde_json::Value = serde_json::from_slice(json)?;
    let t = v.get("t").and_then(|x| x.as_str()).unwrap_or("");
    if !KNOWN_TYPES.contains(&t) {
        return Ok(ControlMsg::Unknown);
    }
    Ok(serde_json::from_value(v)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round(m: &ControlMsg) -> ControlMsg {
        let json = serde_json::to_vec(m).unwrap();
        decode_msg(&json).unwrap()
    }

    #[test]
    fn hello_roundtrip() {
        let m = ControlMsg::Hello {
            role: "pc".into(),
            device_id: "ABCDEF0123456789".into(),
            name: "my-pc".into(),
            proto: 1,
        };
        assert_eq!(round(&m), m);
    }

    #[test]
    fn input_flatten_tag() {
        let m = ControlMsg::Input { ev: InputEvent::Down { x: 0.5, y: 0.25, btn: 1 } };
        let json = serde_json::to_string(&m).unwrap();
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["t"], "input");
        assert_eq!(v["k"], "down");
        assert_eq!(v["btn"], 1);
        assert_eq!(round(&m), m);
    }

    #[test]
    fn key_input() {
        let m = ControlMsg::Input {
            ev: InputEvent::Key { key_code: 0x41, action: "press".into(), mods: MOD_CTRL },
        };
        assert_eq!(round(&m), m);
    }

    #[test]
    fn unit_variants() {
        for m in [ControlMsg::KeyframeReq, ControlMsg::SessionClose, ControlMsg::CapStart] {
            assert_eq!(round(&m), m);
        }
    }

    #[test]
    fn clip_set_with_id() {
        let m = ControlMsg::ClipSet { text: "hi".into(), ts: 123, id: Some(9) };
        assert_eq!(round(&m), m);
    }

    #[test]
    fn unknown_type_fallback() {
        let json = br#"{"t":"future_thing","x":1}"#;
        let m = decode_msg(json).unwrap();
        assert_eq!(m, ControlMsg::Unknown);
    }

    #[test]
    fn error_codes_present() {
        let m = ControlMsg::Error { code: crate::codes::ERR_SPKI_PIN, msg: "pin".into() };
        assert_eq!(round(&m), m);
    }
}
