import { invoke as tauriInvoke } from "@tauri-apps/api/core";
import { listen as tauriListen, type UnlistenFn } from "@tauri-apps/api/event";

/** 是否运行在 Tauri WebView 中（否则为纯浏览器演示环境） */
export const isTauri: boolean =
  typeof (window as unknown as { __TAURI_INTERNALS__?: unknown }).__TAURI_INTERNALS__ !==
  "undefined";

// ---------------- IPC 契约类型 ----------------

export interface DeviceInfo {
  device_id: string;
  name: string;
}

export interface ConnectResult {
  peer_name: string;
  peer_device_id: string;
}

export interface MeetingTokenResult {
  token: string;
  server_url: string;
}

/** 录制启动结果：SDK 直连成功返回 egress_id，否则返回需人工执行的 command */
export interface EgressStartResult {
  ok: boolean;
  room: string;
  egress_id?: string;
  command?: string;
  note?: string;
}

/** uu://frame */
export interface FramePayload {
  seq: number;
  key: boolean;
  w: number;
  h: number;
  ts_us: number;
  jpeg_b64: string;
}

/** uu://status */
export interface StatusPayload {
  connected: boolean;
  phase: string;
  msg: string;
}

// ---------------- 浏览器演示事件总线 ----------------

type BusHandler = (payload: unknown) => void;
const bus = new Map<string, Set<BusHandler>>();

/** 演示模式下由前端主动广播事件（模拟后端 uu://* 事件） */
export function demoEmit(event: string, payload: unknown): void {
  bus.get(event)?.forEach((fn) => fn(payload));
}

function demoListen(event: string, cb: BusHandler): UnlistenFn {
  let set = bus.get(event);
  if (!set) {
    set = new Set();
    bus.set(event, set);
  }
  set.add(cb);
  return () => {
    set?.delete(cb);
  };
}

// ---------------- 命令封装 ----------------

async function cmd<T>(name: string, args?: Record<string, unknown>): Promise<T> {
  if (!isTauri) throw new Error("not-tauri");
  return tauriInvoke<T>(name, args);
}

export const bridge = {
  isTauri,

  deviceInfo(): Promise<DeviceInfo> {
    if (!isTauri) {
      return Promise.resolve({ device_id: "DEV-DEMO-0001", name: "本机" });
    }
    return cmd<DeviceInfo>("device_info");
  },

  remoteConnect(serverUrl: string, code: string): Promise<ConnectResult> {
    return cmd<ConnectResult>("remote_connect", { serverUrl, code });
  },

  remoteConnectDirect(addr: string, pinB32: string): Promise<ConnectResult> {
    return cmd<ConnectResult>("remote_connect_direct", { addr, pinB32 });
  },

  remoteDisconnect(): Promise<void> {
    if (!isTauri) return Promise.resolve();
    return cmd<void>("remote_disconnect");
  },

  /** json 为 {"t":"input","k":"move"|"down"|"up"|"scroll"|"key"|"touch"|"text", ...} */
  remoteInput(json: string): Promise<void> {
    if (!isTauri) return Promise.resolve();
    return cmd<void>("remote_input", { json });
  },

  remoteRequestKeyframe(): Promise<void> {
    if (!isTauri) return Promise.resolve();
    return cmd<void>("remote_request_keyframe");
  },

  meetingToken(
    serverUrl: string,
    room: string,
    identity: string,
    name: string,
    canPublish: boolean,
  ): Promise<MeetingTokenResult> {
    return cmd<MeetingTokenResult>("meeting_token", {
      serverUrl,
      room,
      identity,
      name,
      canPublish,
    });
  },

  controlledStart(): Promise<void> {
    if (!isTauri) return Promise.resolve();
    return cmd<void>("controlled_start");
  },

  controlledStop(): Promise<void> {
    if (!isTauri) return Promise.resolve();
    return cmd<void>("controlled_stop");
  },

  /** 会中屏幕共享控制：把 §3.2 input 事件注入本机（ev 为 {"t":"input","k":...} 原文） */
  meetingInject(ev: Record<string, unknown>): Promise<void> {
    if (!isTauri) return Promise.resolve();
    return cmd<void>("meeting_inject", { ev });
  },

  /** 会中录制：开始/停止房间录制（走后端 LiveKit Egress） */
  meetingEgressStart(serverUrl: string, room: string): Promise<EgressStartResult> {
    return cmd<EgressStartResult>("meeting_egress_start", { serverUrl, room });
  },

  meetingEgressStop(serverUrl: string, room: string): Promise<EgressStartResult> {
    return cmd<EgressStartResult>("meeting_egress_stop", { serverUrl, room });
  },

  // ---------------- 事件订阅 ----------------

  onFrame(cb: (f: FramePayload) => void): Promise<UnlistenFn> {
    if (!isTauri) return Promise.resolve(demoListen("uu://frame", cb as BusHandler));
    return tauriListen<FramePayload>("uu://frame", (e) => cb(e.payload));
  },

  onStatus(cb: (s: StatusPayload) => void): Promise<UnlistenFn> {
    if (!isTauri) return Promise.resolve(demoListen("uu://status", cb as BusHandler));
    return tauriListen<StatusPayload>("uu://status", (e) => cb(e.payload));
  },
};
