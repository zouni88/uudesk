//! §4 视频帧头解析 + RGBA→JPEG 编码 + `uu://frame` 事件负载。

use serde::Serialize;
use uu_proto::{VideoHeader, VIDEO_HEADER_LEN};

/// 解析一条单向流字节：§4 帧头 + Annex-B NAL。
/// 长度不足 / magic 错误 / payload 截断时返回 None。
pub fn parse_video_frame(data: &[u8]) -> Option<(VideoHeader, &[u8])> {
    let h = VideoHeader::decode(data).ok()?;
    let end = VIDEO_HEADER_LEN.checked_add(h.len as usize)?;
    if data.len() < end {
        return None;
    }
    Some((h, &data[VIDEO_HEADER_LEN..end]))
}

/// `uu://frame` 事件负载（字段名与前端契约一致）
#[derive(Clone, Serialize)]
pub struct FramePayload {
    pub seq: u32,
    pub key: bool,
    pub w: u16,
    pub h: u16,
    pub ts_us: u64,
    pub jpeg_b64: String,
}

/// RGBA8 → JPEG（quality 70）
pub fn encode_jpeg(rgba: &[u8], w: u16, h: u16) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 70);
    enc.encode(rgba, w as u32, h as u32, image::ExtendedColorType::Rgba8)
        .map_err(|e| format!("jpeg encode: {e}"))?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use uu_proto::{VIDEO_MAGIC, CODEC_H264_ANNEXB};

    fn hdr_frame() -> Vec<u8> {
        let h = VideoHeader {
            keyframe: true,
            codec: CODEC_H264_ANNEXB,
            seq: 42,
            pts_us: 1_234_567,
            w: 1920,
            h: 1080,
            len: 4,
        };
        let mut buf = h.encode().to_vec();
        buf.extend_from_slice(&[0, 0, 0, 1]); // 假 NAL 起始码
        buf
    }

    #[test]
    fn parse_video_frame_ok() {
        let buf = hdr_frame();
        let (h, nal) = parse_video_frame(&buf).expect("should parse");
        assert_eq!(h.seq, 42);
        assert!(h.keyframe);
        assert_eq!((h.w, h.h), (1920, 1080));
        assert_eq!(h.pts_us, 1_234_567);
        assert_eq!(nal, &[0, 0, 0, 1]);
    }

    #[test]
    fn parse_video_frame_rejects_bad() {
        // 截断 payload
        let mut buf = hdr_frame();
        buf.truncate(VIDEO_HEADER_LEN + 2);
        assert!(parse_video_frame(&buf).is_none());
        // magic 错误
        let mut buf = hdr_frame();
        buf[0] = (VIDEO_MAGIC >> 8) as u8 ^ 0xFF;
        assert!(parse_video_frame(&buf).is_none());
        // 太短
        assert!(parse_video_frame(&[0x55, 0x56, 0x01]).is_none());
    }

    #[test]
    fn frame_payload_field_names() {
        let p = FramePayload {
            seq: 1,
            key: true,
            w: 2,
            h: 3,
            ts_us: 4,
            jpeg_b64: "aaa".into(),
        };
        let j = serde_json::to_string(&p).unwrap();
        for k in ["\"seq\"", "\"key\"", "\"w\"", "\"h\"", "\"ts_us\"", "\"jpeg_b64\""] {
            assert!(j.contains(k), "missing {k} in {j}");
        }
    }
}
