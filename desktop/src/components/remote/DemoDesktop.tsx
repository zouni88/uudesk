import { useEffect, useRef } from "react";

/** 演示模式：前端自绘"远程桌面"动画（假窗口、走动时钟、移动光标） */
export function DemoDesktop({ className = "" }: { className?: string }) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    canvas.width = 1280;
    canvas.height = 720;

    let raf = 0;
    const draw = () => {
      const now = new Date();
      const t = now.getTime() / 1000;

      // 壁纸
      const g = ctx.createLinearGradient(0, 0, 1280, 720);
      g.addColorStop(0, "#0f2b52");
      g.addColorStop(1, "#2a5298");
      ctx.fillStyle = g;
      ctx.fillRect(0, 0, 1280, 720);

      // 桌面图标
      for (let i = 0; i < 4; i++) {
        ctx.fillStyle = "rgba(255,255,255,0.14)";
        roundRect(ctx, 28, 28 + i * 84, 52, 52, 10);
        ctx.fill();
      }

      // 窗口
      ctx.fillStyle = "rgba(24,26,30,0.92)";
      roundRect(ctx, 180, 90, 820, 480, 12);
      ctx.fill();
      ctx.fillStyle = "rgba(255,255,255,0.06)";
      ctx.fillRect(180, 90, 820, 38);
      ["#f54a45", "#ff8800", "#00b96b"].forEach((c, i) => {
        ctx.fillStyle = c;
        ctx.beginPath();
        ctx.arc(206 + i * 20, 109, 5.5, 0, Math.PI * 2);
        ctx.fill();
      });
      ctx.fillStyle = "rgba(255,255,255,0.75)";
      ctx.font = "13px system-ui, 'Microsoft YaHei'";
      ctx.fillText("远程桌面 — 演示画面", 420, 114);

      // 窗口内容：代码行
      ctx.font = "13px Consolas, monospace";
      const code = [
        ["#7aa5ff", "use livekit_client::Room;"],
        ["#8f959e", "// 帧管线：capture -> encode -> relay"],
        ["#4ad49a", "let frame = encoder.encode(argb);"],
        ["#f0b429", "pipeline.push(frame).await?;"],
        ["#7aa5ff", "input.inject(pointer_event).await?;"],
        ["#8f959e", "// 目标延迟 < 120ms"],
      ];
      code.forEach(([c, s], i) => {
        ctx.fillStyle = c;
        ctx.fillText(s, 216, 178 + i * 26);
      });

      // 走动时钟
      ctx.fillStyle = "rgba(255,255,255,0.9)";
      ctx.font = "bold 40px system-ui, 'Microsoft YaHei'";
      ctx.fillText(now.toLocaleTimeString("zh-CN", { hour12: false }), 216, 470);
      ctx.font = "14px system-ui, 'Microsoft YaHei'";
      ctx.fillStyle = "rgba(255,255,255,0.55)";
      ctx.fillText(
        now.toLocaleDateString("zh-CN", { year: "numeric", month: "long", day: "numeric", weekday: "long" }),
        216, 505,
      );

      // 任务栏
      ctx.fillStyle = "rgba(10,12,15,0.85)";
      ctx.fillRect(0, 676, 1280, 44);
      for (let i = 0; i < 6; i++) {
        ctx.fillStyle = "rgba(255,255,255,0.18)";
        roundRect(ctx, 480 + i * 56, 686, 28, 24, 6);
        ctx.fill();
      }
      ctx.fillStyle = "rgba(255,255,255,0.7)";
      ctx.font = "12px system-ui";
      ctx.fillText(now.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit", hour12: false }), 1210, 703);

      // 移动光标
      const cx = 640 + Math.sin(t * 0.6) * 420;
      const cy = 360 + Math.sin(t * 0.9 + 1.2) * 240;
      ctx.fillStyle = "#ffffff";
      ctx.strokeStyle = "#111";
      ctx.lineWidth = 1.2;
      ctx.beginPath();
      ctx.moveTo(cx, cy);
      ctx.lineTo(cx + 15, cy + 15);
      ctx.lineTo(cx + 6.5, cy + 16);
      ctx.lineTo(cx + 11.5, cy + 25);
      ctx.lineTo(cx + 6.5, cy + 27);
      ctx.lineTo(cx + 1, cy + 18);
      ctx.lineTo(cx - 5.5, cy + 23);
      ctx.closePath();
      ctx.fill();
      ctx.stroke();

      raf = requestAnimationFrame(draw);
    };
    draw();
    return () => cancelAnimationFrame(raf);
  }, []);

  return <canvas ref={canvasRef} className={className} />;
}

function roundRect(
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  w: number,
  h: number,
  r: number,
) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}
