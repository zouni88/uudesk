const GRADIENTS: [string, string][] = [
  ["#3370FF", "#7AA5FF"],
  ["#00B96B", "#4AD49A"],
  ["#7B5CFF", "#A78BFF"],
  ["#FF8800", "#FFB25C"],
  ["#F54A45", "#FF8A7E"],
  ["#00A2C8", "#5CC8E0"],
  ["#D83E8A", "#F07CB4"],
  ["#4E5CA8", "#8A96D6"],
];

function hashStr(s: string): number {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0;
  return h;
}

export function avatarGradient(name: string): string {
  const [a, b] = GRADIENTS[hashStr(name) % GRADIENTS.length];
  return `linear-gradient(135deg, ${a}, ${b})`;
}

export function avatarInitial(name: string): string {
  const n = name.trim();
  if (!n) return "?";
  const c = n[0];
  return /[a-z]/i.test(c) ? c.toUpperCase() : c;
}

interface AvatarProps {
  name: string;
  size?: number;
  className?: string;
  disabled?: boolean;
}

export function Avatar({ name, size = 36, className = "", disabled = false }: AvatarProps) {
  return (
    <div
      className={`flex shrink-0 items-center justify-center rounded-full font-medium text-white select-none ${
        disabled ? "opacity-45 grayscale" : ""
      } ${className}`}
      style={{
        width: size,
        height: size,
        backgroundImage: avatarGradient(name),
        fontSize: Math.max(12, size * 0.42),
      }}
    >
      {avatarInitial(name)}
    </div>
  );
}
