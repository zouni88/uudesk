import type { ReactNode } from "react";

interface TooltipProps {
  label: string;
  side?: "top" | "bottom" | "right";
  children: ReactNode;
  dark?: boolean;
}

const POS: Record<NonNullable<TooltipProps["side"]>, string> = {
  top: "bottom-full left-1/2 -translate-x-1/2 mb-2",
  bottom: "top-full left-1/2 -translate-x-1/2 mt-2",
  right: "left-full top-1/2 -translate-y-1/2 ml-3",
};

export function Tooltip({ label, side = "bottom", children, dark = false }: TooltipProps) {
  return (
    <span className="group/tt relative inline-flex">
      {children}
      <span
        className={`pointer-events-none absolute z-50 whitespace-nowrap rounded-md px-2 py-1 text-xs opacity-0 shadow transition-all duration-150 group-hover/tt:opacity-100 ${POS[side]} ${
          dark ? "bg-[#1f2329] text-white" : "bg-white text-[#1f2329] border border-[#e5e6eb]"
        }`}
      >
        {label}
      </span>
    </span>
  );
}
