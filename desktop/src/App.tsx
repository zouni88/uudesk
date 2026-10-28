import { useEffect, useState } from "react";
import { Sidebar, type PageKey } from "./components/Sidebar";
import { TopBar } from "./components/TopBar";
import { ToastHost } from "./components/Toast";
import { Meeting } from "./pages/Meeting";
import { Remote } from "./pages/Remote";
import { Devices } from "./pages/Devices";
import { Settings } from "./pages/Settings";
import { bridge, type DeviceInfo } from "./lib/bridge";

const TITLES: Record<PageKey, string> = {
  meeting: "会议",
  remote: "远程控制",
  devices: "设备",
  settings: "设置",
};

export default function App() {
  const [page, setPage] = useState<PageKey>("meeting");
  const [inCall, setInCall] = useState(false);
  const [device, setDevice] = useState<DeviceInfo | null>(null);

  useEffect(() => {
    bridge
      .deviceInfo()
      .then(setDevice)
      .catch(() => setDevice({ device_id: "unknown", name: "本机" }));
  }, []);

  return (
    <div className="flex h-screen w-screen overflow-hidden bg-page text-ink">
      <Sidebar active={page} onChange={setPage} device={device} />
      <div className="flex min-w-0 flex-1 flex-col">
        {!inCall && <TopBar title={TITLES[page]} />}
        <main className="min-h-0 flex-1 overflow-hidden">
          {page === "meeting" && <Meeting device={device} setInCall={setInCall} />}
          {page === "remote" && <Remote device={device} />}
          {page === "devices" && <Devices device={device} />}
          {page === "settings" && <Settings />}
        </main>
      </div>
      <ToastHost />
    </div>
  );
}
