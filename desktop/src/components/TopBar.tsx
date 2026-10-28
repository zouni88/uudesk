import { useEffect, useState } from "react";
import { bridge, isTauri } from "../lib/bridge";

export function TopBar({ title }: { title: string }) {
  const [online, setOnline] = useState(!isTauri);

  useEffect(() => {
    let alive = true;
    let un: (() => void) | undefined;
    bridge
      .onStatus((s) => {
        if (alive) setOnline(s.connected);
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

  return (
    <header className="flex h-12 shrink-0 items-center justify-between border-b border-line bg-card px-5">
      <h1 className="text-[15px] font-semibold text-ink">{title}</h1>
      <div
        className={`flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs ${
          online ? "bg-success/10 text-success" : "bg-raised text-ink-3"
        }`}
      >
        <span
          className={`h-1.5 w-1.5 rounded-full ${online ? "bg-success" : "bg-ink-3"}`}
        />
        {online ? "在线" : "离线"}
      </div>
    </header>
  );
}
