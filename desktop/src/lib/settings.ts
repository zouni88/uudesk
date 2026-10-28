import { useSyncExternalStore } from "react";
import { applyTheme, type ThemeMode } from "./theme";

export interface AppSettings {
  serverUrl: string;
  defaultRoom: string;
  theme: ThemeMode;
}

const KEY = "uudesk.settings.v1";

const DEFAULTS: AppSettings = {
  serverUrl: "http://127.0.0.1:8080",
  defaultRoom: "demo-room",
  theme: "light",
};

function load(): AppSettings {
  try {
    const raw = localStorage.getItem(KEY);
    if (raw) return { ...DEFAULTS, ...(JSON.parse(raw) as Partial<AppSettings>) };
  } catch {
    /* ignore */
  }
  return { ...DEFAULTS };
}

let current: AppSettings = load();
applyTheme(current.theme);

const subs = new Set<() => void>();

export function getSettings(): AppSettings {
  return current;
}

export function setSettings(patch: Partial<AppSettings>): void {
  current = { ...current, ...patch };
  try {
    localStorage.setItem(KEY, JSON.stringify(current));
  } catch {
    /* ignore */
  }
  applyTheme(current.theme);
  subs.forEach((fn) => fn());
}

function subscribe(fn: () => void): () => void {
  subs.add(fn);
  return () => subs.delete(fn);
}

export function useSettings(): AppSettings {
  return useSyncExternalStore(subscribe, getSettings);
}
