import { useRef } from "react";

interface CodeInputProps {
  value: string;
  onChange: (v: string) => void;
  onComplete?: (v: string) => void;
}

export function CodeInput({ value, onChange, onComplete }: CodeInputProps) {
  const refs = useRef<(HTMLInputElement | null)[]>([]);

  const setAt = (i: number, ch: string) => {
    const arr = (value + "      ").slice(0, 6).split("");
    arr[i] = ch;
    const next = arr.join("").trimEnd();
    onChange(next);
    if (next.length === 6 && /^\d{6}$/.test(next)) onComplete?.(next);
  };

  return (
    <div className="flex gap-2">
      {Array.from({ length: 6 }, (_, i) => (
        <input
          key={i}
          ref={(el) => {
            refs.current[i] = el;
          }}
          value={value[i] ?? ""}
          inputMode="numeric"
          maxLength={1}
          onChange={(e) => {
            const d = e.target.value.replace(/\D/g, "").slice(-1);
            if (d) {
              setAt(i, d);
              refs.current[i + 1]?.focus();
            }
          }}
          onKeyDown={(e) => {
            if (e.key === "Backspace") {
              e.preventDefault();
              if (value[i]) setAt(i, "");
              else {
                setAt(i - 1, "");
                refs.current[i - 1]?.focus();
              }
            }
            if (e.key === "ArrowLeft") refs.current[i - 1]?.focus();
            if (e.key === "ArrowRight") refs.current[i + 1]?.focus();
          }}
          onPaste={(e) => {
            e.preventDefault();
            const t = e.clipboardData.getData("text").replace(/\D/g, "").slice(0, 6);
            if (t) {
              onChange(t);
              refs.current[Math.min(t.length, 5)]?.focus();
              if (t.length === 6) onComplete?.(t);
            }
          }}
          className="h-12 w-10 rounded-lg border border-line bg-raised text-center text-lg font-semibold text-ink outline-none transition-colors focus:border-brand focus:bg-card"
        />
      ))}
    </div>
  );
}
