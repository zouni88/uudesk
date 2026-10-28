//! 会议令牌获取（§10.1）：`POST /api/meeting/token {room, identity, can_publish}`
//! → `{token, server_url}`。客户端不持有 API secret。

use crate::error::{MeetingError, Result};

#[derive(Clone, Debug, serde::Deserialize)]
pub struct TokenResponse {
    pub token: String,
    /// LiveKit 信令地址，如 `wss://host:7881`
    pub server_url: String,
}

/// 阻塞式取 token（调用方放 spawn_blocking / 专用线程）。
/// `signaling_url` 为服务器基址（http/https），identity = device_id。
pub fn fetch_token(
    signaling_url: &str,
    room: &str,
    identity: &str,
    can_publish: bool,
) -> Result<TokenResponse> {
    let url = format!(
        "{}/api/meeting/token",
        signaling_url.trim_end_matches('/')
    );
    let body = serde_json::json!({
        "room": room,
        "identity": identity,
        "can_publish": can_publish,
    });
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(std::time::Duration::from_secs(10))
        .timeout_read(std::time::Duration::from_secs(15))
        .build();
    let resp = agent
        .post(&url)
        .send_json(body)
        .map_err(|e| MeetingError::Http(e.to_string()))?;
    let tr: TokenResponse = resp
        .into_json()
        .map_err(|e| MeetingError::Http(format!("bad token resp: {e}")))?;
    if tr.token.is_empty() || tr.server_url.is_empty() {
        return Err(MeetingError::Http("token resp missing fields".into()));
    }
    Ok(tr)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_resp_deserialize() {
        let t: TokenResponse =
            serde_json::from_str(r#"{"token":"abc","server_url":"wss://h:7881"}"#).unwrap();
        assert_eq!(t.server_url, "wss://h:7881");
    }
}
