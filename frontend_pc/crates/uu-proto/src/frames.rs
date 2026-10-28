//! 二进制帧头编解码（§4 视频 / §5 音频 / §7 文件），全部大端。

use crate::error::ProtoError;

// ---------- 视频帧头 §4 ----------
pub const VIDEO_MAGIC: u16 = 0x5556; // "UV"
pub const VIDEO_HEADER_LEN: usize = 24;
/// codec: 0 = H264 AnnexB
pub const CODEC_H264_ANNEXB: u8 = 0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VideoHeader {
    pub keyframe: bool,
    pub codec: u8,
    pub seq: u32,
    pub pts_us: u64,
    pub w: u16,
    pub h: u16,
    pub len: u32,
}

impl VideoHeader {
    pub fn encode(&self) -> [u8; VIDEO_HEADER_LEN] {
        let mut b = [0u8; VIDEO_HEADER_LEN];
        b[0..2].copy_from_slice(&VIDEO_MAGIC.to_be_bytes());
        b[2] = if self.keyframe { 1 } else { 0 };
        b[3] = self.codec;
        b[4..8].copy_from_slice(&self.seq.to_be_bytes());
        b[8..16].copy_from_slice(&self.pts_us.to_be_bytes());
        b[16..18].copy_from_slice(&self.w.to_be_bytes());
        b[18..20].copy_from_slice(&self.h.to_be_bytes());
        b[20..24].copy_from_slice(&self.len.to_be_bytes());
        b
    }

    pub fn decode(b: &[u8]) -> Result<Self, ProtoError> {
        if b.len() < VIDEO_HEADER_LEN {
            return Err(ProtoError::TooShort { need: VIDEO_HEADER_LEN, got: b.len() });
        }
        let magic = u16::from_be_bytes([b[0], b[1]]);
        if magic != VIDEO_MAGIC {
            return Err(ProtoError::BadMagic(magic));
        }
        Ok(Self {
            keyframe: b[2] & 1 != 0,
            codec: b[3],
            seq: u32::from_be_bytes([b[4], b[5], b[6], b[7]]),
            pts_us: u64::from_be_bytes(b[8..16].try_into().unwrap()),
            w: u16::from_be_bytes([b[16], b[17]]),
            h: u16::from_be_bytes([b[18], b[19]]),
            len: u32::from_be_bytes([b[20], b[21], b[22], b[23]]),
        })
    }
}

// ---------- 音频帧头 §5 ----------
pub const AUDIO_MAGIC: u16 = 0x5541; // "UA"
pub const AUDIO_HEADER_LEN: usize = 19;
/// codec: 0 = opus 48k/2ch
pub const CODEC_OPUS_48K2CH: u8 = 0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AudioHeader {
    pub seq: u32,
    pub pts_us: u64,
    pub codec: u8,
    pub len: u32,
}

impl AudioHeader {
    pub fn encode(&self) -> [u8; AUDIO_HEADER_LEN] {
        let mut b = [0u8; AUDIO_HEADER_LEN];
        b[0..2].copy_from_slice(&AUDIO_MAGIC.to_be_bytes());
        b[2..6].copy_from_slice(&self.seq.to_be_bytes());
        b[6..14].copy_from_slice(&self.pts_us.to_be_bytes());
        b[14] = self.codec;
        b[15..19].copy_from_slice(&self.len.to_be_bytes());
        b
    }

    pub fn decode(b: &[u8]) -> Result<Self, ProtoError> {
        if b.len() < AUDIO_HEADER_LEN {
            return Err(ProtoError::TooShort { need: AUDIO_HEADER_LEN, got: b.len() });
        }
        let magic = u16::from_be_bytes([b[0], b[1]]);
        if magic != AUDIO_MAGIC {
            return Err(ProtoError::BadMagic(magic));
        }
        Ok(Self {
            seq: u32::from_be_bytes([b[2], b[3], b[4], b[5]]),
            pts_us: u64::from_be_bytes(b[6..14].try_into().unwrap()),
            codec: b[14],
            len: u32::from_be_bytes([b[15], b[16], b[17], b[18]]),
        })
    }
}

// ---------- 文件 chunk 头 §7 ----------
pub const FILE_MAGIC: u16 = 0x5546; // "UF"
pub const FILE_HEADER_LEN: usize = 14;
pub const FILE_CHUNK_SIZE: usize = 256 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FileHeader {
    pub id: u32,
    pub chunk_index: u32,
    pub chunk_len: u32,
}

impl FileHeader {
    pub fn encode(&self) -> [u8; FILE_HEADER_LEN] {
        let mut b = [0u8; FILE_HEADER_LEN];
        b[0..2].copy_from_slice(&FILE_MAGIC.to_be_bytes());
        b[2..6].copy_from_slice(&self.id.to_be_bytes());
        b[6..10].copy_from_slice(&self.chunk_index.to_be_bytes());
        b[10..14].copy_from_slice(&self.chunk_len.to_be_bytes());
        b
    }

    pub fn decode(b: &[u8]) -> Result<Self, ProtoError> {
        if b.len() < FILE_HEADER_LEN {
            return Err(ProtoError::TooShort { need: FILE_HEADER_LEN, got: b.len() });
        }
        let magic = u16::from_be_bytes([b[0], b[1]]);
        if magic != FILE_MAGIC {
            return Err(ProtoError::BadMagic(magic));
        }
        Ok(Self {
            id: u32::from_be_bytes([b[2], b[3], b[4], b[5]]),
            chunk_index: u32::from_be_bytes([b[6], b[7], b[8], b[9]]),
            chunk_len: u32::from_be_bytes([b[10], b[11], b[12], b[13]]),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn video_header_roundtrip() {
        let h = VideoHeader {
            keyframe: true,
            codec: CODEC_H264_ANNEXB,
            seq: 0xDEAD_BEEF,
            pts_us: 0x0123_4567_89AB_CDEF,
            w: 1920,
            h: 1080,
            len: 123456,
        };
        let b = h.encode();
        assert_eq!(b.len(), VIDEO_HEADER_LEN);
        assert_eq!(VideoHeader::decode(&b).unwrap(), h);
    }

    #[test]
    fn video_header_magic() {
        let h = VideoHeader { keyframe: false, codec: 0, seq: 1, pts_us: 2, w: 3, h: 4, len: 5 };
        let mut b = h.encode();
        b[0] = 0xFF;
        assert!(matches!(VideoHeader::decode(&b), Err(ProtoError::BadMagic(_))));
        assert!(matches!(VideoHeader::decode(&b[..10]), Err(ProtoError::TooShort { .. })));
    }

    #[test]
    fn audio_header_roundtrip() {
        let h = AudioHeader { seq: 7, pts_us: 999_999, codec: CODEC_OPUS_48K2CH, len: 160 };
        let b = h.encode();
        assert_eq!(b.len(), AUDIO_HEADER_LEN);
        assert_eq!(AudioHeader::decode(&b).unwrap(), h);
    }

    #[test]
    fn file_header_roundtrip() {
        let h = FileHeader { id: 1, chunk_index: 2, chunk_len: FILE_CHUNK_SIZE as u32 };
        let b = h.encode();
        assert_eq!(b.len(), FILE_HEADER_LEN);
        assert_eq!(FileHeader::decode(&b).unwrap(), h);
    }

    #[test]
    fn magic_distinct() {
        // 三种帧头 magic 必须互不相同，接收侧靠首 2 字节分派
        assert_ne!(VIDEO_MAGIC, AUDIO_MAGIC);
        assert_ne!(VIDEO_MAGIC, FILE_MAGIC);
        assert_ne!(AUDIO_MAGIC, FILE_MAGIC);
    }
}
