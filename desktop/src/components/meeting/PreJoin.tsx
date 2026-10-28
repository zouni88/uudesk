import { useCallback, useEffect, useRef, useState } from "react";
import { Camera, CameraOff, Mic, MicOff, Plus, Video } from "lucide-react";
import { Avatar } from "../Avatar";
import { Tooltip } from "../Tooltip";

export interface JoinOptions {
  room: string;
  name: string;
  micOn: boolean;
  camOn: boolean;
  previewStream: MediaStream | null;
  micId?: string;
  camId?: string;
  speakerId?: string;
}

interface PreJoinProps {
  initialRoom: string;
  deviceName: string;
  error?: string | null;
  onJoin: (opts: JoinOptions) => void;
}

export function PreJoin({ initialRoom, deviceName, error, onJoin }: PreJoinProps) {
  const [room, setRoom] = useState(initialRoom);
  const [name, setName] = useState(deviceName);
  const [micOn, setMicOn] = useState(true);
  const [camOn, setCamOn] = useState(true);
  const [mics, setMics] = useState<MediaDeviceInfo[]>([]);
  const [cams, setCams] = useState<MediaDeviceInfo[]>([]);
  const [speakers, setSpeakers] = useState<MediaDeviceInfo[]>([]);
  const [micId, setMicId] = useState("");
  const [camId, setCamId] = useState("");
  const [speakerId, setSpeakerId] = useState("");
  // 竖屏摄像头用 contain 完整显示，否则 16:9 预览框会裁掉画面上下
  const [portraitCam, setPortraitCam] = useState(false);
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const streamRef = useRef<MediaStream | null>(null);

  const refreshDevices = useCallback(async () => {
    try {
      const list = await navigator.mediaDevices.enumerateDevices();
      setMics(list.filter((d) => d.kind === "audioinput"));
      setCams(list.filter((d) => d.kind === "videoinput"));
      setSpeakers(list.filter((d) => d.kind === "audiooutput"));
    } catch {
      // 设备枚举失败不阻塞入会
    }
  }, []);

  useEffect(() => {
    void refreshDevices();
    navigator.mediaDevices.addEventListener("devicechange", refreshDevices);
    return () => navigator.mediaDevices.removeEventListener("devicechange", refreshDevices);
  }, [refreshDevices]);

  useEffect(() => {
    let cancelled = false;
    if (!camOn) {
      streamRef.current?.getTracks().forEach((t) => t.stop());
      streamRef.current = null;
      return;
    }
    // 切换摄像头时先释放上一路，避免旧设备一直占用
    streamRef.current?.getTracks().forEach((t) => t.stop());
    streamRef.current = null;
    const video: MediaTrackConstraints = camId
      ? { deviceId: { exact: camId } }
      : { facingMode: "user" };
    navigator.mediaDevices
      .getUserMedia({ video, audio: false })
      .then((s) => {
        if (cancelled) {
          s.getTracks().forEach((t) => t.stop());
          return;
        }
        streamRef.current = s;
        if (videoRef.current) videoRef.current.srcObject = s;
        // 拿到摄像头权限后设备 label 才可见，刷新一次列表
        void refreshDevices();
      })
      .catch(() => {
        if (!cancelled) streamRef.current = null;
      });
    return () => {
      cancelled = true;
    };
  }, [camOn, camId, refreshDevices]);

  useEffect(() => {
    return () => {
      streamRef.current?.getTracks().forEach((t) => t.stop());
    };
  }, []);

  const join = (r: string) => {
    onJoin({
      room: r.trim() || initialRoom,
      name: name.trim() || deviceName,
      micOn,
      camOn,
      previewStream: streamRef.current,
      micId: micId || undefined,
      camId: camId || undefined,
      speakerId: speakerId || undefined,
    });
  };

  const quickCreate = () => {
    const id = String(Math.floor(100000 + Math.random() * 900000));
    setRoom(id);
    join(id);
  };

  return (
    <div className="flex h-full items-center justify-center p-6">
      <div className="animate-pop-in flex max-h-full w-full max-w-[900px] gap-6 overflow-hidden rounded-2xl border border-line bg-card p-6 shadow-[0_12px_40px_rgba(31,35,41,0.10)]">
        {/* 摄像头预览 */}
        <div className="relative aspect-video min-w-0 flex-1 overflow-hidden rounded-xl bg-[#17181a]">
          <video
            ref={videoRef}
            autoPlay
            muted
            playsInline
            onLoadedMetadata={(e) => {
              const v = e.currentTarget;
              if (v.videoWidth && v.videoHeight) setPortraitCam(v.videoHeight > v.videoWidth);
            }}
            className={`h-full w-full ${portraitCam ? "object-contain" : "object-cover"} ${camOn ? "" : "hidden"}`}
            style={{ transform: "scaleX(-1)" }}
          />
          {!camOn && (
            <div className="absolute inset-0 flex flex-col items-center justify-center gap-3">
              <Avatar name={name || deviceName} size={72} />
              <span className="text-sm text-white/45">摄像头已关闭</span>
            </div>
          )}
          <div className="absolute bottom-3 left-3 flex items-center gap-2">
            <Tooltip label={micOn ? "麦克风开" : "麦克风关"} side="top" dark>
              <button
                onClick={() => setMicOn((v) => !v)}
                className={`flex h-9 w-9 items-center justify-center rounded-full backdrop-blur-sm transition-colors ${
                  micOn ? "bg-white/15 text-white hover:bg-white/25" : "bg-danger text-white hover:bg-danger-active"
                }`}
              >
                {micOn ? <Mic size={16} /> : <MicOff size={16} />}
              </button>
            </Tooltip>
            <Tooltip label={camOn ? "摄像头开" : "摄像头关"} side="top" dark>
              <button
                onClick={() => setCamOn((v) => !v)}
                className={`flex h-9 w-9 items-center justify-center rounded-full backdrop-blur-sm transition-colors ${
                  camOn ? "bg-white/15 text-white hover:bg-white/25" : "bg-danger text-white hover:bg-danger-active"
                }`}
              >
                {camOn ? <Camera size={16} /> : <CameraOff size={16} />}
              </button>
            </Tooltip>
          </div>
        </div>

        {/* 表单 */}
        <div className="flex w-[320px] shrink-0 flex-col overflow-y-auto pr-1">
          <h2 className="text-lg font-semibold text-ink">加入会议</h2>
          <p className="mt-1 text-xs text-ink-3">输入会议号即可加入，摄像头预览已开启</p>

          {error && (
            <p className="mt-3 rounded-lg border border-danger/30 bg-danger/10 px-3 py-2 text-xs leading-5 text-danger">
              {error}
            </p>
          )}

          <label className="mt-6 text-xs font-medium text-ink-2">会议号</label>
          <input
            value={room}
            onChange={(e) => setRoom(e.target.value)}
            placeholder="例如 demo-room"
            className="mt-1.5 h-10 rounded-lg border border-line bg-raised px-3 text-sm text-ink outline-none transition-colors focus:border-brand focus:bg-card"
          />

          <label className="mt-4 text-xs font-medium text-ink-2">昵称</label>
          <input
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="你的昵称"
            className="mt-1.5 h-10 rounded-lg border border-line bg-raised px-3 text-sm text-ink outline-none transition-colors focus:border-brand focus:bg-card"
          />

          <label className="mt-4 text-xs font-medium text-ink-2">麦克风</label>
          <select
            value={micId}
            onChange={(e) => setMicId(e.target.value)}
            className="mt-1.5 h-9 rounded-lg border border-line bg-raised px-2 text-xs text-ink outline-none transition-colors focus:border-brand focus:bg-card"
          >
            <option value="">系统默认</option>
            {mics.map((d, i) => (
              <option key={d.deviceId} value={d.deviceId}>
                {d.label || `麦克风 ${i + 1}`}
              </option>
            ))}
          </select>

          <label className="mt-3 text-xs font-medium text-ink-2">摄像头</label>
          <select
            value={camId}
            onChange={(e) => setCamId(e.target.value)}
            className="mt-1.5 h-9 rounded-lg border border-line bg-raised px-2 text-xs text-ink outline-none transition-colors focus:border-brand focus:bg-card"
          >
            <option value="">系统默认</option>
            {cams.map((d, i) => (
              <option key={d.deviceId} value={d.deviceId}>
                {d.label || `摄像头 ${i + 1}`}
              </option>
            ))}
          </select>

          <label className="mt-3 text-xs font-medium text-ink-2">扬声器</label>
          <select
            value={speakerId}
            onChange={(e) => setSpeakerId(e.target.value)}
            className="mt-1.5 h-9 rounded-lg border border-line bg-raised px-2 text-xs text-ink outline-none transition-colors focus:border-brand focus:bg-card"
          >
            <option value="">系统默认</option>
            {speakers.map((d, i) => (
              <option key={d.deviceId} value={d.deviceId}>
                {d.label || `扬声器 ${i + 1}`}
              </option>
            ))}
          </select>

          <div className="mt-4 flex items-center gap-2">
            <Tooltip label={micOn ? "点击静音" : "点击取消静音"} side="top">
              <button
                onClick={() => setMicOn((v) => !v)}
                className={`flex h-9 w-9 items-center justify-center rounded-full border transition-colors ${
                  micOn
                    ? "border-line bg-raised text-ink hover:border-brand hover:text-brand"
                    : "border-danger/40 bg-danger/10 text-danger"
                }`}
              >
                {micOn ? <Mic size={16} /> : <MicOff size={16} />}
              </button>
            </Tooltip>
            <Tooltip label={camOn ? "点击关闭摄像头" : "点击开启摄像头"} side="top">
              <button
                onClick={() => setCamOn((v) => !v)}
                className={`flex h-9 w-9 items-center justify-center rounded-full border transition-colors ${
                  camOn
                    ? "border-line bg-raised text-ink hover:border-brand hover:text-brand"
                    : "border-danger/40 bg-danger/10 text-danger"
                }`}
              >
                {camOn ? <Camera size={16} /> : <CameraOff size={16} />}
              </button>
            </Tooltip>
          </div>

          <div className="flex-1" />

          <button
            onClick={() => join(room)}
            className="mt-6 flex h-11 items-center justify-center gap-2 rounded-lg bg-brand text-sm font-medium text-white transition-all duration-150 hover:bg-brand-hover active:bg-brand-active"
          >
            <Video size={17} />
            加入会议
          </button>
          <button
            onClick={quickCreate}
            className="mt-2.5 flex h-10 items-center justify-center gap-1.5 rounded-lg border border-line bg-card text-sm text-ink transition-colors duration-150 hover:border-brand hover:text-brand"
          >
            <Plus size={15} />
            快速创建会议
          </button>
        </div>
      </div>
    </div>
  );
}
