import { useEffect, useState } from "react";
import { Check, Copy, Cpu, Radar, RefreshCw } from "lucide-react";
import { toast } from "../components/Toast";
import { Avatar } from "../components/Avatar";
import type { DeviceInfo } from "../lib/bridge";

const CODE_TTL = 600; // 10 分钟

function randomCode(): string {
  return String(Math.floor(100000 + Math.random() * 900000));
}

export function Devices({ device }: { device: DeviceInfo | null }) {
  const [code, setCode] = useState(randomCode);
  const [remain, setRemain] = useState(CODE_TTL);
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    const id = window.setInterval(() => {
      setRemain((r) => {
        if (r <= 1) {
          setCode(randomCode());
          return CODE_TTL;
        }
        return r - 1;
      });
    }, 1000);
    return () => window.clearInterval(id);
  }, []);

  const copyId = async () => {
    if (!device?.device_id) return;
    try {
      await navigator.clipboard.writeText(device.device_id);
      setCopied(true);
      toast("已复制设备 ID", "success");
      window.setTimeout(() => setCopied(false), 1600);
    } catch {
      toast("复制失败", "error");
    }
  };

  const R = 46;
  const C = 2 * Math.PI * R;
  const offset = C * (1 - remain / CODE_TTL);
  const mm = Math.floor(remain / 60);
  const ss = String(remain % 60).padStart(2, "0");

  return (
    <div className="h-full overflow-y-auto p-6">
      <div className="mx-auto grid max-w-[960px] gap-5 lg:grid-cols-2">
        {/* 本机信息 */}
        <section className="rounded-xl border border-line bg-card p-5 shadow-[0_4px_16px_rgba(31,35,41,0.06)]">
          <div className="mb-4 flex items-center gap-2">
            <Cpu size={17} className="text-brand" />
            <h3 className="text-sm font-semibold text-ink">本机信息</h3>
          </div>
          <div className="flex items-center gap-3.5">
            <Avatar name={device?.name ?? "本机"} size={48} />
            <div className="min-w-0">
              <p className="truncate text-sm font-medium text-ink">{device?.name ?? "本机"}</p>
              <p className="mt-0.5 text-xs text-ink-3">角色：PC · Windows</p>
            </div>
          </div>
          <div className="mt-4 flex items-center gap-2 rounded-lg bg-raised px-3 py-2.5">
            <span className="flex-1 truncate font-mono text-xs text-ink-2">
              设备 ID：{device?.device_id ?? "—"}
            </span>
            <button
              onClick={copyId}
              className="flex h-7 w-7 items-center justify-center rounded-md text-ink-3 transition-colors hover:bg-brand/10 hover:text-brand"
            >
              {copied ? <Check size={14} className="text-success" /> : <Copy size={14} />}
            </button>
          </div>
        </section>

        {/* 我的配对码 */}
        <section className="rounded-xl border border-line bg-card p-5 shadow-[0_4px_16px_rgba(31,35,41,0.06)]">
          <div className="mb-4 flex items-center justify-between">
            <h3 className="text-sm font-semibold text-ink">我的配对码</h3>
            <button
              onClick={() => {
                setCode(randomCode());
                setRemain(CODE_TTL);
                toast("已生成新配对码", "info");
              }}
              className="flex items-center gap-1 rounded-md px-2 py-1 text-xs text-ink-2 transition-colors hover:bg-raised hover:text-brand"
            >
              <RefreshCw size={13} />
              刷新
            </button>
          </div>
          <div className="flex items-center justify-center gap-6 py-2">
            <div className="font-mono text-[40px] font-bold tracking-[0.18em] text-ink tabular-nums">
              {code.slice(0, 3)}
              <span className="mx-1 text-ink-3">·</span>
              {code.slice(3)}
            </div>
            <div className="relative h-[112px] w-[112px]">
              <svg viewBox="0 0 112 112" className="h-full w-full -rotate-90">
                <circle cx="56" cy="56" r={R} fill="none" stroke="var(--color-line)" strokeWidth="7" />
                <circle
                  cx="56"
                  cy="56"
                  r={R}
                  fill="none"
                  stroke="var(--color-brand)"
                  strokeWidth="7"
                  strokeLinecap="round"
                  strokeDasharray={C}
                  strokeDashoffset={offset}
                  style={{ transition: "stroke-dashoffset 0.6s linear" }}
                />
              </svg>
              <div className="absolute inset-0 flex flex-col items-center justify-center">
                <span className="text-lg font-semibold tabular-nums text-ink">
                  {mm}:{ss}
                </span>
                <span className="text-[10px] text-ink-3">后过期</span>
              </div>
            </div>
          </div>
          <p className="mt-2 text-center text-xs text-ink-3">对方在「远程控制」页输入此 6 位配对码即可连接本机</p>
        </section>

        {/* 附近设备 */}
        <section className="rounded-xl border border-line bg-card p-5 shadow-[0_4px_16px_rgba(31,35,41,0.06)] lg:col-span-2">
          <div className="mb-4 flex items-center gap-2">
            <Radar size={17} className="text-brand" />
            <h3 className="text-sm font-semibold text-ink">附近设备</h3>
          </div>
          <div className="flex flex-col items-center justify-center rounded-xl border border-dashed border-line py-14">
            <Radar size={36} className="text-ink-3/50" />
            <p className="mt-3 text-sm text-ink-2">暂未发现附近设备</p>
            <p className="mt-1 text-xs text-ink-3">请确认对方已开启「本机被控」，并与本机处于同一网络</p>
          </div>
        </section>
      </div>
    </div>
  );
}
