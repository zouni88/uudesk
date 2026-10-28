import {
  useEffect,
  useRef,
  useState,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
} from "react";
import {
  Camera,
  CameraOff,
  Circle,
  Copy,
  Hand,
  LayoutGrid,
  Loader2,
  Maximize,
  MessageSquare,
  Mic,
  MicOff,
  Minimize,
  PhoneOff,
  ScreenShare,
  ScreenShareOff,
  Send,
  Smile,
  Square,
  UserRound,
  Users,
  X,
} from "lucide-react";
import { Avatar } from "../Avatar";
import { Tooltip } from "../Tooltip";
import { toast } from "../Toast";
import { isTauri } from "../../lib/bridge";
import { openUrl } from "@tauri-apps/plugin-opener";
import { useElementSize } from "../../lib/useElementSize";

// ---------------- 类型 ----------------

export interface StageParticipant {
  id: string;
  name: string;
  isLocal: boolean;
  muted: boolean;
  hasVideo: boolean;
  speaking: boolean;
  raised: boolean;
  quality: "excellent" | "good" | "poor" | "lost" | "unknown";
}

export interface ChatMessage {
  id: number;
  from: string;
  text: string;
  time: number;
  self: boolean;
}

export interface FloatingReaction {
  id: number;
  emoji: string;
  name: string;
}

export type SlotKind = "camera" | "screen";

export interface MeetingStageProps {
  roomCode: string;
  elapsed: number;
  participants: StageParticipant[];
  localId: string;
  sharing: { id: string; name: string } | null;
  viewMode: "grid" | "spotlight";
  setViewMode: (m: "grid" | "spotlight") => void;
  attachSlot: (kind: SlotKind, id: string, el: HTMLDivElement | null) => void;
  micOn: boolean;
  camOn: boolean;
  sharingLocal: boolean;
  raised: boolean;
  onToggleMic: () => void;
  onToggleCam: () => void;
  onToggleShare: () => void;
  onToggleRaise: () => void;
  onReaction: (emoji: string) => void;
  onLeave: () => void;
  messages: ChatMessage[];
  onSendChat: (text: string) => void;
  reactions: FloatingReaction[];
  drawer: "none" | "people" | "chat";
  setDrawer: (d: "none" | "people" | "chat") => void;
  /** 抽屉关闭时收到的未读聊天数 */
  unreadChat: number;
  /** 房间是否正在录制 */
  recording: boolean;
  recBusy: boolean;
  onToggleRecord: () => void;
  // ---- 会中屏幕共享控制 ----
  /** 当前共享者 identity（null = 无共享/演示模式，控制功能禁用） */
  sharerIdentity: string | null;
  /** 本端是否共享者 */
  isLocalSharer: boolean;
  /** 共享者侧：待处理的控制请求 */
  controlRequests: { identity: string; name: string }[];
  /** 共享者侧：已授权观看方数量 */
  grantedCount: number;
  /** 观看方侧：授权来源共享者 identity */
  myGrantFrom: string | null;
  onRequestControl: (sharerIdentity: string) => void;
  onReleaseControl: () => void;
  onGrantControl: (viewerIdentity: string) => void;
  onRejectControl: (viewerIdentity: string) => void;
  onRevokeControl: () => void;
  onControlInput: (ev: Record<string, unknown>) => void;
}

const REACTION_EMOJIS = ["👍", "❤️", "😂", "🎉"];

function fmtElapsed(sec: number): string {
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = sec % 60;
  const mm = String(m).padStart(2, "0");
  const ss = String(s).padStart(2, "0");
  return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
}

function gridCols(n: number, w: number, h: number): number {
  if (n <= 1 || w <= 0 || h <= 0) return 1;
  let best = 1;
  let bestScore = -Infinity;
  for (let c = 1; c <= 6; c++) {
    const r = Math.ceil(n / c);
    const cw = w / c;
    const ch = h / r;
    const penalty = Math.abs(Math.log(cw / ch / 1.6));
    const score = (cw * ch) / (1 + penalty * 1.5);
    if (score > bestScore) {
      bestScore = score;
      best = c;
    }
  }
  return best;
}

// ---------------- 视频挂载槽 ----------------

function VideoSlot({
  kind,
  id,
  attach,
  className = "",
}: {
  kind: SlotKind;
  id: string;
  attach: MeetingStageProps["attachSlot"];
  className?: string;
}) {
  const ref = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    attach(kind, id, ref.current);
    return () => attach(kind, id, null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [kind, id]);
  return <div ref={ref} className={`cell-video absolute inset-0 ${className}`} />;
}

// ---------------- 观看方输入覆盖层（会中控制） ----------------

/** DOM button -> 协议 btn（1=左 2=右 3=中） */
function protoBtn(b: number): number {
  return b === 2 ? 2 : b === 1 ? 3 : 1;
}

function ControlInputLayer({ onInput }: { onInput: (ev: Record<string, unknown>) => void }) {
  const ref = useRef<HTMLDivElement | null>(null);
  const norm = (clientX: number, clientY: number) => {
    const el = ref.current;
    if (!el) return null;
    const r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return null;
    // 共享画面是 object-fit: contain，有黑边时要按实际视频内容矩形换算，否则点击会偏移
    const v = el.querySelector("video");
    const vw = v?.videoWidth ?? 0;
    const vh = v?.videoHeight ?? 0;
    let w = r.width;
    let h = r.height;
    let ox = 0;
    let oy = 0;
    if (vw > 0 && vh > 0) {
      const scale = Math.min(r.width / vw, r.height / vh);
      w = vw * scale;
      h = vh * scale;
      ox = (r.width - w) / 2;
      oy = (r.height - h) / 2;
    }
    return {
      x: Math.min(1, Math.max(0, (clientX - r.left - ox) / w)),
      y: Math.min(1, Math.max(0, (clientY - r.top - oy) / h)),
    };
  };
  const release = (e: ReactPointerEvent<HTMLDivElement>) => {
    const p = norm(e.clientX, e.clientY);
    if (!p) return;
    onInput({ t: "input", k: "up", x: p.x, y: p.y, btn: e.button >= 0 ? protoBtn(e.button) : 1 });
  };
  return (
    <div
      ref={ref}
      className="absolute inset-0 z-10 cursor-crosshair touch-none"
      onContextMenu={(e) => e.preventDefault()}
      onPointerDown={(e) => {
        e.currentTarget.setPointerCapture(e.pointerId);
        const p = norm(e.clientX, e.clientY);
        if (!p) return;
        // down 时补发一条 move（与手机端行为一致，先定位再按下）
        onInput({ t: "input", k: "down", x: p.x, y: p.y, btn: protoBtn(e.button) });
        onInput({ t: "input", k: "move", x: p.x, y: p.y });
      }}
      onPointerMove={(e) => {
        const p = norm(e.clientX, e.clientY);
        if (!p) return;
        onInput({ t: "input", k: "move", x: p.x, y: p.y });
      }}
      onPointerUp={release}
      // 指针取消/丢失捕获时也要补 up，否则远端会一直处于按下状态
      onPointerCancel={release}
      onLostPointerCapture={release}
      onWheel={(e) => {
        const p = norm(e.clientX, e.clientY);
        if (!p) return;
        onInput({
          t: "input",
          k: "scroll",
          x: p.x,
          y: p.y,
          dx: -e.deltaX / 100,
          dy: -e.deltaY / 100,
        });
      }}
    />
  );
}

// ---------------- 成员卡片 ----------------

function ParticipantCell({
  p,
  attach,
  small = false,
  pinned = false,
  onPin,
}: {
  p: StageParticipant;
  attach: MeetingStageProps["attachSlot"];
  small?: boolean;
  pinned?: boolean;
  onPin?: (id: string) => void;
}) {
  return (
    <div
      onClick={onPin ? () => onPin(p.id) : undefined}
      title={onPin ? (pinned ? "取消固定" : "固定该成员") : undefined}
      className={`relative overflow-hidden rounded-lg border bg-stage-cell transition-shadow duration-150 ${
        pinned
          ? "border-brand ring-2 ring-brand/50"
          : p.speaking
            ? "border-success speaking-ring"
            : "border-white/10"
      } ${onPin ? "cursor-pointer" : ""} ${small ? "h-[76px] w-[120px] shrink-0" : "h-full w-full"}`}
    >
      {p.hasVideo ? (
        <VideoSlot kind="camera" id={p.id} attach={attach} />
      ) : (
        <div className="absolute inset-0 flex items-center justify-center">
          <Avatar name={p.name} size={small ? 34 : 64} disabled={p.muted && p.isLocal} />
        </div>
      )}

      {/* 麦克风状态 */}
      <div className="absolute left-2 top-2 flex h-6 items-center gap-1 rounded-md bg-black/45 px-1.5 backdrop-blur-sm">
        {p.muted ? (
          <MicOff size={13} className="text-danger" />
        ) : (
          <Mic size={13} className={p.speaking ? "text-success" : "text-white/80"} />
        )}
        {p.raised && <Hand size={13} className="text-warning" />}
        {(p.quality === "poor" || p.quality === "lost") && (
          <span
            title={p.quality === "lost" ? "网络已断开" : "网络较差"}
            className="h-1.5 w-1.5 rounded-full bg-danger"
          />
        )}
      </div>

      {/* 姓名条 */}
      <div className="absolute bottom-0 left-0 right-0 flex items-center gap-1 bg-gradient-to-t from-black/60 to-transparent px-2 pb-1.5 pt-4">
        <span className={`truncate text-white/90 ${small ? "text-[11px]" : "text-xs"}`}>
          {p.name}
          {p.isLocal && <span className="ml-1 text-white/50">（我）</span>}
        </span>
      </div>
    </div>
  );
}

// ---------------- 右侧抽屉 ----------------

function Drawer({
  tab,
  onClose,
  participants,
  messages,
  onSend,
}: {
  tab: "people" | "chat";
  onClose: () => void;
  participants: StageParticipant[];
  messages: ChatMessage[];
  onSend: (t: string) => void;
}) {
  const [text, setText] = useState("");
  const listRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (tab === "chat" && listRef.current) listRef.current.scrollTop = listRef.current.scrollHeight;
  }, [messages, tab]);

  const send = () => {
    const t = text.trim();
    if (!t) return;
    onSend(t);
    setText("");
  };

  return (
    <aside className="animate-slide-in-right absolute inset-y-0 right-0 z-30 flex w-[320px] flex-col border-l border-white/10 bg-[#1d2026]">
      <div className="flex h-11 shrink-0 items-center justify-between border-b border-white/10 px-3">
        <span className="text-sm font-medium text-white">
          {tab === "people" ? `参会人（${participants.length}）` : "聊天"}
        </span>
        <button
          onClick={onClose}
          className="flex h-7 w-7 items-center justify-center rounded-md text-white/60 transition-colors hover:bg-white/10 hover:text-white"
        >
          <X size={15} />
        </button>
      </div>

      {tab === "people" ? (
        <div className="flex-1 overflow-y-auto p-2">
          {participants.map((p) => (
            <div
              key={p.id}
              className="flex items-center gap-2.5 rounded-lg px-2 py-2 transition-colors hover:bg-white/5"
            >
              <Avatar name={p.name} size={32} disabled={p.muted && p.isLocal} />
              <span className="flex-1 truncate text-[13px] text-white/85">
                {p.name}
                {p.isLocal && <span className="ml-1 text-white/45">（我）</span>}
              </span>
              {p.raised && <Hand size={15} className="mr-1 text-warning" />}
              {p.muted ? (
                <MicOff size={15} className="text-danger" />
              ) : (
                <Mic size={15} className="text-white/50" />
              )}
            </div>
          ))}
        </div>
      ) : (
        <div className="flex flex-1 flex-col overflow-hidden">
          <div ref={listRef} className="flex-1 space-y-3 overflow-y-auto p-3">
            {messages.length === 0 && (
              <div className="pt-10 text-center text-xs text-white/35">还没有人聊天</div>
            )}
            {messages.map((m) => (
              <div key={m.id} className="animate-fade-in">
                <div className="mb-0.5 flex items-baseline gap-2 text-[11px] text-white/45">
                  <span>{m.self ? "我" : m.from}</span>
                  <span>
                    {new Date(m.time).toLocaleTimeString("zh-CN", {
                      hour: "2-digit",
                      minute: "2-digit",
                    })}
                  </span>
                </div>
                <div
                  className={`inline-block max-w-[90%] rounded-lg px-2.5 py-1.5 text-[13px] leading-relaxed ${
                    m.self ? "bg-brand/85 text-white" : "bg-white/10 text-white/85"
                  }`}
                >
                  {m.text.includes("http") ? <Linkified text={m.text} /> : m.text}
                </div>
              </div>
            ))}
          </div>
          <div className="shrink-0 p-2.5">
            <div className="flex items-center gap-2 rounded-lg bg-white/8 px-2.5 py-1.5">
              <input
                value={text}
                onChange={(e) => setText(e.target.value)}
                onKeyDown={(e) => {
                  // 中文输入法选词回车不算发送
                  if (e.key === "Enter" && !e.nativeEvent.isComposing) send();
                  e.stopPropagation();
                }}
                placeholder="发送消息…"
                className="h-7 flex-1 bg-transparent text-[13px] text-white outline-none placeholder:text-white/35"
              />
              <button
                onClick={send}
                className="flex h-7 w-7 items-center justify-center rounded-md text-brand transition-colors hover:bg-white/10"
              >
                <Send size={15} />
              </button>
            </div>
          </div>
        </div>
      )}
    </aside>
  );
}

// ---------------- 控制条按钮 ----------------

// ---------------- 工具 ----------------

const URL_SPLIT = /(https?:\/\/[^\s]+)/g;
const isUrl = (s: string) => /^https?:\/\//.test(s);

/** 把聊天里的 http(s) 链接渲染为可点击链接（Tauri 中用系统浏览器打开） */
function Linkified({ text }: { text: string }) {
  return (
    <>
      {text.split(URL_SPLIT).map((part, i) =>
        isUrl(part) ? (
          <a
            key={i}
            href={part}
            onClick={(e) => {
              e.preventDefault();
              e.stopPropagation();
              if (isTauri) void openUrl(part);
              else window.open(part, "_blank", "noopener,noreferrer");
            }}
            className="underline decoration-white/40 underline-offset-2 hover:decoration-white"
          >
            {part}
          </a>
        ) : (
          <span key={i}>{part}</span>
        ),
      )}
    </>
  );
}

function CtrlButton({
  label,
  onClick,
  tone = "default",
  badge,
  children,
}: {
  label: string;
  onClick: () => void;
  tone?: "default" | "danger" | "dangerActive" | "active";
  badge?: number;
  children: ReactNode;
}) {
  const toneCls =
    tone === "danger"
      ? "bg-danger text-white hover:bg-danger-active"
      : tone === "dangerActive"
        ? "bg-danger text-white ring-2 ring-danger/40 hover:bg-danger-active"
        : tone === "active"
          ? "bg-brand text-white hover:bg-brand-hover"
          : "bg-white/10 text-white hover:bg-white/20";
  return (
    <Tooltip label={label} side="top" dark>
      <button
        onClick={onClick}
        className={`relative flex h-11 w-11 items-center justify-center rounded-full transition-all duration-150 hover:scale-110 active:scale-95 ${toneCls}`}
      >
        {children}
        {!!badge && (
          <span className="absolute -right-0.5 -top-0.5 flex h-4 min-w-4 items-center justify-center rounded-full bg-danger px-1 text-[10px] font-medium text-white">
            {badge > 99 ? "99+" : badge}
          </span>
        )}
      </button>
    </Tooltip>
  );
}

// ---------------- 舞台主体 ----------------

export function MeetingStage(props: MeetingStageProps) {
  const {
    roomCode,
    elapsed,
    participants,
    localId,
    sharing,
    viewMode,
    setViewMode,
    attachSlot,
    micOn,
    camOn,
    sharingLocal,
    raised,
    onToggleMic,
    onToggleCam,
    onToggleShare,
    onToggleRaise,
    onReaction,
    onLeave,
    messages,
    onSendChat,
    reactions,
    drawer,
    setDrawer,
    unreadChat,
    recording,
    recBusy,
    onToggleRecord,
    sharerIdentity,
    isLocalSharer,
    controlRequests,
    grantedCount,
    myGrantFrom,
    onRequestControl,
    onReleaseControl,
    onGrantControl,
    onRejectControl,
    onRevokeControl,
    onControlInput,
  } = props;

  const [gridRef, gridSize] = useElementSize<HTMLDivElement>();
  const [emojiOpen, setEmojiOpen] = useState(false);
  const emojiWrapRef = useRef<HTMLDivElement | null>(null);
  const [pinnedId, setPinnedId] = useState<string | null>(null);
  const [fullscreen, setFullscreen] = useState(false);

  useEffect(() => {
    const onChange = () => setFullscreen(!!document.fullscreenElement);
    document.addEventListener("fullscreenchange", onChange);
    return () => document.removeEventListener("fullscreenchange", onChange);
  }, []);

  // 点击空白处 / Esc 关闭表情面板
  useEffect(() => {
    if (!emojiOpen) return;
    const onDown = (e: PointerEvent) => {
      if (!emojiWrapRef.current?.contains(e.target as Node)) setEmojiOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setEmojiOpen(false);
    };
    document.addEventListener("pointerdown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("pointerdown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [emojiOpen]);

  // 会中控制：观看方已获当前共享者授权 -> 可注入；未授权 -> 可请求
  const canControl = !isLocalSharer && sharing !== null && myGrantFrom !== null && myGrantFrom === sharerIdentity;
  const canRequest = !isLocalSharer && sharing !== null && sharerIdentity !== null && myGrantFrom === null;
  const waitingGrant = !isLocalSharer && sharing !== null && myGrantFrom !== null && myGrantFrom !== sharerIdentity;

  // 固定成员优先，其次是共享画面、正在说话的人
  const pinned = pinnedId && participants.some((p) => p.id === pinnedId) ? pinnedId : null;
  const spotlightId = sharing?.id ?? pinned ?? participants.find((p) => p.speaking)?.id ?? localId;
  const spotlight = participants.find((p) => p.id === spotlightId) ?? null;
  const sharingId = sharing?.id ?? null;
  // 共享开始时自动切到主讲人视图，但不在每次成员刷新时强制，用户可以手动切回宫格
  useEffect(() => {
    if (sharingId) setViewMode("spotlight");
  }, [sharingId, setViewMode]);
  const useSpotlight = viewMode === "spotlight";
  const togglePin = (id: string) => {
    setPinnedId((cur) => (cur === id ? null : id));
    setViewMode("spotlight");
  };
  const toggleFullscreen = () => {
    if (document.fullscreenElement) void document.exitFullscreen();
    else void document.documentElement.requestFullscreen().catch(() => undefined);
  };

  const cols = gridCols(participants.length, gridSize.w, gridSize.h);
  const rows = Math.ceil(participants.length / cols);

  return (
    <div className="fixed inset-0 z-50 flex flex-col bg-stage">
      {/* 左上会议信息 */}
      <div className="absolute left-4 top-4 z-30 flex items-center gap-3 rounded-xl border border-white/10 bg-black/35 px-3.5 py-2 backdrop-blur-md">
        <span className="text-sm font-semibold text-white">UUDesk 会议</span>
        <span className="h-3.5 w-px bg-white/20" />
        <span className="text-xs text-white/70">会议号 {roomCode}</span>
        <Tooltip label="复制会议号" side="bottom" dark>
          <button
            onClick={() => {
              navigator.clipboard
                ?.writeText(roomCode)
                .then(() => toast("会议号已复制"))
                .catch(() => toast("复制失败", "error"));
            }}
            className="flex h-6 w-6 items-center justify-center rounded-md text-white/50 transition-colors hover:bg-white/10 hover:text-white"
          >
            <Copy size={13} />
          </button>
        </Tooltip>
        {recording && (
          <span className="flex items-center gap-1 rounded-full bg-danger/20 px-2 py-0.5 text-[11px] font-medium text-danger">
            <span className="h-1.5 w-1.5 animate-pulse rounded-full bg-danger" />
            REC
          </span>
        )}
        <span className="text-xs tabular-nums text-white/70">{fmtElapsed(elapsed)}</span>
        <span className="flex items-center gap-1 text-xs text-white/70">
          <Users size={13} />
          {participants.length}
        </span>
      </div>

      {/* 视图切换（共享时提供切回宫格） */}
      <div className="absolute right-4 top-4 z-30 flex items-center gap-1 rounded-xl border border-white/10 bg-black/35 p-1 backdrop-blur-md">
        <Tooltip label="宫格视图" side="bottom" dark>
          <button
            onClick={() => setViewMode("grid")}
            className={`flex h-8 w-8 items-center justify-center rounded-lg transition-colors ${
              !useSpotlight ? "bg-white/15 text-white" : "text-white/55 hover:text-white"
            }`}
          >
            <LayoutGrid size={16} />
          </button>
        </Tooltip>
        <Tooltip label="主讲人视图" side="bottom" dark>
          <button
            onClick={() => setViewMode("spotlight")}
            className={`flex h-8 w-8 items-center justify-center rounded-lg transition-colors ${
              useSpotlight ? "bg-white/15 text-white" : "text-white/55 hover:text-white"
            }`}
          >
            <UserRound size={16} />
          </button>
        </Tooltip>
        <Tooltip label={fullscreen ? "退出全屏" : "全屏"} side="bottom" dark>
          <button
            onClick={toggleFullscreen}
            className="flex h-8 w-8 items-center justify-center rounded-lg text-white/55 transition-colors hover:text-white"
          >
            {fullscreen ? <Minimize size={16} /> : <Maximize size={16} />}
          </button>
        </Tooltip>
      </div>

      {participants.length <= 1 && (
        <div className="absolute left-1/2 top-16 z-20 -translate-x-1/2 rounded-full border border-white/10 bg-black/35 px-3 py-1 text-xs text-white/60 backdrop-blur-md">
          等待其他人加入 · 把会议号 {roomCode} 发给对方
        </div>
      )}

      {/* 共享者侧：会中控制请求/授权横幅 */}
      {isLocalSharer && (controlRequests.length > 0 || grantedCount > 0) && (
        <div className="absolute left-1/2 top-4 z-40 flex -translate-x-1/2 flex-col items-center gap-2">
          {controlRequests.map((r) => (
            <div
              key={r.identity}
              className="animate-pop-in flex items-center gap-2 rounded-xl border border-white/10 bg-[#1d2026]/95 px-3 py-2 shadow-lg backdrop-blur-md"
            >
              <span className="text-xs text-white/90">{r.name} 请求控制你的屏幕</span>
              <button
                onClick={() => onGrantControl(r.identity)}
                className="rounded-md bg-brand px-2.5 py-1 text-xs font-medium text-white transition-colors hover:bg-brand-hover"
              >
                同意
              </button>
              <button
                onClick={() => onRejectControl(r.identity)}
                className="rounded-md bg-white/10 px-2.5 py-1 text-xs text-white/80 transition-colors hover:bg-white/20"
              >
                拒绝
              </button>
            </div>
          ))}
          {grantedCount > 0 && (
            <div className="animate-pop-in flex items-center gap-2 rounded-xl border border-white/10 bg-[#1d2026]/95 px-3 py-2 shadow-lg backdrop-blur-md">
              <span className="text-xs text-white/90">{grantedCount} 人控制中</span>
              <button
                onClick={onRevokeControl}
                className="rounded-md bg-danger px-2.5 py-1 text-xs font-medium text-white transition-colors hover:bg-danger-active"
              >
                收回
              </button>
            </div>
          )}
        </div>
      )}

      {/* 主画面区 */}
      <div className="relative flex-1 overflow-hidden p-4 pb-24 pt-16">
        {useSpotlight ? (
          <div className="flex h-full flex-col gap-3">
            <div className="relative min-h-0 flex-1 overflow-hidden rounded-xl border border-white/10 bg-stage-cell">
              {sharing ? (
                <>
                  <div className="spotlight-video absolute inset-0">
                    <VideoSlot kind="screen" id={sharing.id} attach={attachSlot} />
                  </div>
                  <div className="absolute left-3 top-3 z-20 flex items-center gap-1.5 rounded-md bg-black/50 px-2 py-1 text-xs text-white/85 backdrop-blur-sm">
                    <ScreenShare size={13} />
                    {sharing.name} 正在共享屏幕
                  </div>
                  {canControl && (
                    <>
                      <ControlInputLayer onInput={onControlInput} />
                      <button
                        onClick={onReleaseControl}
                        className="absolute right-3 top-3 z-20 flex items-center gap-1 rounded-md bg-black/50 px-2.5 py-1 text-xs text-white/85 backdrop-blur-sm transition-colors hover:bg-danger"
                      >
                        控制中 · 退出
                      </button>
                    </>
                  )}
                  {canRequest && (
                    <button
                      onClick={() => sharerIdentity && onRequestControl(sharerIdentity)}
                      className="absolute right-3 top-3 z-20 rounded-md bg-black/50 px-2.5 py-1 text-xs text-white/85 backdrop-blur-sm transition-colors hover:bg-brand"
                    >
                      请求控制
                    </button>
                  )}
                  {waitingGrant && (
                    <button
                      disabled
                      className="absolute right-3 top-3 z-20 cursor-default rounded-md bg-black/50 px-2.5 py-1 text-xs text-white/50 backdrop-blur-sm"
                    >
                      等待授权…
                    </button>
                  )}
                </>
              ) : (
                spotlight && (
                  <>
                    {spotlight.hasVideo ? (
                      <VideoSlot kind="camera" id={spotlight.id} attach={attachSlot} />
                    ) : (
                      <div className="absolute inset-0 flex items-center justify-center">
                        <Avatar name={spotlight.name} size={110} />
                      </div>
                    )}
                    <div className="absolute bottom-3 left-3 rounded-md bg-black/50 px-2.5 py-1 text-xs text-white/85 backdrop-blur-sm">
                      {spotlight.name}
                      {spotlight.isLocal && "（我）"}
                    </div>
                  </>
                )
              )}
            </div>
            {/* filmstrip */}
            <div className="flex h-[80px] shrink-0 gap-2 overflow-x-auto pb-1">
              {participants
                .filter((p) => p.id !== spotlightId)
                .map((p) => (
                  <ParticipantCell
                    key={p.id}
                    p={p}
                    attach={attachSlot}
                    small
                    pinned={p.id === pinned}
                    onPin={togglePin}
                  />
                ))}
            </div>
          </div>
        ) : (
          <div
            ref={gridRef}
            className="grid h-full w-full gap-3"
            style={{
              gridTemplateColumns: `repeat(${cols}, minmax(0, 1fr))`,
              gridTemplateRows: `repeat(${rows}, minmax(0, 1fr))`,
            }}
          >
            {participants.map((p) => (
              <ParticipantCell
                key={p.id}
                p={p}
                attach={attachSlot}
                pinned={p.id === pinned}
                onPin={togglePin}
              />
            ))}
          </div>
        )}
      </div>

      {/* 表情飘屏：z 高于抽屉与控制条，抽屉展开时左移避开 */}
      <div
        className={`pointer-events-none absolute bottom-24 z-40 flex flex-col-reverse items-end gap-1 ${
          drawer !== "none" ? "right-[344px]" : "right-6"
        }`}
      >
        {reactions.map((r) => (
          <div key={r.id} className="animate-float-up flex flex-col items-end">
            <span className="text-5xl drop-shadow-lg">{r.emoji}</span>
            <span className="mt-0.5 rounded bg-black/40 px-1.5 py-0.5 text-[11px] text-white/75">
              {r.name}
            </span>
          </div>
        ))}
      </div>

      {/* 底部控制条 */}
      <div ref={emojiWrapRef} className="absolute bottom-5 left-1/2 z-30 -translate-x-1/2">
        {emojiOpen && (
          <div className="animate-pop-in absolute bottom-full left-1/2 mb-2 flex -translate-x-1/2 gap-1 rounded-2xl border border-white/10 bg-[#1d2026] px-2 py-1.5 shadow-lg">
            {REACTION_EMOJIS.map((e) => (
              <button
                key={e}
                onClick={() => {
                  onReaction(e);
                  setEmojiOpen(false);
                }}
                className="flex h-9 w-9 items-center justify-center rounded-full text-xl transition-transform hover:scale-125 hover:bg-white/10"
              >
                {e}
              </button>
            ))}
          </div>
        )}
        <div className="flex items-center gap-2 rounded-2xl border border-white/10 bg-[#1d2026]/90 px-3 py-2 shadow-[0_12px_32px_rgba(0,0,0,0.45)] backdrop-blur-md">
          <CtrlButton
            label={micOn ? "静音 (Ctrl+M)" : "取消静音 (Ctrl+M)"}
            tone={micOn ? "default" : "dangerActive"}
            onClick={onToggleMic}
          >
            {micOn ? <Mic size={19} /> : <MicOff size={19} />}
          </CtrlButton>
          <CtrlButton
            label={camOn ? "关闭摄像头 (Ctrl+E)" : "开启摄像头 (Ctrl+E)"}
            tone={camOn ? "default" : "dangerActive"}
            onClick={onToggleCam}
          >
            {camOn ? <Camera size={19} /> : <CameraOff size={19} />}
          </CtrlButton>
          <CtrlButton
            label={sharingLocal ? "停止共享" : "共享屏幕"}
            tone={sharingLocal ? "dangerActive" : "default"}
            onClick={onToggleShare}
          >
            {sharingLocal ? <ScreenShareOff size={19} /> : <ScreenShare size={19} />}
          </CtrlButton>
          <CtrlButton
            label={recording ? "停止录制" : "开始录制"}
            tone={recording ? "danger" : "default"}
            onClick={onToggleRecord}
          >
            {recBusy ? (
              <Loader2 size={19} className="animate-spin" />
            ) : recording ? (
              <Square size={17} className="fill-current" />
            ) : (
              <Circle size={18} className="fill-current" />
            )}
          </CtrlButton>
          <CtrlButton
            label={raised ? "放下手" : "举手"}
            tone={raised ? "active" : "default"}
            onClick={onToggleRaise}
          >
            <Hand size={19} />
          </CtrlButton>
          <CtrlButton label="表情" onClick={() => setEmojiOpen((v) => !v)}>
            <Smile size={19} />
          </CtrlButton>
          <CtrlButton
            label="参会人"
            tone={drawer === "people" ? "active" : "default"}
            onClick={() => setDrawer(drawer === "people" ? "none" : "people")}
          >
            <Users size={19} />
          </CtrlButton>
          <CtrlButton
            label="聊天"
            tone={drawer === "chat" ? "active" : "default"}
            badge={unreadChat}
            onClick={() => setDrawer(drawer === "chat" ? "none" : "chat")}
          >
            <MessageSquare size={19} />
          </CtrlButton>
          <div className="mx-1 h-7 w-px bg-white/15" />
          <Tooltip label="离开会议" side="top" dark>
            <button
              onClick={onLeave}
              className="flex h-11 items-center gap-2 rounded-full bg-danger px-4 text-sm font-medium text-white transition-all duration-150 hover:scale-105 hover:bg-danger-active active:scale-95"
            >
              <PhoneOff size={18} />
              离开
            </button>
          </Tooltip>
        </div>
      </div>

      {/* 抽屉 */}
      {drawer !== "none" && (
        <Drawer
          tab={drawer}
          onClose={() => setDrawer("none")}
          participants={participants}
          messages={messages}
          onSend={onSendChat}
        />
      )}
    </div>
  );
}
