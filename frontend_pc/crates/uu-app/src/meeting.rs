//! 会议页（§10）：加入/离开、成员视频宫格、静音、屏幕共享、聊天、举手、REC。

use std::collections::HashMap;
use std::sync::mpsc::{channel, Receiver};

use eframe::egui;
use egui::{ColorImage, Context, TextureHandle};
use tokio::sync::mpsc::UnboundedReceiver;
use uu_meeting::{create_client, fetch_token, JoinOptions, MeetingConfig, RoomClient, RoomEvent};

/// token 获取结果（后台线程 → UI 线程）
enum JoinOutcome {
    Ok(JoinOptions),
    Err(String),
}

pub struct Member {
    pub display_name: String,
    pub hand_raised: bool,
    pub speaking: bool,
}

pub struct MeetingPage {
    // 输入区
    server_addr: String,
    room: String,
    display_name: String,
    // 会议状态
    device_id: String,
    client: Box<dyn RoomClient>,
    events_rx: Option<UnboundedReceiver<RoomEvent>>,
    join_rx: Option<Receiver<JoinOutcome>>,
    joined: bool,
    connecting: bool,
    recording: bool,
    mic_muted: bool,
    screen_sharing: bool,
    hand_raised: bool,
    status: String,
    members: HashMap<String, Member>,
    /// sid -> (identity, texture)
    video_tiles: HashMap<String, (String, TextureHandle)>,
    chat_log: Vec<(String, String)>,
    chat_input: String,
}

impl MeetingPage {
    pub fn new(device_id: String) -> Self {
        let cfg = MeetingConfig::load();
        let mut client = create_client();
        let events_rx = client.take_events();
        Self {
            server_addr: cfg.signaling_url,
            room: cfg.room,
            display_name: cfg.display_name,
            device_id,
            client,
            events_rx,
            join_rx: None,
            joined: false,
            connecting: false,
            recording: false,
            mic_muted: false,
            screen_sharing: false,
            hand_raised: false,
            status: "未加入会议".into(),
            members: HashMap::new(),
            video_tiles: HashMap::new(),
            chat_log: Vec::new(),
            chat_input: String::new(),
        }
    }

    fn name_of(&self, identity: &str) -> String {
        self.members
            .get(identity)
            .map(|m| m.display_name.clone())
            .unwrap_or_else(|| identity.to_string())
    }

    fn pump_events(&mut self, ctx: &Context) {
        // 取出 receiver 避免循环内 self 被可变借用，name_of 等只读方法才能调用
        let Some(mut rx) = self.events_rx.take() else { return };
        let mut budget = 256usize;
        while budget > 0 {
            let Ok(ev) = rx.try_recv() else { break };
            budget -= 1;
            match ev {
                RoomEvent::Connected { room, recording } => {
                    self.joined = true;
                    self.connecting = false;
                    self.recording = recording;
                    self.status = format!("已加入 {room}");
                }
                RoomEvent::Disconnected { reason } => {
                    self.joined = false;
                    self.connecting = false;
                    self.recording = false;
                    self.video_tiles.clear();
                    self.members.clear();
                    self.status = format!("已离开会议（{reason}）");
                }
                RoomEvent::ParticipantJoined { identity, display_name } => {
                    let name = if display_name.is_empty() {
                        identity.clone()
                    } else {
                        display_name
                    };
                    self.members.entry(identity).or_insert(Member {
                        display_name: name,
                        hand_raised: false,
                        speaking: false,
                    });
                }
                RoomEvent::ParticipantLeft { identity } => {
                    self.members.remove(&identity);
                    self.video_tiles.retain(|_, (id, _)| *id != identity);
                }
                RoomEvent::TrackPublished { .. } | RoomEvent::TrackUnpublished { .. } => {}
                RoomEvent::VideoFrame { identity, sid, frame } => {
                    let size = [frame.width as usize, frame.height as usize];
                    if size[0] == 0 || size[1] == 0 {
                        continue;
                    }
                    let img = ColorImage::from_rgba_unmultiplied(size, &frame.rgba);
                    match self.video_tiles.get_mut(&sid) {
                        Some((_, tex)) => tex.set(img, egui::TextureOptions::LINEAR),
                        None => {
                            let tex = ctx.load_texture(
                                format!("lk-{sid}"),
                                img,
                                egui::TextureOptions::LINEAR,
                            );
                            self.video_tiles.insert(sid, (identity, tex));
                        }
                    }
                }
                RoomEvent::Speaking { identity, active } => {
                    if let Some(m) = self.members.get_mut(&identity) {
                        m.speaking = active;
                    }
                }
                RoomEvent::Chat { identity, text } => {
                    let name = self.name_of(&identity);
                    self.chat_log.push((name, text));
                }
                RoomEvent::RaiseHand { identity, raised } => {
                    if let Some(m) = self.members.get_mut(&identity) {
                        m.hand_raised = raised;
                    }
                    if identity == self.device_id {
                        self.hand_raised = raised;
                    }
                }
                RoomEvent::Reaction { identity, emoji } => {
                    let name = self.name_of(&identity);
                    self.chat_log.push((name, emoji));
                }
                RoomEvent::Error { message } => {
                    self.status = format!("错误：{message}");
                    self.connecting = false;
                }
            }
        }
        self.events_rx = Some(rx);
    }

    fn pump_join_outcome(&mut self) {
        let mut done = None;
        if let Some(rx) = self.join_rx.as_ref() {
            if let Ok(out) = rx.try_recv() {
                done = Some(out);
            }
        }
        if let Some(out) = done {
            self.join_rx = None;
            match out {
                JoinOutcome::Ok(opts) => {
                    self.status = "连接 LiveKit…".into();
                    match self.client.join(opts) {
                        Ok(()) => self.connecting = true,
                        Err(e) => self.status = format!("join 失败：{e}"),
                    }
                }
                JoinOutcome::Err(e) => {
                    self.status = format!("取 token 失败：{e}");
                    self.connecting = false;
                }
            }
        }
    }

    fn do_join(&mut self) {
        if self.connecting || self.joined {
            return;
        }
        let cfg = MeetingConfig {
            signaling_url: self.server_addr.trim().to_string(),
            room: self.room.trim().to_string(),
            display_name: self.display_name.trim().to_string(),
        };
        if cfg.room.is_empty() {
            self.status = "房间号不能为空".into();
            return;
        }
        let _ = cfg.save();
        let (tx, rx) = channel::<JoinOutcome>();
        self.join_rx = Some(rx);
        self.status = format!("向 {} 取 token…", cfg.signaling_url);
        self.connecting = true;
        let identity = self.device_id.clone();
        std::thread::spawn(move || {
            let out = match fetch_token(&cfg.signaling_url, &cfg.room, &identity, true) {
                Ok(t) => JoinOutcome::Ok(JoinOptions {
                    server_url: t.server_url,
                    token: t.token,
                    room: cfg.room.clone(),
                    identity: identity.clone(),
                    display_name: cfg.display_name.clone(),
                    can_publish: true,
                }),
                Err(e) => JoinOutcome::Err(e.to_string()),
            };
            let _ = tx.send(out);
        });
    }

    fn do_leave(&mut self) {
        self.client.leave();
        self.joined = false;
        self.connecting = false;
        self.status = "已离开会议".into();
    }

    fn send_chat(&mut self) {
        let text = self.chat_input.trim().to_string();
        if text.is_empty() {
            return;
        }
        if self.client.send_chat(&text).is_ok() {
            self.chat_input.clear();
        }
    }

    /// 会议页主体（CentralPanel 之外的面板由 main.rs 组织）
    pub fn top_bar(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            ui.label("服务器");
            ui.add(
                egui::TextEdit::singleline(&mut self.server_addr)
                    .hint_text("http://host:8080")
                    .desired_width(180.0),
            );
            ui.label("房间");
            ui.add(
                egui::TextEdit::singleline(&mut self.room)
                    .hint_text("房间号")
                    .desired_width(100.0),
            );
            ui.label("显示名");
            ui.add(
                egui::TextEdit::singleline(&mut self.display_name)
                    .hint_text("显示名")
                    .desired_width(120.0),
            );
            if !self.joined {
                if ui.button("加入会议").clicked() {
                    self.do_join();
                }
            } else if ui.button("离开会议").clicked() {
                self.do_leave();
            }
            if self.recording {
                ui.colored_label(egui::Color32::RED, "● REC");
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                ui.label(&self.status);
            });
        });
        ui.horizontal(|ui| {
            let muted = self.mic_muted;
            if ui
                .selectable_label(muted, if muted { "🎤 已静音" } else { "🎤 麦克风开" })
                .clicked()
            {
                if self.client.set_mic_muted(!muted).is_ok() {
                    self.mic_muted = !muted;
                }
            }
            let sharing = self.screen_sharing;
            if ui
                .selectable_label(
                    sharing,
                    if sharing { "🖥 停止共享" } else { "🖥 共享屏幕" },
                )
                .clicked()
            {
                if self.client.set_screen_share(!sharing).is_ok() {
                    self.screen_sharing = !sharing;
                }
            }
            let raised = self.hand_raised;
            if ui
                .selectable_label(raised, if raised { "✋ 举手取消" } else { "✋ 举手" })
                .clicked()
            {
                if self.client.raise_hand(!raised).is_ok() {
                    self.hand_raised = !raised;
                }
            }
            for emoji in ["👍", "👏", "🎉"] {
                if ui.button(emoji).clicked() {
                    let _ = self.client.send_reaction(emoji);
                }
            }
        });
    }

    pub fn central(&mut self, ui: &mut egui::Ui) {
        if self.video_tiles.is_empty() {
            ui.centered_and_justified(|ui| {
                ui.label(if self.joined {
                    "会议中，暂无远端视频"
                } else {
                    "未加入会议（当前为 mock 实现时，加入后会显示演示视频）"
                });
            });
            return;
        }
        // 视频宫格：每行 2 列
        let tiles: Vec<(String, TextureHandle)> = self
            .video_tiles
            .iter()
            .map(|(_sid, (id, tex))| (id.clone(), tex.clone()))
            .collect::<Vec<(String, TextureHandle)>>();
        let avail = ui.available_width();
        let cell_w = (avail - 16.0) / 2.0;
        egui::Grid::new("lk-grid")
            .num_columns(2)
            .spacing([8.0, 8.0])
            .show(ui, |ui| {
                for (i, (identity, tex)) in tiles.iter().enumerate() {
                    let name = self.name_of(identity);
                    let raised = self
                        .members
                        .get(identity)
                        .map(|m| m.hand_raised)
                        .unwrap_or(false);
                    let label = if raised { format!("✋ {name}") } else { name };
                    ui.group(|ui| {
                        ui.label(label);
                        let (rect, _) = ui.allocate_exact_size(
                            egui::vec2(cell_w, cell_w * 9.0 / 16.0),
                            egui::Sense::hover(),
                        );
                        ui.painter().image(
                            tex.id(),
                            rect,
                            egui::Rect::from_min_max(egui::pos2(0.0, 0.0), egui::pos2(1.0, 1.0)),
                            egui::Color32::WHITE,
                        );
                    });
                    if i % 2 == 1 {
                        ui.end_row();
                    }
                }
            });
    }

    pub fn side_panel(&mut self, ui: &mut egui::Ui) {
        ui.heading("成员");
        if self.members.is_empty() {
            ui.label("（无）");
        }
        for (id, m) in self.members.iter() {
            let _ = id;
            let mark = if m.hand_raised { " ✋" } else { "" };
            let speak = if m.speaking { " 🗣" } else { "" };
            ui.label(format!("{}{}{}", m.display_name, mark, speak));
        }
        ui.separator();
        ui.heading("聊天");
        egui::ScrollArea::vertical()
            .id_salt("lk-chat")
            .auto_shrink([false, false])
            .stick_to_bottom(true)
            .show(ui, |ui| {
                for (name, text) in &self.chat_log {
                    ui.label(format!("{name}: {text}"));
                }
            });
        ui.horizontal(|ui| {
            let resp = ui.add(
                egui::TextEdit::singleline(&mut self.chat_input)
                    .hint_text("输入消息…")
                    .desired_width(ui.available_width() - 50.0),
            );
            let enter = resp.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter));
            if enter || ui.button("发送").clicked() {
                self.send_chat();
            }
        });
    }

    /// 每帧驱动：事件泵 + 定时重绘
    pub fn update(&mut self, ctx: &Context) {
        self.pump_join_outcome();
        self.pump_events(ctx);
        if self.joined || self.connecting {
            ctx.request_repaint_after(std::time::Duration::from_millis(100));
        }
    }
}
