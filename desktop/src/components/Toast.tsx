import { useSyncExternalStore } from "react";
import { AlertCircle, CheckCircle, Info } from "lucide-react";

export type ToastKind = "info" | "success" | "error";

export interface ToastItem {
  id: number;
  kind: ToastKind;
  text: string;
}

let seq = 1;
let items: ToastItem[] = [];
const subs = new Set<() => void>();

function notify() {
  subs.forEach((fn) => fn());
}

export function toast(text: string, kind: ToastKind = "info"): void {
  const item: ToastItem = { id: seq++, kind, text };
  items = [...items, item];
  notify();
  setTimeout(() => {
    items = items.filter((t) => t.id !== item.id);
    notify();
  }, 3600);
}

function subscribe(fn: () => void): () => void {
  subs.add(fn);
  return () => subs.delete(fn);
}

const ICONS: Record<ToastKind, typeof Info> = {
  info: Info,
  success: CheckCircle,
  error: AlertCircle,
};

const TONE: Record<ToastKind, string> = {
  info: "text-brand",
  success: "text-success",
  error: "text-danger",
};

export function ToastHost() {
  const list = useSyncExternalStore(subscribe, () => items);
  return (
    <div className="pointer-events-none fixed left-1/2 top-6 z-[999] flex -translate-x-1/2 flex-col items-center gap-2">
      {list.map((t) => {
        const Icon = ICONS[t.kind];
        return (
          <div
            key={t.id}
            className="animate-fade-in pointer-events-auto flex items-center gap-2 rounded-xl border border-line bg-card px-4 py-2.5 text-[13px] text-ink shadow-[0_8px_24px_rgba(31,35,41,0.14)]"
          >
            <Icon size={16} className={TONE[t.kind]} />
            <span className="max-w-[420px]">{t.text}</span>
          </div>
        );
      })}
    </div>
  );
}
