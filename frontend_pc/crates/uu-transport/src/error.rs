use thiserror::Error;

#[derive(Debug, Error)]
pub enum TransportError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("quic connect: {0}")]
    Connect(#[from] quinn::ConnectError),
    #[error("quic connection: {0}")]
    Connection(#[from] quinn::ConnectionError),
    #[error("quic write: {0}")]
    Write(#[from] quinn::WriteError),
    #[error("quic read: {0}")]
    Read(#[from] quinn::ReadError),
    #[error("quic read exact: {0}")]
    ReadExact(#[from] quinn::ReadExactError),
    #[error("quic read to end: {0}")]
    ReadToEnd(#[from] quinn::ReadToEndError),
    #[error("quic stream closed: {0}")]
    ClosedStream(#[from] quinn::ClosedStream),
    #[error("quic send datagram: {0}")]
    SendDatagram(#[from] quinn::SendDatagramError),
    #[error("quic rustls config: {0}")]
    NoCipherSuite(#[from] quinn::crypto::rustls::NoInitialCipherSuite),
    #[error("rustls: {0}")]
    Rustls(#[from] rustls::Error),
    #[error("rcgen: {0}")]
    Rcgen(#[from] rcgen::Error),
    #[error("certificate parse: {0}")]
    CertParse(String),
    #[error("spki pin mismatch: {0}")]
    PinMismatch(String),
    #[error("proto: {0}")]
    Proto(#[from] uu_proto::ProtoError),
    #[error("{0}")]
    Other(String),
}

pub type Result<T> = std::result::Result<T, TransportError>;
