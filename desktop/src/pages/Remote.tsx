import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import {
  Eye,
  KeyRound,
  LogOut,
  Maximize2,
  MonitorUp,
  MousePointer2,
  Play,
  RefreshCw,
  Wifi,
} from "lucide-react";
import { bridge, demoEmit, isTauri, type ConnectResult, type DeviceInfo } from "../lib/bridge";
import { getSettings } from "../lib/settings";
import { toast } from "../components/Toast";
import { Tooltip } from "../components/Tooltip";
import { CodeInput } from "../components/remote/CodeInput";
import { DemoDesktop } from "../components/remote/DemoDesktop";
import { vkFromCode } from "../lib/vk";

type ConnState = "idle" | "connecting" | "connected" | "demo";

const PHASES: { key: string; label: string }[] = [
  { key: "registering", label: "注册信令服务" },
  { key: "signaling", label: "信令交换" },
  { key: "punching", label: "NAT 打洞" },
  { key: "connected", label: "建立连接" },
];

interface RemoteProps {
  device: DeviceInfo | null;
}

export function Remote({ device }: RemoteProps) {
  const [tab, setTab] = useState<"code" | "direct">("code");
  const [code, setCode] = useState("");
  const [addr, setAddr] = useState("");
  const [pin, setPin] = useState("");
  const [conn, setConn] = useState<ConnState>("idle");
  const [phase, setPhase] = useState("registering");
  const [peer, setPeer] = useState<ConnectResult | null>(null);
  const [fps, setFps] = useState(0);
  const [mouseMode, setMouseMode] = useState<"control" | "view">("control");
  const [controlled, setControlled] = useState(false);

  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const stageRef = useRef<HTMLDivElement | null>(null);
  const frameTimesRef = useRef<number[]>([]);
  const lastMoveRef = useRef(0);
  const mouseModeRef = useRef<"control" | "view">("control");
  mouseModeRef.current = mouseMode;
  const connRef = useRef<ConnState>("idle");
  connRef.current = conn;

  // ---------------- 状态事件（uu://status） ----------------

  useEffect(() => {
    let alive = true;
    let un: (() => void) | undefined;
    bridge
      .onStatus((s) => {
        if (!alive) return;
        if (s.phase) setPhase(s.phase);
        if (!s.connected && s.phase === "error") {
          toast(s.msg || "连接失败", "error");
          setConn("idle");
        }
      })
      .then((fn) => {
        if (!alive) fn();
        else un = fn;
      });
    return () => {
      alive = false;
      un?.();
    };
  }, []);

  // ---------------- 真实帧渲染 ----------------

  const renderFrame = useCallback((jpegB64: string, w: number, h: number) => {
    try {
      const bin = Uint8Array.from(atob(jpegB64), (c) => c.charCodeAt(0));
      const blob = new Blob([bin], { type: "image/jpeg" });
      createImageBitmap(blob).then((bmp) => {
        const canvas = canvasRef.current;
        if (!canvas) {
          bmp.close();
          return;
        }
        if (canvas.width !== w || canvas.height !== h) {
          canvas.width = w;
          canvas.height = h;
        }
        const ctx = canvas.getContext("2d");
        if (ctx) ctx.drawImage(bmp, 0, 0);
        bmp.close();
        const now = performance.now();
        frameTimesRef.current = frameTimesRef.current.filter((t) => now - t < 1000);
        frameTimesRef.current.push(now);
      });
    } catch {
      /* 忽略坏帧 */
    }
  }, []);

  useEffect(() => {
    if (conn !== "connected") return;
    let un: (() => void) | undefined;
    let alive = true;
    bridge
      .onFrame((f) => {
        if (!alive) return;
        renderFrame(f.jpeg_b64, f.w, f.h);
      })
      .then((fn) => {
        if (!alive) fn();
        else un = fn;
      });
    const id = window.setInterval(() => {
      setFps(frameTimesRef.current.filter((t) => performance.now() - t < 1000).length);
    }, 500);
    return () => {
      alive = false;
      un?.();
      window.clearInterval(id);
    };
  }, [conn, renderFrame]);

  // ---------------- 连接动作 ----------------

  const startConnect = useCallback(
    async (kind: "code" | "direct") => {
      if (!isTauri) {
        toast("当前为浏览器环境，请使用「进入演示画面」", "info");
        return;
      }
      setConn("connecting");
      setPhase("registering");
      try {
        const result =
          kind === "code"
            ? await bridge.remoteConnect(getSettings().serverUrl, code)
            : await bridge.remoteConnectDirect(addr, pin);
        setPeer(result);
        setConn("connected");
        toast(`已连接到 ${result.peer_name}`, "success");
      } catch (e) {
        toast(`连接失败：${String(e)}`, "error");
        setConn("idle");
      }
    },
    [addr, code, pin],
  );

  const enterDemo = () => {
    setPeer({ peer_name: "邹妮的电脑", peer_device_id: "demo-peer-01" });
    setConn("demo");
    demoEmit("uu://status", { connected: true, phase: "connected", msg: "" });
  };

  const disconnect = () => {
    bridge.remoteDisconnect().catch(() => undefined);
    demoEmit("uu://status", { connected: false, phase: "idle", msg: "" });
    setConn("idle");
    setPeer(null);
    setFps(0);
    frameTimesRef.current = [];
    toast("已断开连接", "info");
  };

  // ---------------- 输入注入 ----------------

  const sendInput = (obj: Record<string, unknown>) => {
    if (mouseModeRef.current === "view") return;
    if (connRef.current === "demo") return; // 演示画面不向后端注入输入
    bridge.remoteInput(JSON.stringify({ t: "input", ...obj })).catch(() => undefined);
  };

  const normPoint = (e: { clientX: number; clientY: number }) => {
    const canvas = canvasRef.current;
    if (!canvas) return { x: 0, y: 0 };
    const r = canvas.getBoundingClientRect();
    return {
      x: Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)),
      y: Math.min(1, Math.max(0, (e.clientY - r.top) / r.height)),
    };
  };

  useEffect(() => {
    const stage = stageRef.current;
    if (!stage || (conn !== "connected" && conn !== "demo")) return;
    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      sendInput({ k: "scroll", dx: 0, dy: e.deltaY });
    };
    stage.addEventListener("wheel", onWheel, { passive: false });
    return () => stage.removeEventListener("wheel", onWheel);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [conn]);

  // ---------------- 被控开关 ----------------

  const toggleControlled = async () => {
    const v = !controlled;
    setControlled(v);
    try {
      if (v) {
        await bridge.controlledStart();
        toast(isTauri ? "已进入被控模式，等待对方连接" : "演示：已进入被控模式", "success");
      } else {
        await bridge.controlledStop();
        toast("已退出被控模式", "info");
      }
    } catch (e) {
      toast(`操作失败：${String(e)}`, "error");
      setControlled(!v);
    }
  };

  // ---------------- 渲染 ----------------

  if (conn === "connected" || conn === "demo") {
    const isDemo = conn === "demo";
    return (
      <div className="flex h-full flex-col gap-3 p-4">
        <div
          ref={stageRef}
          tabIndex={0}
          className="relative flex min-h-0 flex-1 items-center justify-center overflow-hidden rounded-xl bg-[#0b0d10] shadow-[0_16px_48px_rgba(0,0,0,0.35)] outline-none ring-brand/0 transition-shadow focus:ring-2 focus:ring-brand/60"
          onPointerMove={(e) => {
            const now = performance.now();
            if (now - lastMoveRef.current < 30) return;
            lastMoveRef.current = now;
            const { x, y } = normPoint(e);
            sendInput({ k: "move", x, y });
          }}
          onPointerDown={(e) => {
            (e.target as HTMLElement).setPointerCapture?.(e.pointerId);
            const { x, y } = normPoint(e);
            sendInput({ k: "down", btn: e.button, x, y });
          }}
          onPointerUp={(e) => {
            const { x, y } = normPoint(e);
            sendInput({ k: "up", btn: e.button, x, y });
          }}
          onKeyDown={(e) => {
            const vk = vkFromCode(e.code);
            if (vk !== null) {
              if (["Space", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Tab"].includes(e.code))
                e.preventDefault();
              sendInput({ k: "key", key_code: vk, action: "down" });
            }
          }}
          onKeyUp={(e) => {
            const vk = vkFromCode(e.code);
            if (vk !== null) sendInput({ k: "key", key_code: vk, action: "up" });
          }}
        >
          {isDemo ? (
            <DemoDesktop className="max-h-full max-w-full rounded-lg" />
          ) : (
            <canvas ref={canvasRef} className="max-h-full max-w-full rounded-lg" />
          )}

          {/* fps 徽标 */}
          {!isDemo && (
            <div className="absolute left-3 top-3 rounded-md bg-black/55 px-2 py-1 text-[11px] tabular-nums text-white/80 backdrop-blur-sm">
              {fps} fps
            </div>
          )}

          {/* 控制中浮层 */}
          <div className="absolute right-3 top-3 flex items-center gap-1.5 rounded-md bg-success/90 px-2.5 py-1 text-xs font-medium text-white shadow">
            <MousePointer2 size={13} />
            控制中 · {peer?.peer_name ?? "远程设备"}
          </div>

          {isDemo && (
            <div className="absolute bottom-3 left-3 rounded-md bg-black/55 px-2 py-1 text-[11px] text-white/70 backdrop-blur-sm">
              演示画面 · 输入已模拟
            </div>
          )}
        </div>

        {/* 底部控制条 */}
        <div className="flex items-center justify-center gap-2">
          <BarButton
            label="请求关键帧"
            onClick={() => {
              bridge.remoteRequestKeyframe().catch(() => undefined);
              toast("已请求关键帧", "info");
            }}
          >
            <RefreshCw size={16} />
          </BarButton>
          <BarButton
            label={mouseMode === "control" ? "鼠标模式：控制（点击切换为仅查看）" : "鼠标模式：仅查看（点击切换为控制）"}
            tone={mouseMode === "control" ? "active" : "default"}
            onClick={() => setMouseMode((m) => (m === "control" ? "view" : "control"))}
          >
            {mouseMode === "control" ? <MousePointer2 size={16} /> : <Eye size={16} />}
          </BarButton>
          <BarButton
            label="全屏"
            onClick={() => {
              const el = stageRef.current;
              if (el && !document.fullscreenElement) el.requestFullscreen().catch(() => undefined);
              else document.exitFullscreen().catch(() => undefined);
            }}
          >
            <Maximize2 size={16} />
          </BarButton>
          <BarButton label="断开连接" tone="danger" onClick={disconnect}>
            <LogOut size={16} />
          </BarButton>
        </div>
      </div>
    );
  }

  if (conn === "connecting") {
    const idx = Math.max(0, PHASES.findIndex((p) => p.key === phase));
    return (
      <div className="flex h-full items-center justify-center">
        <div className="animate-pop-in w-[440px] rounded-2xl border border-line bg-card p-8 shadow-[0_12px_40px_rgba(31,35,41,0.10)]">
          <h3 className="mb-6 text-center text-base font-semibold text-ink">正在建立连接…</h3>
          <div className="space-y-1">
            {PHASES.map((p, i) => (
              <div key={p.key} className="flex items-center gap-3">
                <div
                  className={`flex h-7 w-7 items-center justify-center rounded-full text-xs font-medium transition-colors ${
                    i < idx
                      ? "bg-success text-white"
                      : i === idx
                        ? "animate-step-pulse bg-brand text-white"
                        : "bg-raised text-ink-3"
                  }`}
                >
                  {i < idx ? "✓" : i + 1}
                </div>
                <span className={`text-sm ${i === idx ? "font-medium text-ink" : "text-ink-3"}`}>
                  {p.label}
                </span>
                {i === idx && (
                  <span className="ml-auto text-xs text-brand">进行中…</span>
                )}
              </div>
            ))}
          </div>
          <button
            onClick={disconnect}
            className="mt-8 h-9 w-full rounded-lg border border-line text-sm text-ink-2 transition-colors hover:border-danger hover:text-danger"
          >
            取消
          </button>
        </div>
      </div>
    );
  }

  // ---------------- 未连接：连接卡片 ----------------

  return (
    <div className="flex h-full items-center justify-center overflow-y-auto p-6">
      <div className="w-full max-w-[560px] rounded-2xl border border-line bg-card p-6 shadow-[0_12px_40px_rgba(31,35,41,0.10)]">
        <div className="mb-5 flex items-center gap-2">
          <MonitorUp size={18} className="text-brand" />
          <h2 className="text-base font-semibold text-ink">远程控制</h2>
        </div>

        {/* Tabs */}
        <div className="mb-5 flex rounded-lg bg-raised p-1">
          {(["code", "direct"] as const).map((t) => (
            <button
              key={t}
              onClick={() => setTab(t)}
              className={`flex-1 rounded-md py-1.5 text-[13px] font-medium transition-all duration-150 ${
                tab === t ? "bg-card text-ink shadow-sm" : "text-ink-3 hover:text-ink-2"
              }`}
            >
              {t === "code" ? "配对码连接" : "局域网直连"}
            </button>
          ))}
        </div>

        {tab === "code" ? (
          <div className="space-y-4">
            <div>
              <label className="text-xs font-medium text-ink-2">6 位配对码</label>
              <div className="mt-2">
                <CodeInput value={code} onChange={setCode} onComplete={() => startConnect("code")} />
              </div>
            </div>
            <div>
              <label className="text-xs font-medium text-ink-2">服务器地址</label>
              <input
                value={getSettings().serverUrl}
                readOnly
                className="mt-1.5 h-10 w-full rounded-lg border border-line bg-raised px-3 text-sm text-ink-2 outline-none"
              />
              <p className="mt-1 text-xs text-ink-3">可在「设置」页修改服务器地址</p>
            </div>
            <button
              onClick={() => startConnect("code")}
              disabled={code.length !== 6}
              className="flex h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand text-sm font-medium text-white transition-all duration-150 hover:bg-brand-hover active:bg-brand-active disabled:cursor-not-allowed disabled:opacity-45"
            >
              <Wifi size={16} />
              连接
            </button>
          </div>
        ) : (
          <div className="space-y-4">
            <div>
              <label className="text-xs font-medium text-ink-2">设备地址（IP:端口）</label>
              <input
                value={addr}
                onChange={(e) => setAddr(e.target.value)}
                placeholder="192.168.1.20:9527"
                className="mt-1.5 h-10 w-full rounded-lg border border-line bg-raised px-3 text-sm text-ink outline-none transition-colors focus:border-brand focus:bg-card"
              />
            </div>
            <div>
              <label className="text-xs font-medium text-ink-2">连接 PIN</label>
              <div className="relative mt-1.5">
                <KeyRound size={15} className="absolute left-3 top-1/2 -translate-y-1/2 text-ink-3" />
                <input
                  value={pin}
                  onChange={(e) => setPin(e.target.value)}
                  placeholder="64 位十六进制"
                  className="h-10 w-full rounded-lg border border-line bg-raised pl-9 pr-3 text-sm text-ink outline-none transition-colors focus:border-brand focus:bg-card"
                />
              </div>
            </div>
            <button
              onClick={() => startConnect("direct")}
              disabled={!addr || !pin}
              className="flex h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand text-sm font-medium text-white transition-all duration-150 hover:bg-brand-hover active:bg-brand-active disabled:cursor-not-allowed disabled:opacity-45"
            >
              <Wifi size={16} />
              直连
            </button>
          </div>
        )}

        <div className="my-5 h-px bg-line" />

        {/* 本机被控 */}
        <div className="flex items-center justify-between rounded-xl bg-raised px-4 py-3">
          <div>
            <p className="text-sm font-medium text-ink">本机被控</p>
            <p className="mt-0.5 text-xs text-ink-3">
              本机：{device?.name ?? "本机"} · 开启后其他设备可通过配对码控制本机
            </p>
          </div>
          <button
            onClick={toggleControlled}
            className={`relative h-6 w-11 rounded-full transition-colors duration-200 ${
              controlled ? "bg-success" : "bg-[#bbbfc6] dark:bg-[#4a4e55]"
            }`}
          >
            <span
              className={`absolute top-0.5 h-5 w-5 rounded-full bg-white shadow transition-transform duration-200 ${
                controlled ? "translate-x-[22px]" : "translate-x-0.5"
              }`}
            />
          </button>
        </div>

        <button
          onClick={enterDemo}
          className="mt-4 flex h-10 w-full items-center justify-center gap-2 rounded-lg border border-dashed border-line text-sm text-ink-2 transition-colors hover:border-brand hover:text-brand"
        >
          <Play size={15} />
          进入演示画面
        </button>
      </div>
    </div>
  );
}

function BarButton({
  label,
  onClick,
  tone = "default",
  children,
}: {
  label: string;
  onClick: () => void;
  tone?: "default" | "danger" | "active";
  children: ReactNode;
}) {
  const cls =
    tone === "danger"
      ? "border-danger/40 text-danger hover:bg-danger hover:text-white"
      : tone === "active"
        ? "border-brand/50 bg-brand/10 text-brand"
        : "border-line text-ink-2 hover:border-brand hover:text-brand";
  return (
    <Tooltip label={label} side="top">
      <button
        onClick={onClick}
        className={`flex h-9 items-center gap-1.5 rounded-lg border bg-card px-3.5 text-xs font-medium transition-all duration-150 active:scale-95 ${cls}`}
      >
        {children}
        <span>{label}</span>
      </button>
    </Tooltip>
  );
}
