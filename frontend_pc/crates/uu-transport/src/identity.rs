//! 设备身份（§1）：Ed25519 密钥 + 自签证书 + device_id/pin 计算。
//! device_id = base32(SHA256(SPKI DER)) 前 16 字符（大写，无填充）。

use std::path::{Path, PathBuf};

use data_encoding::BASE32_NOPAD;
use sha2::{Digest, Sha256};

use crate::der::spki_der;
use crate::error::Result;

const KEY_FILE: &str = "identity_pk8.der";
const CERT_FILE: &str = "identity_cert.der";

#[derive(Clone)]
pub struct Identity {
    pub device_id: String,
    cert_der: Vec<u8>,
    pkcs8: Vec<u8>,
    dir: PathBuf,
}

impl Identity {
    /// 从目录加载；不存在则生成并保存。
    pub fn load_or_create(dir: &Path) -> Result<Self> {
        std::fs::create_dir_all(dir)?;
        let key_path = dir.join(KEY_FILE);
        let cert_path = dir.join(CERT_FILE);
        if key_path.exists() && cert_path.exists() {
            let pkcs8 = std::fs::read(&key_path)?;
            let cert_der = std::fs::read(&cert_path)?;
            let device_id = pin_of_cert(&cert_der)?;
            return Ok(Self { device_id, cert_der, pkcs8, dir: dir.to_path_buf() });
        }
        let (cert_der, pkcs8) = generate_cert()?;
        std::fs::write(&key_path, &pkcs8)?;
        std::fs::write(&cert_path, &cert_der)?;
        let device_id = pin_of_cert(&cert_der)?;
        Ok(Self { device_id, cert_der, pkcs8, dir: dir.to_path_buf() })
    }

    pub fn cert_der(&self) -> &[u8] {
        &self.cert_der
    }

    pub fn pkcs8(&self) -> &[u8] {
        &self.pkcs8
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }
}

/// SPKI SHA-256 → base32 前 16 字符
pub fn pin_of_cert(cert_der: &[u8]) -> Result<String> {
    let spki = spki_der(cert_der)?;
    let hash = Sha256::digest(&spki);
    let b32 = BASE32_NOPAD.encode(&hash);
    Ok(b32.chars().take(16).collect())
}

/// 生成 Ed25519 自签证书（CN=device_id，SAN=uudesk.local）
fn generate_cert() -> Result<(Vec<u8>, Vec<u8>)> {
    let key_pair = rcgen::KeyPair::generate_for(&rcgen::PKCS_ED25519)?;
    let pkcs8 = key_pair.serialize_der(); // PKCS#8 v1

    // 由公钥直接构造 SPKI 计算 device_id
    let spki = ed25519_spki_der(key_pair.public_key_raw());
    let device_id = {
        let hash = Sha256::digest(&spki);
        BASE32_NOPAD.encode(&hash).chars().take(16).collect::<String>()
    };

    let mut params = rcgen::CertificateParams::new(vec!["uudesk.local".to_string()])?;
    params.distinguished_name = rcgen::DistinguishedName::new();
    params
        .distinguished_name
        .push(rcgen::DnType::CommonName, device_id.clone());
    params.not_before = rcgen::date_time_ymd(2025, 1, 1);
    params.not_after = rcgen::date_time_ymd(2125, 1, 1);
    let cert = params.self_signed(&key_pair)?;
    Ok((cert.der().as_ref().to_vec(), pkcs8))
}

/// Ed25519 SPKI DER：固定前缀 + 32 字节公钥
pub fn ed25519_spki_der(pubkey: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(44);
    v.extend_from_slice(&[0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00]);
    v.extend_from_slice(pubkey);
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_generate_and_pin_consistent() {
        let dir = std::env::temp_dir().join("uu-identity-test");
        let _ = std::fs::remove_dir_all(&dir);
        let id = Identity::load_or_create(&dir).unwrap();
        assert_eq!(id.device_id.len(), 16);
        assert_eq!(id.device_id, pin_of_cert(id.cert_der()).unwrap());
        // 重新加载得到同一 device_id
        let id2 = Identity::load_or_create(&dir).unwrap();
        assert_eq!(id.device_id, id2.device_id);
        std::fs::remove_dir_all(&dir).ok();
    }
}
