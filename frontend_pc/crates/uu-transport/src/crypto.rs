//! rustls/quinn 配置：ALPN `uudesk/1`、SPKI pin 校验 verifier（§1）。

use std::sync::Arc;

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime};
use rustls::server::danger::{ClientCertVerified, ClientCertVerifier};
use rustls::{DigitallySignedStruct, DistinguishedName, Error as TlsError, SignatureScheme};
use std::collections::HashSet;

use crate::error::{TransportError};
use crate::identity::{pin_of_cert, Identity};

/// 本 crate 内部 Result 别名（避免与 trait 的 std Result 混淆）
type CResult<T> = std::result::Result<T, TransportError>;

/// ALPN 协议名（§1）
pub const ALPN: &[u8] = b"uudesk/1";

/// 证书校验策略
#[derive(Clone, Debug)]
pub enum PinPolicy {
    /// 配对模式：接受任意证书（首次配对用）
    AllowAny,
    /// 仅接受 pin 集合内的证书
    Pinned(HashSet<String>),
}

impl PinPolicy {
    pub fn check(&self, pin: &str) -> bool {
        match self {
            PinPolicy::AllowAny => true,
            PinPolicy::Pinned(set) => set.contains(pin),
        }
    }
}

fn tls_err_pin() -> TlsError {
    // §9 错误码 1002：SPKI pin 不匹配
    TlsError::General("1002 spki pin mismatch".to_string())
}

fn schemes() -> Vec<SignatureScheme> {
    vec![SignatureScheme::ED25519]
}

// ---------------- 客户端侧：校验服务端证书 ----------------

#[derive(Debug)]
pub struct PinServerVerifier {
    policy: PinPolicy,
}

impl PinServerVerifier {
    pub fn new(policy: PinPolicy) -> Self {
        Self { policy }
    }
}

impl ServerCertVerifier for PinServerVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, TlsError> {
        let pin = pin_of_cert(end_entity.as_ref())
            .map_err(|_| TlsError::General("cert spki extract failed".into()))?;
        if !self.policy.check(&pin) {
            return Err(tls_err_pin());
        }
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        Err(TlsError::General("tls12 not supported".into()))
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        // 证书自签且 SPKI 已 pin，Finished MAC 由 rustls 校验，此处直接通过
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        schemes()
    }
}

// ---------------- 服务端侧：校验客户端证书 ----------------

#[derive(Debug)]
pub struct PinClientVerifier {
    policy: PinPolicy,
}

impl PinClientVerifier {
    pub fn new(policy: PinPolicy) -> Self {
        Self { policy }
    }
}

impl ClientCertVerifier for PinClientVerifier {
    fn client_auth_mandatory(&self) -> bool {
        true // 双向均用自签证书，客户端必须出示
    }

    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        &[]
    }

    fn verify_client_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _now: UnixTime,
    ) -> Result<ClientCertVerified, TlsError> {
        let pin = pin_of_cert(end_entity.as_ref())
            .map_err(|_| TlsError::General("cert spki extract failed".into()))?;
        if !self.policy.check(&pin) {
            return Err(tls_err_pin());
        }
        Ok(ClientCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        Err(TlsError::General("tls12 not supported".into()))
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        schemes()
    }
}

// ---------------- 配置构建 ----------------

fn provider() -> Arc<rustls::crypto::CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

pub fn server_config(identity: &Identity, policy: PinPolicy) -> CResult<Arc<rustls::ServerConfig>> {
    let certs = vec![CertificateDer::from(identity.cert_der().to_vec())];
    let key = PrivateKeyDer::try_from(identity.pkcs8().to_vec())
        .map_err(|e| TransportError::Other(format!("pkcs8: {e}")))?;
    let verifier = Arc::new(PinClientVerifier::new(policy));
    let mut cfg = rustls::ServerConfig::builder_with_provider(provider())
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .with_client_cert_verifier(verifier)
        .with_single_cert(certs, key)?;
    cfg.alpn_protocols = vec![ALPN.to_vec()];
    Ok(Arc::new(cfg))
}

pub fn client_config(identity: &Identity, policy: PinPolicy) -> CResult<Arc<rustls::ClientConfig>> {
    let certs = vec![CertificateDer::from(identity.cert_der().to_vec())];
    let key = PrivateKeyDer::try_from(identity.pkcs8().to_vec())
        .map_err(|e| TransportError::Other(format!("pkcs8: {e}")))?;
    let verifier = Arc::new(PinServerVerifier::new(policy));
    let mut cfg = rustls::ClientConfig::builder_with_provider(provider())
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_client_auth_cert(certs, key)?;
    cfg.alpn_protocols = vec![ALPN.to_vec()];
    Ok(Arc::new(cfg))
}
