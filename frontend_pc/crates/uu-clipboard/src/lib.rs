//! 剪贴板同步（uu-proto.md §3.4）：arboard + 轮询检测本地变更。
//! `clip_set{text,ts}` 双向发送，以较大 ts 为准（ts 判定由上层处理）。

use thiserror::Error;

#[derive(Debug, Error)]
pub enum ClipError {
    #[error("clipboard init: {0}")]
    Init(String),
    #[error("clipboard read: {0}")]
    Read(String),
    #[error("clipboard write: {0}")]
    Write(String),
}

pub type Result<T> = std::result::Result<T, ClipError>;

/// 本地剪贴板桥：轮询发现变更上抛；写入远端内容时抑制回声。
pub struct ClipboardBridge {
    clip: arboard::Clipboard,
    last: String,
}

impl ClipboardBridge {
    pub fn new() -> Result<Self> {
        let mut clip =
            arboard::Clipboard::new().map_err(|e| ClipError::Init(e.to_string()))?;
        let last = clip.get_text().unwrap_or_default();
        Ok(Self { clip, last })
    }

    /// 轮询一次：本地文本相对上次快照变化时返回 Some(new_text)
    pub fn poll_local(&mut self) -> Option<String> {
        match self.clip.get_text() {
            // get_text 需要 &mut self（arboard 3.7）
            Ok(t) if t != self.last => {
                self.last = t.clone();
                Some(t)
            }
            _ => None,
        }
        // 非文本/空剪贴板读取失败视为无变化
    }

    /// 写入远端同步来的文本，并更新快照避免回声
    pub fn apply_remote(&mut self, text: &str) -> Result<()> {
        self.clip
            .set_text(text.to_string())
            .map_err(|e| ClipError::Write(e.to_string()))?;
        self.last = text.to_string();
        Ok(())
    }

    /// 当前本地文本快照
    pub fn current(&self) -> &str {
        &self.last
    }
}

/// 轮询任务：每 interval 检查一次本地变更并经通道上抛
pub fn spawn_poller(
    interval: std::time::Duration,
    tx: tokio::sync::mpsc::UnboundedSender<String>,
) -> Result<tokio::task::JoinHandle<()>> {
    let mut bridge = ClipboardBridge::new()?;
    Ok(tokio::spawn(async move {
        let mut tick = tokio::time::interval(interval);
        loop {
            tick.tick().await;
            if let Some(text) = bridge.poll_local() {
                if tx.send(text).is_err() {
                    return;
                }
            }
        }
    }))
}
