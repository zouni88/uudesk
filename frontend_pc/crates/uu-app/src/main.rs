//! UUDesk PC 主窗口：远程控制页（§1–§8，保持原状）+ 会议页（§10）。

mod meeting;

use eframe::egui;
use meeting::MeetingPage;

#[derive(PartialEq, Eq)]
enum Tab {
    Remote,
    Meeting,
}

struct UuApp {
    tab: Tab,
    meeting: MeetingPage,
}

impl UuApp {
    fn new(device_id: String) -> Self {
        Self {
            tab: Tab::Meeting,
            meeting: MeetingPage::new(device_id),
        }
    }
}

impl eframe::App for UuApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.meeting.update(ctx);
        match self.tab {
            Tab::Meeting => {
                egui::TopBottomPanel::top("top").show(ctx, |ui| {
                    tab_bar(ui, &mut self.tab);
                    ui.separator();
                    self.meeting.top_bar(ui);
                });
                egui::SidePanel::right("side").default_width(280.0).show(ctx, |ui| {
                    self.meeting.side_panel(ui);
                });
                egui::CentralPanel::default().show(ctx, |ui| {
                    self.meeting.central(ui);
                });
            }
            Tab::Remote => {
                egui::TopBottomPanel::top("top").show(ctx, |ui| {
                    tab_bar(ui, &mut self.tab);
                });
                egui::CentralPanel::default().show(ctx, |ui| {
                    ui.label(
                        "远程控制（QUIC，§1–§8）：沿用现有实现，页面保持不变。\n\
                         设备身份 device_id 见「会议」页状态栏。",
                    );
                });
            }
        }
    }
}

fn tab_bar(ui: &mut egui::Ui, tab: &mut Tab) {
    ui.horizontal(|ui| {
        ui.selectable_value(tab, Tab::Remote, "远程控制");
        ui.selectable_value(tab, Tab::Meeting, "会议");
    });
}

fn main() -> eframe::Result {
    // 设备身份（§1）：与远程控制共用同一 device_id（§10.1 identity=device_id）
    let dir = uu_meeting::MeetingConfig::config_path()
        .parent()
        .map(|p| p.join("identity"))
        .unwrap_or_else(|| std::path::PathBuf::from("uu_identity"));
    let device_id = uu_transport::Identity::load_or_create(&dir)
        .map(|i| i.device_id)
        .unwrap_or_else(|e| format!("unknown({e})"));

    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_inner_size([1100.0, 720.0]),
        ..Default::default()
    };
    eframe::run_native(
        "UUDesk",
        options,
        Box::new(move |_cc| Ok(Box::new(UuApp::new(device_id)))),
    )
}
