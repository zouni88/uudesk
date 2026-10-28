//! 输入注入（uu-proto.md §3.2 / 附录 A）：enigo + Windows VK 码转换。

pub mod error;
pub mod inject;
pub mod vk;

pub use error::{InputError, Result};
pub use inject::InputInjector;
pub use vk::{vk_to_key, MOD_ALT, MOD_CTRL, MOD_META, MOD_SHIFT};
