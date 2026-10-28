//! 控制流长度前缀编解码（§2/§3）：u32 大端长度 + UTF-8 JSON。

use crate::control::ControlMsg;
use crate::error::ProtoError;

/// 控制消息最大长度（防御性上限）
pub const MAX_CONTROL_LEN: u32 = 4 * 1024 * 1024;

pub fn encode_len(n: u32) -> [u8; 4] {
    n.to_be_bytes()
}

pub fn decode_len(b: [u8; 4]) -> Result<u32, ProtoError> {
    let n = u32::from_be_bytes(b);
    if n > MAX_CONTROL_LEN {
        return Err(ProtoError::LenTooLarge(n));
    }
    Ok(n)
}

/// 序列化消息并加 4 字节大端长度前缀
pub fn encode_msg(m: &ControlMsg) -> Result<Vec<u8>, ProtoError> {
    let json = serde_json::to_vec(m)?;
    let mut out = Vec::with_capacity(4 + json.len());
    out.extend_from_slice(&encode_len(json.len() as u32));
    out.extend_from_slice(&json);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn len_prefix_roundtrip() {
        for n in [0u32, 1, 255, 65535, MAX_CONTROL_LEN] {
            assert_eq!(decode_len(encode_len(n)).unwrap(), n);
        }
        assert!(matches!(
            decode_len(encode_len(MAX_CONTROL_LEN + 1)),
            Err(ProtoError::LenTooLarge(_))
        ));
    }

    #[test]
    fn encode_msg_prefix_layout() {
        let m = ControlMsg::KeyframeReq;
        let bytes = encode_msg(&m).unwrap();
        let len = decode_len(bytes[..4].try_into().unwrap()).unwrap() as usize;
        assert_eq!(bytes.len(), 4 + len);
        let json = std::str::from_utf8(&bytes[4..]).unwrap();
        let v: serde_json::Value = serde_json::from_str(json).unwrap();
        assert_eq!(v["t"], "keyframe_req");
    }
}
