/** 演示模式共享屏幕：用 canvas 动画伪造一个"活的"桌面画面，captureStream 输出 MediaStream */

let cached: MediaStream | null = null;

export function getFakeScreenStream(): MediaStream | null {
  try {
    if (cached) return cached;
    const canvas = document.createElement("canvas");
    canvas.width = 1280;
    canvas.height = 720;
    const ctx = canvas.getContext("2d");
    if (!ctx) return null;

    const draw = () => {
      const now = new Date();
      // 壁纸
      const g = ctx.createLinearGradient(0, 0, 1280, 720);
      g.addColorStop(0, "#1e3a6e");
      g.addColorStop(1, "#3370ff");
      ctx.fillStyle = g;
      ctx.fillRect(0, 0, 1280, 720);

      // 窗口
      ctx.fillStyle = "rgba(255,255,255,0.96)";
      roundRect(ctx, 140, 90, 720, 460, 14);
      ctx.fill();
      ctx.fillStyle = "#f2f3f5";
      ctx.fillRect(140, 90, 720, 40);
      ctx.fillStyle = "#1f2329";
      ctx.font = "14px system-ui, 'Microsoft YaHei'";
      ctx.fillText("演示共享内容 — 产品原型评审", 168, 116);
      ["#f54a45", "#ff8800", "#00b96b"].forEach((c, i) => {
        ctx.fillStyle = c;
        ctx.beginPath();
        ctx.arc(836 - i * 22, 110, 6, 0, Math.PI * 2);
        ctx.fill();
      });

      ctx.fillStyle = "#646a73";
      ctx.font = "13px system-ui, 'Microsoft YaHei'";
      const lines = [
        "· 会议 UI 对标飞书桌面端",
        "· 远程控制帧率目标 30fps",
        "· NAT 穿透成功率 92%",
        "· 下一步：接入 LiveKit SFU",
      ];
      lines.forEach((t, i) => ctx.fillText(t, 176, 180 + i * 30));

      // 走动时钟
      ctx.fillStyle = "#1f2329";
      ctx.font = "bold 48px system-ui, 'Microsoft YaHei'";
      ctx.fillText(now.toLocaleTimeString("zh-CN", { hour12: false }), 176, 480);

      // 移动光标
      const t = now.getTime() / 1000;
      const cx = 640 + Math.sin(t * 0.7) * 380;
      const cy = 360 + Math.cos(t * 0.5) * 220;
      ctx.fillStyle = "#ffffff";
      ctx.strokeStyle = "#1f2329";
      ctx.beginPath();
      ctx.moveTo(cx, cy);
      ctx.lineTo(cx + 14, cy + 14);
      ctx.lineTo(cx + 6, cy + 15);
      ctx.lineTo(cx + 11, cy + 24);
      ctx.lineTo(cx + 6, cy + 26);
      ctx.lineTo(cx + 1, cy + 17);
      ctx.lineTo(cx - 5, cy + 22);
      ctx.closePath();
      ctx.fill();
      ctx.stroke();

      requestAnimationFrame(draw);
    };
    draw();

    cached = canvas.captureStream(15);
    return cached;
  } catch {
    return null;
  }
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
