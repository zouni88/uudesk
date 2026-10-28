import { Cpu, MonitorSmartphone, Settings, Video } from "lucide-react";
import { Avatar } from "./Avatar";
import { Tooltip } from "./Tooltip";
import type { DeviceInfo } from "../lib/bridge";

export type PageKey = "meeting" | "remote" | "devices" | "settings";

const NAV: { key: PageKey; label: string; icon: typeof Video }[] = [
  { key: "meeting", label: "会议", icon: Video },
  { key: "remote", label: "远程控制", icon: MonitorSmartphone },
  { key: "devices", label: "设备", icon: Cpu },
  { key: "settings", label: "设置", icon: Settings },
];

interface SidebarProps {
  active: PageKey;
  onChange: (key: PageKey) => void;
  device: DeviceInfo | null;
}

export function Sidebar({ active, onChange, device }: SidebarProps) {
  return (
    <nav className="flex w-[68px] shrink-0 flex-col items-center bg-nav py-4">
      {/* Logo */}
      <div className="mb-6 flex h-9 w-9 items-center justify-center rounded-lg bg-brand text-[13px] font-bold text-white select-none">
        UU
      </div>

      {/* 导航项 */}
      <div className="flex flex-1 flex-col items-center gap-2">
        {NAV.map(({ key, label, icon: Icon }) => {
          const isActive = active === key;
          return (
            <Tooltip key={key} label={label} side="right" dark>
              <button
                onClick={() => onChange(key)}
                className={`relative flex h-11 w-11 items-center justify-center rounded-lg transition-colors duration-150 ${
                  isActive
                    ? "bg-nav-hover text-brand"
                    : "text-nav-item hover:bg-nav-hover hover:text-white"
                }`}
              >
                {isActive && (
                  <span className="absolute -left-[13px] top-1/2 h-5 w-[3px] -translate-y-1/2 rounded-full bg-brand" />
                )}
                <Icon size={20} strokeWidth={isActive ? 2.2 : 1.8} />
              </button>
            </Tooltip>
          );
        })}
      </div>

      {/* 底部头像 */}
      <Tooltip label={device?.name ?? "本机"} side="right" dark>
        <div className="mt-2">
          <Avatar name={device?.name ?? "U"} size={36} />
        </div>
      </Tooltip>
    </nav>
  );
}
