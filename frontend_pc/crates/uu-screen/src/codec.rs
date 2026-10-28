//! H.264 软编解码（§4，Annex-B）：trait 封装 + openh264 实现（feature `codec`）。

use crate::error::{Result, ScreenError};

/// 编码输出：一条单向流一帧（Annex-B 字节 + 关键帧标志）
#[derive(Debug, Clone)]
pub struct EncodedFrame {
    pub annexb: Vec<u8>,
    pub keyframe: bool,
}

/// 解码输出：RGBA8 像素
#[derive(Debug, Clone)]
pub struct DecodedFrame {
    pub width: u16,
    pub height: u16,
    pub rgba: Vec<u8>,
}

/// 视频编码器抽象
pub trait VideoEncoder: Send {
    /// rgba 为 `width*height*4` 字节；force_key 请求下一帧 IDR
    fn encode(
        &mut self,
        rgba: &[u8],
        width: u16,
        height: u16,
        force_key: bool,
        pts_us: u64,
    ) -> Result<EncodedFrame>;
    /// 动态码率（bps），默认实现忽略
    fn set_bitrate(&mut self, _bps: u32) -> Result<()> {
        Ok(())
    }
}

/// 视频解码器抽象
pub trait VideoDecoder: Send {
    /// 输入一帧 Annex-B；无可用输出时返回 None（如仅 SPS/PPS）
    fn decode(&mut self, annexb: &[u8]) -> Result<Option<DecodedFrame>>;
}

// ---------------- openh264 实现 ----------------

#[cfg(feature = "codec")]
mod imp {
    use super::*;
    use openh264::encoder::{EncoderConfig, FrameType, RateControlMode, UsageType};
    use openh264::formats::{RgbaSliceU8, YUVBuffer, YUVSource};
    use openh264::{nal_units, Timestamp};

    pub struct H264Encoder {
        inner: openh264::encoder::Encoder,
    }

    impl H264Encoder {
        /// 屏幕内容实时编码：指定初始码率与帧率
        pub fn new(bitrate_bps: u32, fps: f32) -> Result<Self> {
            let config = EncoderConfig::new()
                .set_bitrate_bps(bitrate_bps)
                .max_frame_rate(fps)
                .rate_control_mode(RateControlMode::Bitrate)
                .usage_type(UsageType::ScreenContentRealTime)
                .enable_skip_frame(false);
            let api = openh264::OpenH264API::from_source();
            let inner = openh264::encoder::Encoder::with_api_config(api, config)
                .map_err(|e| ScreenError::Codec(e.to_string()))?;
            Ok(Self { inner })
        }
    }

    impl VideoEncoder for H264Encoder {
        fn encode(
            &mut self,
            rgba: &[u8],
            width: u16,
            height: u16,
            force_key: bool,
            pts_us: u64,
        ) -> Result<EncodedFrame> {
            // 4:2:0 要求偶数尺寸，奇数时裁掉最后一行/列
            let w = (width as usize) & !1;
            let h = (height as usize) & !1;
            if w == 0 || h == 0 {
                return Err(ScreenError::Invalid("frame too small".into()));
            }
            let need = w * h * 4;
            if rgba.len() < need {
                return Err(ScreenError::Invalid(format!(
                    "rgba len {} < {}",
                    rgba.len(),
                    need
                )));
            }
            if force_key {
                self.inner.force_intra_frame();
            }
            let src = RgbaSliceU8::new(rgba, (w, h));
            let yuv = YUVBuffer::from_rgb_source(src);
            let ts = Timestamp::from_millis(pts_us / 1000);
            let bs = self
                .inner
                .encode_at(&yuv, ts)
                .map_err(|e| ScreenError::Codec(e.to_string()))?;
            let keyframe = matches!(bs.frame_type(), FrameType::IDR | FrameType::I);
            Ok(EncodedFrame {
                annexb: bs.to_vec(),
                keyframe,
            })
        }
    }

    pub struct H264Decoder {
        inner: openh264::decoder::Decoder,
    }

    impl H264Decoder {
        pub fn new() -> Result<Self> {
            let inner = openh264::decoder::Decoder::new()
                .map_err(|e| ScreenError::Codec(e.to_string()))?;
            Ok(Self { inner })
        }
    }

    impl VideoDecoder for H264Decoder {
        fn decode(&mut self, annexb: &[u8]) -> Result<Option<DecodedFrame>> {
            let mut out = None;
            for nal in nal_units(annexb) {
                // 首几帧可能失败，按规范继续喂数据等待恢复
                match self.inner.decode(nal) {
                    Ok(Some(frame)) => {
                        let (w, h) = frame.dimensions();
                        let mut rgba = vec![0u8; w * h * 4];
                        frame.write_rgba8(&mut rgba);
                        out = Some(DecodedFrame {
                            width: w as u16,
                            height: h as u16,
                            rgba,
                        });
                    }
                    Ok(None) => {}
                    Err(e) => {
                        tracing::debug!("h264 decode err (ignored): {e}");
                    }
                }
            }
            Ok(out)
        }
    }
}

#[cfg(feature = "codec")]
pub use imp::{H264Decoder, H264Encoder};

/// 无 openh264 时的占位编码器（feature 未开启）
#[cfg(not(feature = "codec"))]
pub struct StubEncoder;

#[cfg(not(feature = "codec"))]
impl VideoEncoder for StubEncoder {
    fn encode(
        &mut self,
        _rgba: &[u8],
        _width: u16,
        _height: u16,
        _force_key: bool,
        _pts_us: u64,
    ) -> Result<EncodedFrame> {
        Err(ScreenError::CodecUnavailable)
    }
}

#[cfg(not(feature = "codec"))]
pub struct StubDecoder;

#[cfg(not(feature = "codec"))]
impl VideoDecoder for StubDecoder {
    fn decode(&mut self, _annexb: &[u8]) -> Result<Option<DecodedFrame>> {
        Err(ScreenError::CodecUnavailable)
    }
}

#[cfg(all(test, feature = "codec"))]
mod tests {
    use super::*;

    #[test]
    fn encode_decode_roundtrip() {
        let (w, h) = (64usize, 64usize);
        let mut rgba = vec![0u8; w * h * 4];
        for px in rgba.chunks_exact_mut(4) {
            px[0] = 200; // 偏红
            px[1] = 40;
            px[2] = 30;
            px[3] = 255;
        }
        let mut enc = H264Encoder::new(1_000_000, 30.0).unwrap();
        let f1 = enc.encode(&rgba, w as u16, h as u16, true, 0).unwrap();
        assert!(f1.keyframe);
        assert!(!f1.annexb.is_empty());
        // 第二帧（P 帧）
        let f2 = enc.encode(&rgba, w as u16, h as u16, false, 33_333).unwrap();

        let mut dec = H264Decoder::new().unwrap();
        let d1 = dec.decode(&f1.annexb).unwrap().expect("keyframe output");
        assert_eq!((d1.width as usize, d1.height as usize), (w, h));
        let p = &d1.rgba[..4];
        assert!(p[0].abs_diff(200) < 30 && p[1].abs_diff(40) < 30 && p[2].abs_diff(30) < 30);
        let _d2 = dec.decode(&f2.annexb).unwrap();
    }
}
