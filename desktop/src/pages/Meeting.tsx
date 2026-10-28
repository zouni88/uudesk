import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  Room,
  RoomEvent,
  Track,
  type LocalVideoTrack,
  type RemoteVideoTrack,
} from "livekit-client";

type AttachableVideo = RemoteVideoTrack | LocalVideoTrack;
import { Loader2 } from "lucide-react";
import { bridge, isTauri, type DeviceInfo } from "../lib/bridge";
import { getSettings } from "../lib/settings";
import { toast } from "../components/Toast";
import { PreJoin, type JoinOptions } from "../components/meeting/PreJoin";
import {
  MeetingStage,
  type FloatingReaction,
  type ChatMessage,
  type SlotKind,
  type StageParticipant,
} from "../components/meeting/MeetingStage";
import { getFakeScreenStream } from "../lib/demoScreen";

const LOCAL_ID = "local";
const TOPIC_CHAT = "lk.chat";
const TOPIC_RAISE = "uudesk/raise-hand";
const TOPIC_REACTION = "uudesk/reaction";
const TOPIC_CONTROL = "uudesk/control";

/** LiveKit ConnectionQuality → 展示用质量枚举 */
function qualityOf(q: string): StageParticipant["quality"] {
  return q === "excellent" || q === "good" || q === "poor" || q === "lost" ? q : "unknown";
}

/** 摄像头：竖屏画面用 contain 完整显示（cover 会裁掉上下），横屏仍铺满 */
function applyCameraFit(v: HTMLVideoElement) {
  const fit = () => {
    if (!v.videoWidth || !v.videoHeight) return;
    v.style.objectFit = v.videoHeight > v.videoWidth ? "contain" : "cover";
  };
  fit();
  v.addEventListener("loadedmetadata", fit);
  v.addEventListener("resize", fit);
}

const DEMO_NAMES = ["李明轩", "王雨桐", "陈昊", "赵思远"];
const DEMO_CHATS = [
  "大家好，能听到我说话吗？",
  "我一会儿共享一下屏幕，大家看原型。",
  "这个方案还需要再对一下细节。",
  "稍等，我找个文档发出来。",
  "刚才的结论我同步到群里。",
  "这个需求下周能上线吗？",
  "这里是不是要加一个审批流程？",
  "收到，我下午出一版设计稿。",
];
const DEMO_EMOJIS = ["👍", "❤️", "😂", "🎉"];

type Phase = "prejoin" | "connecting" | "incall";

interface MeetingProps {
  device: DeviceInfo | null;
  setInCall: (b: boolean) => void;
}

function pick<T>(arr: T[]): T {
  return arr[Math.floor(Math.random() * arr.length)];
}

export function Meeting({ device, setInCall }: MeetingProps) {
  const [phase, setPhase] = useState<Phase>("prejoin");

  const [roomCode, setRoomCode] = useState(getSettings().defaultRoom || "demo-room");
  const [participants, setParticipants] = useState<StageParticipant[]>([]);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [reactions, setReactions] = useState<FloatingReaction[]>([]);
  const [drawer, setDrawer] = useState<"none" | "people" | "chat">("none");
  const [joinError, setJoinError] = useState<string | null>(null);
  const [unread, setUnread] = useState(0);
  const [recording, setRecording] = useState(false);
  const [recBusy, setRecBusy] = useState(false);
  const [viewMode, setViewMode] = useState<"grid" | "spotlight">("grid");
  const [elapsed, setElapsed] = useState(0);
  const [micOn, setMicOn] = useState(true);
  const [camOn, setCamOn] = useState(true);
  const [raised, setRaised] = useState(false);
  const [sharingLocal, setSharingLocal] = useState(false);
  const [sharing, setSharing] = useState<{ id: string; name: string } | null>(null);
  const [ctrlReqs, setCtrlReqs] = useState<{ identity: string; name: string }[]>([]);
  const [ctrlGranted, setCtrlGranted] = useState<string[]>([]);
  const [myGrantFrom, setMyGrantFrom] = useState<string | null>(null);

  // refs（避免闭包过期）
  const roomRef = useRef<Room | null>(null);
  const tracksRef = useRef<Map<string, { camera?: AttachableVideo; screen?: AttachableVideo }>>(
    new Map(),
  );
  const slotElsRef = useRef<Map<string, HTMLDivElement>>(new Map());
  // 远端音频元素：LiveKit 不会自动播放远端音频，必须 attach 到 <audio> 并挂到 DOM
  const audioElsRef = useRef<Map<string, HTMLMediaElement>>(new Map());
  const raisedRef = useRef<Map<string, boolean>>(new Map());
  const timersRef = useRef<number[]>([]);
  const previewStreamRef = useRef<MediaStream | null>(null);
  const screenStreamRef = useRef<MediaStream | null>(null);
  const screenIsDisplayRef = useRef(false);
  const demoRef = useRef(false);
  const leavingRef = useRef(false);
  const micOnRef = useRef(true);
  const camOnRef = useRef(true);
  const sharingLocalRef = useRef(false);
  const myNameRef = useRef("");
  const seqRef = useRef(1);
  // 会中控制：观看方 identity -> 名称（本端是共享者时收到的请求）
  const ctrlReqRef = useRef<Map<string, string>>(new Map());
  const ctrlGrantedRef = useRef<Set<string>>(new Set()); // 本端已授权的观看方 identity
  const ctrlGrantFromRef = useRef<string | null>(null); // 本端作为观看方，被哪个共享者授权
  const drawerRef = useRef<"none" | "people" | "chat">("none");

  const syncCtrlState = useCallback(() => {
    setCtrlReqs([...ctrlReqRef.current.entries()].map(([identity, name]) => ({ identity, name })));
    setCtrlGranted([...ctrlGrantedRef.current]);
    setMyGrantFrom(ctrlGrantFromRef.current);
  }, []);

  // ---------------- 消息 / 表情 ----------------

  const appendMessage = useCallback((from: string, text: string, self: boolean) => {
    setMessages((prev) => [...prev, { id: seqRef.current++, from, text, time: Date.now(), self }]);
  }, []);

  const pushReaction = useCallback((emoji: string, name: string) => {
    const id = seqRef.current++;
    setReactions((prev) => [...prev, { id, emoji, name }]);
    window.setTimeout(() => setReactions((prev) => prev.filter((r) => r.id !== id)), 2600);
  }, []);

  // ---------------- 真实模式：成员快照 ----------------

  const rebuild = useCallback(() => {
    const room = roomRef.current;
    if (!room) return;
    const list: StageParticipant[] = [];
    const lp = room.localParticipant;
    // 摄像头“关闭”在 LiveKit 里是 mute 而非取消发布，必须结合 isMuted 判断画面是否可见
    const camShown = (pub: { isMuted?: boolean } | undefined) => !(pub?.isMuted ?? false);
    list.push({
      id: LOCAL_ID,
      name: lp.name || myNameRef.current || "我",
      isLocal: true,
      muted: !micOnRef.current,
      hasVideo:
        !!tracksRef.current.get(LOCAL_ID)?.camera &&
        camShown(lp.getTrackPublication(Track.Source.Camera)),
      speaking: lp.isSpeaking,
      raised: raisedRef.current.get(LOCAL_ID) ?? false,
      quality: qualityOf(lp.connectionQuality),
    });
    // remoteParticipants 以 identity 为键（不是 sid），轨道缓存也统一按 identity 存
    room.remoteParticipants.forEach((p, identity) => {
      list.push({
        id: identity,
        name: p.name || p.identity || "参会者",
        isLocal: false,
        muted: ![...p.audioTrackPublications.values()].some((pub) => !pub.isMuted),
        hasVideo:
          !!tracksRef.current.get(identity)?.camera &&
          camShown(p.getTrackPublication(Track.Source.Camera)),
        speaking: p.isSpeaking,
        raised: raisedRef.current.get(identity) ?? false,
        quality: qualityOf(p.connectionQuality),
      });
    });
    setParticipants(list);

    let share: { id: string; name: string } | null = null;
    tracksRef.current.forEach((v, id) => {
      if (v.screen && !share) {
        const name =
          id === LOCAL_ID
            ? lp.name || myNameRef.current || "我"
            : room.remoteParticipants.get(id)?.name || "参会者";
        share = { id, name };
      }
    });
    setSharing(share);
  }, []);

  // ---------------- 视频槽挂载（真实/演示通用） ----------------

  const attachSlot = useCallback((kind: SlotKind, id: string, el: HTMLDivElement | null) => {
    const key = `${kind}:${id}`;
    if (el === null) {
      slotElsRef.current.delete(key);
      return;
    }
    slotElsRef.current.set(key, el);
    el.innerHTML = "";
    if (demoRef.current) {
      const stream =
        kind === "screen"
          ? screenStreamRef.current
          : id === LOCAL_ID
            ? previewStreamRef.current
            : null;
      if (stream) {
        const v = document.createElement("video");
        v.autoplay = true;
        v.muted = true;
        v.playsInline = true;
        v.srcObject = stream;
        if (kind === "camera" && id === LOCAL_ID) v.style.transform = "scaleX(-1)"; // 自视镜像
        if (kind === "camera") applyCameraFit(v);
        el.appendChild(v);
      }
      return;
    }
    const track = tracksRef.current.get(id)?.[kind];
    if (track) {
      const media = track.attach();
      if (id === LOCAL_ID) {
        (media as HTMLVideoElement).muted = true;
        if (kind === "camera") media.style.transform = "scaleX(-1)"; // 自视镜像
      }
      if (kind === "camera") applyCameraFit(media as HTMLVideoElement);
      el.appendChild(media);
    }
  }, []);

  // ---------------- 会中屏幕共享控制（uudesk/control，identity 寻址） ----------------

  const publishControl = useCallback(
    (msg: Record<string, unknown>, to: string, reliable = true) => {
      if (demoRef.current) return;
      roomRef.current?.localParticipant
        .publishData(new TextEncoder().encode(JSON.stringify(msg)), {
          topic: TOPIC_CONTROL,
          reliable,
          destinationIdentities: [to],
        })
        .catch(() => undefined);
    },
    [],
  );

  /** 观看方：请求共享者授权控制 */
  const requestControl = useCallback(
    (sharerIdentity: string) => publishControl({ a: "req", to: sharerIdentity }, sharerIdentity),
    [publishControl],
  );

  /** 观看方：主动退出控制 */
  const releaseControl = useCallback(() => {
    const s = ctrlGrantFromRef.current;
    ctrlGrantFromRef.current = null;
    syncCtrlState();
    if (s) publishControl({ a: "release", to: s }, s);
  }, [publishControl, syncCtrlState]);

  /** 观看方：发送一条 §3.2 input 事件（move 走不可靠通道降延迟） */
  const sendControlInput = useCallback(
    (ev: Record<string, unknown>) => {
      const s = ctrlGrantFromRef.current;
      if (!s) return;
      publishControl({ a: "input", to: s, ev }, s, ev.k !== "move");
    },
    [publishControl],
  );

  /** 共享方：同意某观看方控制 */
  const grantControl = useCallback(
    (viewerIdentity: string) => {
      ctrlReqRef.current.delete(viewerIdentity);
      ctrlGrantedRef.current.add(viewerIdentity);
      syncCtrlState();
      publishControl({ a: "grant", to: viewerIdentity }, viewerIdentity);
    },
    [publishControl, syncCtrlState],
  );

  /** 共享方：拒绝控制请求（本地清除，不回复） */
  const rejectControl = useCallback(
    (viewerIdentity: string) => {
      ctrlReqRef.current.delete(viewerIdentity);
      syncCtrlState();
    },
    [syncCtrlState],
  );

  /** 共享方：收回全部已授权观看方的控制 */
  const revokeAllControl = useCallback(() => {
    for (const v of ctrlGrantedRef.current) publishControl({ a: "revoke", to: v }, v);
    ctrlGrantedRef.current.clear();
    syncCtrlState();
  }, [publishControl, syncCtrlState]);

  /** 共享方：停止共享/离开——收回全部授权并清空请求 */
  const endControlAsSharer = useCallback(() => {
    for (const v of ctrlGrantedRef.current) publishControl({ a: "revoke", to: v }, v);
    ctrlReqRef.current.clear();
    ctrlGrantedRef.current.clear();
    syncCtrlState();
  }, [publishControl, syncCtrlState]);

  // ---------------- LiveKit 接入 ----------------

  const connectLiveKit = useCallback(
    async (url: string, token: string, opts: JoinOptions) => {
      const room = new Room({ adaptiveStream: true, dynacast: true });
      roomRef.current = room;

      room.on(RoomEvent.ParticipantConnected, () => rebuild());
      room.on(RoomEvent.ParticipantDisconnected, (p) => {
        tracksRef.current.delete(p.identity);
        raisedRef.current.delete(p.identity);
        ctrlReqRef.current.delete(p.identity);
        ctrlGrantedRef.current.delete(p.identity);
        if (ctrlGrantFromRef.current === p.identity) ctrlGrantFromRef.current = null;
        syncCtrlState();
        rebuild();
      });
      room.on(RoomEvent.ActiveSpeakersChanged, () => rebuild());
      room.on(RoomEvent.ConnectionQualityChanged, () => rebuild());
      room.on(RoomEvent.TrackMuted, () => rebuild());
      room.on(RoomEvent.TrackUnmuted, () => rebuild());
      room.on(RoomEvent.TrackSubscribed, (track, pub, participant) => {
        // 远端麦克风音频需要手动 attach，否则完全无声
        if (track.kind === Track.Kind.Audio) {
          const el = track.attach();
          el.autoplay = true;
          audioElsRef.current.set(pub.trackSid, el);
          document.body.appendChild(el);
          room.startAudio().catch((e) => console.warn("startAudio failed:", e));
          return;
        }
        if (track.kind !== Track.Kind.Video) return;
        const isScreen = pub.source === Track.Source.ScreenShare;
        // 按 identity 缓存轨道：与 rebuild() 里的成员 id 保持一致
        const entry = tracksRef.current.get(participant.identity) ?? {};
        entry[isScreen ? "screen" : "camera"] = track as RemoteVideoTrack;
        tracksRef.current.set(participant.identity, entry);
        const el = slotElsRef.current.get(
          `${isScreen ? "screen" : "camera"}:${participant.identity}`,
        );
        if (el) {
          el.innerHTML = "";
          el.appendChild(track.attach());
        }
        rebuild();
      });
      room.on(RoomEvent.TrackUnsubscribed, (track, pub, participant) => {
        if (track.kind === Track.Kind.Audio) {
          const audioEl = audioElsRef.current.get(pub.trackSid);
          if (audioEl) {
            audioEl.remove();
            audioElsRef.current.delete(pub.trackSid);
          }
          track.detach();
          return;
        }
        const isScreen = pub.source === Track.Source.ScreenShare;
        const entry = tracksRef.current.get(participant.identity);
        if (entry) {
          if (isScreen) entry.screen = undefined;
          else entry.camera = undefined;
        }
        const el = slotElsRef.current.get(
          `${isScreen ? "screen" : "camera"}:${participant.identity}`,
        );
        if (el) el.innerHTML = "";
        track.detach();
        rebuild();
      });
      room.on(RoomEvent.LocalTrackPublished, (pub) => {
        if (!pub.track) return;
        const entry = tracksRef.current.get(LOCAL_ID) ?? {};
        if (pub.source === Track.Source.ScreenShare) entry.screen = pub.track as LocalVideoTrack;
        if (pub.source === Track.Source.Camera) entry.camera = pub.track as LocalVideoTrack;
        tracksRef.current.set(LOCAL_ID, entry);
        rebuild();
      });
      room.on(RoomEvent.LocalTrackUnpublished, (pub) => {
        const entry = tracksRef.current.get(LOCAL_ID);
        if (entry) {
          if (pub.source === Track.Source.ScreenShare) entry.screen = undefined;
          if (pub.source === Track.Source.Camera) entry.camera = undefined;
        }
        if (pub.source === Track.Source.ScreenShare) endControlAsSharer();
        rebuild();
      });
      room.on(RoomEvent.DataReceived, (payload, participant, _kind, topic) => {
        const text = new TextDecoder().decode(payload);
        const from = participant?.name || participant?.identity || "参会者";
        // 成员 id 统一用 identity（remoteParticipants 的键）
        const identity = participant?.identity ?? "";
        try {
          if (topic === TOPIC_CHAT || !topic) {
            const obj = JSON.parse(text) as { message?: string };
            appendMessage(from, obj.message ?? text, false);
            if (drawerRef.current !== "chat") setUnread((u) => u + 1);
          } else if (topic === TOPIC_RAISE) {
            const obj = JSON.parse(text) as { raised?: boolean };
            raisedRef.current.set(identity, !!obj.raised);
            rebuild();
          } else if (topic === TOPIC_REACTION) {
            const obj = JSON.parse(text) as { emoji?: string };
            if (obj.emoji) pushReaction(obj.emoji, from);
          } else if (topic === TOPIC_CONTROL) {
            const obj = JSON.parse(text) as { a?: string; to?: string; ev?: Record<string, unknown> };
            const r = roomRef.current;
            const fromId = participant?.identity ?? "";
            // identity 寻址：to 不是本端 / 无来源 identity 的消息忽略
            if (!r || !obj.a || !obj.to || obj.to !== r.localParticipant.identity || !fromId) return;
            switch (obj.a) {
              case "req":
                if (sharingLocalRef.current) {
                  ctrlReqRef.current.set(fromId, from);
                  syncCtrlState();
                }
                break;
              case "grant":
                ctrlGrantFromRef.current = fromId;
                syncCtrlState();
                break;
              case "revoke":
                if (ctrlGrantFromRef.current === fromId) {
                  ctrlGrantFromRef.current = null;
                  syncCtrlState();
                }
                break;
              case "release":
                ctrlReqRef.current.delete(fromId);
                ctrlGrantedRef.current.delete(fromId);
                syncCtrlState();
                break;
              case "input":
                if (sharingLocalRef.current && ctrlGrantedRef.current.has(fromId) && obj.ev) {
                  bridge.meetingInject(obj.ev).catch(() => undefined);
                }
                break;
            }
          }
        } catch {
          /* 忽略畸形数据 */
        }
      });
      room.on(RoomEvent.Reconnecting, () => toast("网络波动，正在重连…"));
      room.on(RoomEvent.Reconnected, () => {
        toast("已重新连接");
        rebuild();
      });
      room.on(RoomEvent.Disconnected, (reason) => {
        if (leavingRef.current) return; // 主动离开不提示
        toast(reason ? `会议连接已断开（${reason}）` : "会议连接已断开", "error");
        leave();
      });

      await room.connect(url, token);
      // 昵称：token 里不透传 name，入会后用 setName 更新，否则别人只看到 identity
      await room.localParticipant.setName(opts.name || myNameRef.current || "参会者").catch((e) => {
        console.warn("setName failed:", e);
      });
      // 按入会前选择的设备切换
      if (opts.micId) await room.switchActiveDevice("audioinput", opts.micId).catch(() => undefined);
      if (opts.camId) await room.switchActiveDevice("videoinput", opts.camId).catch(() => undefined);
      if (opts.speakerId) {
        await room.switchActiveDevice("audiooutput", opts.speakerId).catch(() => undefined);
      }
      // 释放预览摄像头，交给 LiveKit 接管
      previewStreamRef.current?.getTracks().forEach((t) => t.stop());
      previewStreamRef.current = null;
      // 轨道启动失败只提示，不影响入会（连接已成功）
      if (opts.micOn) {
        await room.localParticipant.setMicrophoneEnabled(true).catch(() => {
          toast("麦克风开启失败，请检查系统隐私设置", "error");
        });
      }
      if (opts.camOn) {
        await room.localParticipant.setCameraEnabled(true).catch(() => {
          toast("摄像头开启失败，请检查系统隐私设置", "error");
        });
      }
      await room.startAudio().catch(() => undefined);
      rebuild();
    },
    [appendMessage, endControlAsSharer, pushReaction, rebuild, syncCtrlState],
  );

  // ---------------- 演示模式 ----------------

  const startDemo = useCallback(
    (opts: JoinOptions) => {
      demoRef.current = true;
      const list: StageParticipant[] = [
        {
          id: LOCAL_ID,
          name: opts.name || "我",
          isLocal: true,
          muted: !opts.micOn,
          hasVideo: !!opts.previewStream,
          speaking: false,
          raised: false,
          quality: "excellent" as const,
        },
        ...DEMO_NAMES.map((n, i) => ({
          id: `demo-${i}`,
          name: n,
          isLocal: false,
          muted: i % 3 === 1,
          hasVideo: false,
          speaking: false,
          raised: false,
          quality: "good" as const,
        })),
      ];
      setParticipants(list);

      // 说话光环轮换
      timersRef.current.push(
        window.setInterval(() => {
          setParticipants((prev) => {
            const active = prev.filter((p) => !p.isLocal && !p.muted);
            const chosen = active.length ? pick(active) : null;
            return prev.map((p) => ({ ...p, speaking: !!chosen && p.id === chosen.id }));
          });
        }, 2600),
      );

      // 模拟聊天（8-15s 一条）
      const chatLoop = () => {
        const d = 8000 + Math.random() * 7000;
        timersRef.current.push(
          window.setTimeout(() => {
            appendMessage(pick(DEMO_NAMES), pick(DEMO_CHATS), false);
            chatLoop();
          }, d),
        );
      };
      chatLoop();

      // 随机举手
      timersRef.current.push(
        window.setInterval(() => {
          setParticipants((prev) => {
            if (prev.length < 2) return prev;
            const idx = 1 + Math.floor(Math.random() * (prev.length - 1));
            return prev.map((p, i) => (i === idx ? { ...p, raised: !p.raised } : p));
          });
        }, 17000),
      );

      // 表情飘屏
      timersRef.current.push(
        window.setInterval(() => {
          pushReaction(pick(DEMO_EMOJIS), pick(DEMO_NAMES));
        }, 15000),
      );
    },
    [appendMessage, pushReaction],
  );

  const clearDemoTimers = () => {
    timersRef.current.forEach((id) => {
      window.clearTimeout(id);
      window.clearInterval(id);
    });
    timersRef.current = [];
  };

  // ---------------- 加入 / 离开 ----------------

  const handleJoin = useCallback(
    async (opts: JoinOptions) => {
      leavingRef.current = false;
      myNameRef.current = opts.name;
      micOnRef.current = opts.micOn;
      camOnRef.current = opts.camOn;
      previewStreamRef.current = opts.previewStream;
      setMicOn(opts.micOn);
      setCamOn(opts.camOn);
      setRoomCode(opts.room);
      setElapsed(0);
      setMessages([]);
      setReactions([]);
      setDrawer("none");
      drawerRef.current = "none";
      setUnread(0);
      setJoinError(null);
      setRecording(false);
      setRecBusy(false);
      setViewMode("grid");
      setRaised(false);
      setSharingLocal(false);
      setSharingLocalRefSafe(false);
      setSharing(null);
      ctrlReqRef.current.clear();
      ctrlGrantedRef.current.clear();
      ctrlGrantFromRef.current = null;
      syncCtrlState();
      setInCall(true);

      if (!isTauri) {
        startDemo(opts);
        setPhase("incall");
        return;
      }
      setPhase("connecting");
      try {
        const server = getSettings().serverUrl;
        const identity = `u-${Math.random().toString(36).slice(2, 8)}`;
        const t = await bridge.meetingToken(server, opts.room, identity, opts.name, true);
        await connectLiveKit(t.server_url, t.token, opts);
        demoRef.current = false;
        setPhase("incall");
      } catch (e) {
        console.warn("meeting join failed:", e);
        if (roomRef.current?.state === "connected") {
          // 信令与媒体已连通，仅后续步骤异常，保留真实会议
          demoRef.current = false;
          setPhase("incall");
          return;
        }
        // 不再静默切到“演示模式”（假参会人会让人误以为真有人在线），改为报错并可重试
        setJoinError(`连接会议失败：${e instanceof Error ? e.message : String(e)}`);
        setPhase("prejoin");
        setInCall(false);
      }
    },
    [connectLiveKit, setInCall, startDemo, syncCtrlState],
  );

  const leave = useCallback(() => {
    clearDemoTimers();
    demoRef.current = false;
    leavingRef.current = true;
    // 会中控制：离开前收回全部授权（revoke）并退出控制（release）
    endControlAsSharer();
    releaseControl();
    if (roomRef.current) {
      roomRef.current.disconnect().catch(() => undefined);
      roomRef.current = null;
    }
    tracksRef.current.clear();
    raisedRef.current.clear();
    slotElsRef.current.clear();
    audioElsRef.current.forEach((el) => el.remove());
    audioElsRef.current.clear();
    previewStreamRef.current?.getTracks().forEach((t) => t.stop());
    previewStreamRef.current = null;
    screenStreamRef.current?.getTracks().forEach((t) => t.stop());
    screenStreamRef.current = null;
    screenIsDisplayRef.current = false;
    setParticipants([]);
    setSharing(null);
    setSharingLocal(false);
    setRaised(false);
    setRecording(false);
    setRecBusy(false);
    setPhase("prejoin");
    setInCall(false);
  }, [endControlAsSharer, releaseControl, setInCall]);

  /** 离开前二次确认，避免误点“离开”直接退会 */
  const handleLeave = useCallback(() => {
    if (!window.confirm("确定要离开会议吗？")) return;
    leave();
  }, [leave]);

  /** 抽屉切换：打开聊天时清空未读 */
  const changeDrawer = useCallback((d: "none" | "people" | "chat") => {
    drawerRef.current = d;
    if (d === "chat") setUnread(0);
    setDrawer(d);
  }, []);

  /** 房间录制：走后端 LiveKit Egress（开始/停止） */
  const toggleRecord = useCallback(async () => {
    if (recBusy) return;
    if (!isTauri) {
      toast("演示模式不支持录制", "error");
      return;
    }
    const server = getSettings().serverUrl;
    setRecBusy(true);
    try {
      if (!recording) {
        const r = await bridge.meetingEgressStart(server, roomCode);
        if (r.command) {
          // LiveKit 录制服务不可达，后端给出人工执行命令
          console.info("egress command:", r.command);
          toast("录制服务不可达，已生成手工命令（见控制台）", "error");
          return;
        }
        setRecording(true);
        toast("已开始录制");
      } else {
        await bridge.meetingEgressStop(server, roomCode);
        setRecording(false);
        toast("已停止录制，文件稍后可在录制列表查看");
      }
    } catch (e) {
      toast(`录制操作失败：${e instanceof Error ? e.message : String(e)}`, "error");
    } finally {
      setRecBusy(false);
    }
  }, [recBusy, recording, roomCode]);

  const setSharingLocalRefSafe = (v: boolean) => {
    sharingLocalRef.current = v;
    setSharingLocal(v);
  };

  // ---------------- 控制条动作 ----------------

  const updateLocal = (patch: Partial<StageParticipant>) =>
    setParticipants((prev) => prev.map((p) => (p.isLocal ? { ...p, ...patch } : p)));

  const toggleMic = () => {
    const v = !micOnRef.current;
    micOnRef.current = v;
    setMicOn(v);
    if (demoRef.current) updateLocal({ muted: !v });
    else {
      const lp = roomRef.current?.localParticipant;
      if (!lp) return;
      lp.setMicrophoneEnabled(v)
        .then(() => rebuild())
        .catch(() => {
          // 失败时回滚 UI，避免“显示已开麦但实际没采到音”
          micOnRef.current = !v;
          setMicOn(!v);
          rebuild();
          toast(v ? "麦克风开启失败，请检查系统隐私设置" : "静音失败，请重试", "error");
        });
    }
  };

  const toggleCam = () => {
    const v = !camOnRef.current;
    camOnRef.current = v;
    setCamOn(v);
    if (demoRef.current) {
      if (!v) {
        const el = slotElsRef.current.get(`camera:${LOCAL_ID}`);
        if (el) el.innerHTML = "";
      }
      updateLocal({ hasVideo: v && !!previewStreamRef.current });
    } else {
      const lp = roomRef.current?.localParticipant;
      if (!lp) return;
      lp.setCameraEnabled(v)
        .then(() => rebuild())
        .catch(() => {
          camOnRef.current = !v;
          setCamOn(!v);
          rebuild();
          toast(v ? "摄像头开启失败，请检查系统隐私设置" : "关闭摄像头失败，请重试", "error");
        });
    }
  };

  const stopShare = () => {
    endControlAsSharer();
    if (screenIsDisplayRef.current) screenStreamRef.current?.getTracks().forEach((t) => t.stop());
    screenStreamRef.current = null;
    screenIsDisplayRef.current = false;
    setSharingLocalRefSafe(false);
    setSharing(null);
    const el = slotElsRef.current.get(`screen:${LOCAL_ID}`);
    if (el) el.innerHTML = "";
  };

  const toggleShare = async () => {
    if (sharingLocalRef.current) {
      if (demoRef.current) stopShare();
      else {
        roomRef.current?.localParticipant.setScreenShareEnabled(false).catch(() => undefined);
      }
      return;
    }
    if (demoRef.current) {
      try {
        const stream = await navigator.mediaDevices.getDisplayMedia({ video: true });
        screenStreamRef.current = stream;
        screenIsDisplayRef.current = true;
        stream.getVideoTracks()[0].addEventListener("ended", stopShare);
      } catch {
        const fake = getFakeScreenStream();
        if (!fake) {
          toast("无法开始屏幕共享", "error");
          return;
        }
        screenStreamRef.current = fake;
        screenIsDisplayRef.current = false;
      }
      setSharingLocalRefSafe(true);
      setSharing({ id: LOCAL_ID, name: myNameRef.current || "我" });
      const el = slotElsRef.current.get(`screen:${LOCAL_ID}`);
      if (el) attachSlot("screen", LOCAL_ID, el);
    } else {
      try {
        // 带系统声音共享；部分环境不支持音频采集时降级为纯视频
        await roomRef.current?.localParticipant.setScreenShareEnabled(true, { audio: true });
      } catch (e) {
        if ((e as Error)?.name === "NotAllowedError") return; // 用户取消选择，不再重试
        try {
          await roomRef.current?.localParticipant.setScreenShareEnabled(true);
        } catch {
          toast("无法开始屏幕共享", "error");
        }
      }
    }
  };

  const toggleRaise = () => {
    const v = !raised;
    setRaised(v);
    raisedRef.current.set(LOCAL_ID, v);
    if (demoRef.current) updateLocal({ raised: v });
    else {
      rebuild();
      roomRef.current?.localParticipant
        .publishData(
          new TextEncoder().encode(JSON.stringify({ raised: v })),
          { topic: TOPIC_RAISE, reliable: true },
        )
        .catch(() => undefined);
    }
  };

  const sendReaction = (emoji: string) => {
    pushReaction(emoji, myNameRef.current || "我");
    if (!demoRef.current) {
      roomRef.current?.localParticipant
        .publishData(new TextEncoder().encode(JSON.stringify({ emoji })), {
          topic: TOPIC_REACTION,
          reliable: true,
        })
        .catch(() => undefined);
    }
  };

  const sendChat = (text: string) => {
    appendMessage(myNameRef.current || "我", text, true);
    if (!demoRef.current) {
      roomRef.current?.localParticipant
        .publishData(new TextEncoder().encode(JSON.stringify({ message: text })), {
          topic: TOPIC_CHAT,
          reliable: true,
        })
        .catch(() => undefined);
    }
  };

  // 当前共享者的 identity（协议寻址用；演示模式无 room 自然为 null，控制功能禁用）
  const sharerIdentity = useMemo(() => {
    if (!sharing) return null;
    const room = roomRef.current;
    if (!room) return null;
    return sharing.id === LOCAL_ID
      ? room.localParticipant.identity
      : (room.remoteParticipants.get(sharing.id)?.identity ?? null);
  }, [sharing]);

  // ---------------- 计时 ----------------

  useEffect(() => {
    if (phase !== "incall") return;
    const id = window.setInterval(() => setElapsed((e) => e + 1), 1000);
    return () => window.clearInterval(id);
  }, [phase]);

  // 会中快捷键：Ctrl+M 静音 / Ctrl+E 摄像头（输入框内不拦截）
  useEffect(() => {
    if (phase !== "incall") return;
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement | null;
      if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return;
      if (!e.ctrlKey || e.shiftKey || e.altKey) return;
      const k = e.key.toLowerCase();
      if (k === "m") {
        e.preventDefault();
        toggleMic();
      } else if (k === "e") {
        e.preventDefault();
        toggleCam();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [phase, toggleMic, toggleCam]);

  // 离开页面时清理
  useEffect(() => {
    return () => {
      clearDemoTimers();
      leavingRef.current = true;
      roomRef.current?.disconnect().catch(() => undefined);
      roomRef.current = null;
      // 组件卸载时也要停采集，避免仍在后台录屏/占用摄像头
      previewStreamRef.current?.getTracks().forEach((t) => t.stop());
      screenStreamRef.current?.getTracks().forEach((t) => t.stop());
      audioElsRef.current.forEach((el) => el.remove());
      audioElsRef.current.clear();
      setInCall(false);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // ---------------- 渲染 ----------------

  if (phase === "connecting") {
    return (
      <div className="flex h-full flex-col items-center justify-center gap-4">
        <Loader2 size={36} className="animate-spin text-brand" />
        <p className="text-sm text-ink-2">正在加入会议 {roomCode}…</p>
      </div>
    );
  }

  if (phase === "incall") {
    return (
      <MeetingStage
        roomCode={roomCode}
        elapsed={elapsed}
        participants={participants}
        localId={LOCAL_ID}
        sharing={sharing}
        viewMode={viewMode}
        setViewMode={setViewMode}
        attachSlot={attachSlot}
        micOn={micOn}
        camOn={camOn}
        sharingLocal={sharingLocal}
        raised={raised}
        onToggleMic={toggleMic}
        onToggleCam={toggleCam}
        onToggleShare={toggleShare}
        onToggleRaise={toggleRaise}
        onReaction={sendReaction}
        onLeave={handleLeave}
        messages={messages}
        onSendChat={sendChat}
        reactions={reactions}
        drawer={drawer}
        setDrawer={changeDrawer}
        unreadChat={unread}
        recording={recording}
        recBusy={recBusy}
        onToggleRecord={() => void toggleRecord()}
        sharerIdentity={sharerIdentity}
        isLocalSharer={!!sharing && sharing.id === LOCAL_ID}
        controlRequests={ctrlReqs}
        grantedCount={ctrlGranted.length}
        myGrantFrom={myGrantFrom}
        onRequestControl={requestControl}
        onReleaseControl={releaseControl}
        onGrantControl={grantControl}
        onRejectControl={rejectControl}
        onRevokeControl={revokeAllControl}
        onControlInput={sendControlInput}
      />
    );
  }

  return (
    <PreJoin
      initialRoom={roomCode}
      deviceName={device?.name ?? "本机"}
      error={joinError}
      onJoin={handleJoin}
    />
  );
}
