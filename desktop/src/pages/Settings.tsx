import { Info, Moon, Server, Sun, Video } from "lucide-react";
import { setSettings, useSettings } from "../lib/settings";
import { toast } from "../components/Toast";
import { isTauri } from "../lib/bridge";

export function Settings() {
  const settings = useSettings();

  return (
    <div className="h-full overflow-y-auto p-6">
      <div className="mx-auto max-w-[680px] space-y-5">
        {/* 连接 */}
        <section className="rounded-xl border border-line bg-card p-5 shadow-[0_4px_16px_rgba(31,35,41,0.06)]">
          <div className="mb-4 flex items-center gap-2">
            <Server size={17} className="text-brand" />
            <h3 className="text-sm font-semibold text-ink">连接</h3>
          </div>
          <label className="text-xs font-medium text-ink-2">服务器地址</label>
          <input
            value={settings.serverUrl}
            onChange={(e) => setSettings({ serverUrl: e.target.value })}
            placeholder="http://127.0.0.1:8080"
            className="mt-1.5 h-10 w-full rounded-lg border border-line bg-raised px-3 font-mono text-sm text-ink outline-none transition-colors focus:border-brand focus:bg-card"
          />
          <label className="mt-4 block text-xs font-medium text-ink-2">默认会议号</label>
          <div className="relative mt-1.5">
            <Video size={15} className="absolute left-3 top-1/2 -translate-y-1/2 text-ink-3" />
            <input
              value={settings.defaultRoom}
              onChange={(e) => setSettings({ defaultRoom: e.target.value })}
              placeholder="demo-room"
              className="h-10 w-full rounded-lg border border-line bg-raised pl-9 pr-3 text-sm text-ink outline-none transition-colors focus:border-brand focus:bg-card"
            />
          </div>
          <p className="mt-2 text-xs text-ink-3">修改后自动保存，下次连接 / 加入会议时生效</p>
        </section>

        {/* 外观 */}
        <section className="rounded-xl border border-line bg-card p-5 shadow-[0_4px_16px_rgba(31,35,41,0.06)]">
          <div className="mb-4 flex items-center gap-2">
            <Sun size={17} className="text-brand" />
            <h3 className="text-sm font-semibold text-ink">外观</h3>
          </div>
          <div className="grid grid-cols-2 gap-3">
            {(["light", "dark"] as const).map((t) => (
              <button
                key={t}
                onClick={() => {
                  setSettings({ theme: t });
                  toast(t === "dark" ? "已切换到深色主题" : "已切换到浅色主题", "success");
                }}
                className={`flex items-center gap-3 rounded-xl border p-3.5 text-left transition-all duration-150 ${
                  settings.theme === t
                    ? "border-brand bg-brand/8 ring-1 ring-brand/30"
                    : "border-line bg-raised hover:border-brand/50"
                }`}
              >
                <span
                  className={`flex h-9 w-9 items-center justify-center rounded-lg ${
                    t === "light" ? "bg-[#f2f3f5] text-[#ff8800]" : "bg-[#17181a] text-[#7aa5ff]"
                  }`}
                >
                  {t === "light" ? <Sun size={17} /> : <Moon size={17} />}
                </span>
                <div>
                  <p className="text-sm font-medium text-ink">{t === "light" ? "浅色" : "深色"}</p>
                  <p className="text-xs text-ink-3">{t === "light" ? "明亮清爽" : "夜间护眼"}</p>
                </div>
              </button>
            ))}
          </div>
        </section>

        {/* 关于 */}
        <section className="rounded-xl border border-line bg-card p-5 shadow-[0_4px_16px_rgba(31,35,41,0.06)]">
          <div className="mb-4 flex items-center gap-2">
            <Info size={17} className="text-brand" />
            <h3 className="text-sm font-semibold text-ink">关于</h3>
          </div>
          <div className="flex items-center gap-3">
            <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-brand text-sm font-bold text-white">
              UU
            </div>
            <div>
              <p className="text-sm font-semibold text-ink">UUDesk</p>
              <p className="text-xs text-ink-3">版本 0.1.0 · Tauri v2 + React + LiveKit</p>
            </div>
          </div>
          <p className="mt-3 text-xs leading-relaxed text-ink-3">
            集视频会议与远程控制于一体的桌面客户端。
            {isTauri ? "当前运行于 Tauri 桌面环境。" : "当前运行于浏览器演示环境，桌面能力以演示模式呈现。"}
          </p>
        </section>
      </div>
    </div>
  );
}
