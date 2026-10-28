//! 最小 DER 遍历：从 X.509 证书中提取 subjectPublicKeyInfo 的完整 DER。
//! 不引入 x509 解析库，避免依赖漂移；证书结构由本端 rcgen 生成，可预期。

use crate::error::{Result, TransportError};

/// 读取一个 DER 元素，返回 (tag, content_start, content_len, next_pos)
fn read_element(buf: &[u8], pos: usize) -> Result<(u8, usize, usize, usize)> {
    if pos >= buf.len() {
        return Err(TransportError::CertParse("der truncated (tag)".into()));
    }
    let tag = buf[pos];
    let mut i = pos + 1;
    if i >= buf.len() {
        return Err(TransportError::CertParse("der truncated (len)".into()));
    }
    let first = buf[i];
    let (len, content_start) = if first < 0x80 {
        (first as usize, i + 1)
    } else if first == 0x80 {
        return Err(TransportError::CertParse("indefinite length".into()));
    } else {
        let n = (first & 0x7F) as usize;
        i += 1;
        if i + n > buf.len() || n > 4 {
            return Err(TransportError::CertParse("bad long length".into()));
        }
        let mut len = 0usize;
        for k in 0..n {
            len = (len << 8) | buf[i + k] as usize;
        }
        (len, i + n)
    };
    let end = content_start + len;
    if end > buf.len() {
        return Err(TransportError::CertParse("der truncated (content)".into()));
    }
    Ok((tag, content_start, len, end))
}

/// 提取证书 DER 中 SPKI 的完整 TLV 字节。
/// Certificate ::= SEQUENCE { tbsCertificate, sigAlg, sigValue }
/// tbs ::= SEQUENCE { [0] version?, serial, sig, issuer, validity, subject, SPKI, ... }
pub fn spki_der(cert_der: &[u8]) -> Result<Vec<u8>> {
    // 外层 SEQUENCE
    let (tag, tbs_start, _, _) = read_element(cert_der, 0)?;
    if tag != 0x30 {
        return Err(TransportError::CertParse("cert is not SEQUENCE".into()));
    }
    // tbsCertificate SEQUENCE
    let (tag, mut pos, _, _) = read_element(cert_der, tbs_start)?;
    if tag != 0x30 {
        return Err(TransportError::CertParse("tbs is not SEQUENCE".into()));
    }
    // tbs 内容从 pos 开始
    // 可选 [0] version（上下文构造标签 0xA0）
    let (tag0, _, _, next0) = read_element(cert_der, pos)?;
    if tag0 == 0xA0 {
        pos = next0;
    }
    // 跳过 serial, signature, issuer, validity, subject 共 5 个元素
    for _ in 0..5 {
        let (_, _, _, next) = read_element(cert_der, pos)?;
        pos = next;
    }
    // 第 6 个元素即 SPKI，取其完整 TLV
    let (tag, _cs, _len, next) = read_element(cert_der, pos)?;
    if tag != 0x30 {
        return Err(TransportError::CertParse("spki is not SEQUENCE".into()));
    }
    Ok(cert_der[pos..next].to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_spki_from_generated_cert() {
        // 用 rcgen 生成一个 Ed25519 自签证书验证提取逻辑
        let kp = rcgen::KeyPair::generate_for(&rcgen::PKCS_ED25519).unwrap();
        let mut params = rcgen::CertificateParams::new(vec!["uudesk.local".to_string()]).unwrap();
        params
            .distinguished_name
            .push(rcgen::DnType::CommonName, "test");
        params.not_before = rcgen::date_time_ymd(2025, 1, 1);
        params.not_after = rcgen::date_time_ymd(2035, 1, 1);
        let cert = params.self_signed(&kp).unwrap();
        let spki = spki_der(cert.der().as_ref()).unwrap();
        // Ed25519 SPKI 固定 44 字节：30 2A 30 05 06 03 2B 65 70 03 21 00 + 32B pub
        assert_eq!(spki.len(), 44);
        assert_eq!(
            &spki[..12],
            &[0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00]
        );
        // 与直接用公钥构造的 SPKI 一致
        let mut expect = Vec::new();
        expect.extend_from_slice(&[0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00]);
        expect.extend_from_slice(kp.public_key_raw());
        assert_eq!(spki, expect);
    }
}
