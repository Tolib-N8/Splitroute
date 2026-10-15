import React from "react";
import {
  AbsoluteFill, Audio, Easing, Img, OffthreadVideo, Sequence, interpolate, spring, staticFile,
  useCurrentFrame, useVideoConfig,
} from "remotion";

// Токены из Sources/SplitrouteApp/Theme.swift.
const C = {
  bg: "#0A0A0A", surface: "#141414", line: "#262626", text: "#F2F2F2", text2: "#9A9A9A",
  lime: "#C8F542", blue: "#6FA8FF", coral: "#FF6B5E", violet: "#A78BFA",
};
const FONT = "Manrope";
const fontFace = `@font-face { font-family: '${FONT}'; src: url('${staticFile("fonts/Manrope.ttf")}') format('truetype'); font-weight: 200 800; }`;

export const REEL_FRAMES = 600;

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;

/** Детерминированный «рандом». */
const rnd = (i: number, k: number) => {
  const v = Math.sin(i * 12.9898 + k * 78.233) * 43758.5453;
  return v - Math.floor(v);
};

// MARK: — Фон: медленные лаймовые частицы, как на экране «Маршруты»

const Particles: React.FC<{ count?: number; tint?: string }> = ({ count = 110, tint = C.lime }) => {
  const f = useCurrentFrame();
  return (
    <AbsoluteFill>
      <svg width={1080} height={1920}>
        {Array.from({ length: count }).map((_, i) => {
          const speed = 0.4 + rnd(i, 1) * 1.4;
          const x = rnd(i, 2) * 1080 + Math.sin(f / 40 + i) * 14;
          const y = ((rnd(i, 3) * 2200 - f * speed) % 2200 + 2200) % 2200 - 140;
          const r = 0.8 + rnd(i, 4) * 2.2;
          const tw = 0.25 + 0.55 * (0.5 + 0.5 * Math.sin(f / 9 + i * 3.1));
          return <circle key={i} cx={x} cy={y} r={r} fill={rnd(i, 5) > 0.7 ? tint : "#ffffff"} opacity={tw * (rnd(i, 6) > 0.7 ? 0.9 : 0.45)} />;
        })}
      </svg>
    </AbsoluteFill>
  );
};

const Background: React.FC = () => (
  <AbsoluteFill style={{ background: C.bg }}>
    <AbsoluteFill style={{ background: `radial-gradient(70% 45% at 50% 42%, ${C.lime}14, transparent 70%)` }} />
    <Particles />
    <AbsoluteFill style={{ background: "radial-gradient(120% 80% at 50% 50%, transparent 55%, #000000cc 100%)" }} />
  </AbsoluteFill>
);

// MARK: — Типографика

/** Проявление из размытия со сдвигом, на пружине. */
const Reveal: React.FC<{ delay?: number; children: React.ReactNode; y?: number; style?: React.CSSProperties }> = ({ delay = 0, children, y = 40, style }) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  const s = spring({ frame: f - delay, fps, config: { damping: 16, stiffness: 120 } });
  return (
    <div style={{ opacity: s, transform: `translateY(${(1 - s) * y}px)`, filter: `blur(${(1 - s) * 14}px)`, ...style }}>
      {children}
    </div>
  );
};

const Title: React.FC<{ children: React.ReactNode; size?: number; color?: string; weight?: number }> = ({ children, size = 92, color = C.text, weight = 800 }) => (
  <div style={{ fontFamily: FONT, fontSize: size, fontWeight: weight, color, letterSpacing: -size * 0.03, lineHeight: 1.04, textAlign: "center" }}>
    {children}
  </div>
);

/** Плавное появление и исчезновение сцены. */
const SceneFade: React.FC<{ len: number; inF?: number; outF?: number; children: React.ReactNode }> = ({ len, inF = 8, outF = 8, children }) => {
  const f = useCurrentFrame();
  const o = interpolate(f, [0, inF, len - outF, len], [0, 1, 1, 0], clamp);
  return <AbsoluteFill style={{ opacity: o }}>{children}</AbsoluteFill>;
};

// MARK: — Логотип: тот же знак lucide «split», что в приложении

const SPLIT = "M12 22V13.7A4 4 0 0 0 10.83 10.83L3 3M15 9l6-6M3 8V3h5M16 3h5v5";

const Logo: React.FC<{ size: number; draw?: number }> = ({ size, draw = 1 }) => (
  <div style={{
    width: size, height: size, borderRadius: size * 0.27,
    background: "linear-gradient(135deg, #D9FF6B, #9BD11E)",
    boxShadow: `0 0 ${size * 0.6}px ${C.lime}55, inset 0 ${size * 0.04}px ${size * 0.08}px #ffffff55`,
    display: "flex", alignItems: "center", justifyContent: "center",
  }}>
    <svg width={size * 0.56} height={size * 0.56} viewBox="0 0 24 24" fill="none">
      <path d={SPLIT} stroke={C.bg} strokeWidth={2.1} strokeLinecap="round" strokeLinejoin="round"
        pathLength={1} strokeDasharray={1} strokeDashoffset={1 - draw} />
    </svg>
  </div>
);

// MARK: — Кадр из записанного приложения

/** Вырезает область клипа (координаты окна в точках) и вписывает её в ширину `width`. */
const ClipCrop: React.FC<{
  src: string; startFrom?: number; x: number; y: number; w: number; h: number; width: number;
  radius?: number; glow?: boolean; srcW?: number; srcH?: number;
}> = ({ src, startFrom = 0, x, y, w, h, width, radius = 28, glow = true, srcW = 1488, srcH = 1068 }) => {
  const k = width / w;
  return (
    <div style={{
      width, height: h * k, overflow: "hidden", borderRadius: radius, position: "relative",
      border: `1px solid ${C.line}`,
      boxShadow: glow ? `0 40px 120px #000000cc, 0 0 80px ${C.lime}22` : "0 40px 120px #000000cc",
    }}>
      <OffthreadVideo src={staticFile(src)} startFrom={startFrom} muted
        style={{ position: "absolute", left: -x * k, top: -y * k, width: srcW * k, height: srcH * k, maxWidth: "none" }} />
    </div>
  );
};

/** Световая полоса — переход между кадрами. */
const Sweep: React.FC<{ at: number }> = ({ at }) => {
  const f = useCurrentFrame();
  const p = interpolate(f, [at - 6, at + 8], [-0.4, 1.4], clamp);
  if (p <= -0.4 || p >= 1.4) return null;
  return (
    <AbsoluteFill style={{
      background: `linear-gradient(105deg, transparent ${p * 100 - 18}%, ${C.lime}33 ${p * 100 - 4}%, #ffffff55 ${p * 100}%, ${C.lime}33 ${p * 100 + 4}%, transparent ${p * 100 + 18}%)`,
      mixBlendMode: "screen",
    }} />
  );
};

// MARK: — 1. Хук

const Toggle: React.FC<{ on: boolean; label: string }> = ({ on, label }) => (
  <div style={{ display: "flex", alignItems: "center", gap: 22, fontFamily: FONT, fontSize: 44, fontWeight: 700, color: C.text2 }}>
    <div style={{ width: 110, height: 62, borderRadius: 31, background: on ? C.lime : "#2a2a2a", padding: 7, display: "flex", justifyContent: on ? "flex-end" : "flex-start" }}>
      <div style={{ width: 48, height: 48, borderRadius: 24, background: on ? C.bg : "#777" }} />
    </div>
    {label}
  </div>
);

const Breaks: React.FC<{ icon: string; app: string; local: number }> = ({ icon, app, local }) => {
  const shake = local > 8 && local < 20 ? Math.sin(local * 2.4) * 10 : 0;
  return (
    <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 36 }}>
      <div style={{ position: "relative", transform: `translateX(${shake}px)` }}>
        <Img src={staticFile(icon)} style={{ width: 230, height: 230, filter: local > 8 ? "grayscale(0.7) brightness(0.7)" : "none" }} />
        {local > 8 && (
          <div style={{ position: "absolute", right: -16, bottom: -10, width: 92, height: 92, borderRadius: 46, background: C.coral,
            display: "flex", alignItems: "center", justifyContent: "center", fontSize: 58, fontWeight: 800, color: C.bg, fontFamily: FONT,
            transform: `scale(${interpolate(local, [8, 13], [0, 1], { ...clamp, easing: Easing.out(Easing.back(3)) })})` }}>×</div>
        )}
      </div>
      <Title size={100}>{app} <span style={{ color: C.coral }}>breaks.</span></Title>
    </div>
  );
};

const Glitch: React.FC<{ frames: number[]; children: React.ReactNode }> = ({ frames, children }) => {
  const f = useCurrentFrame();
  const g = frames.some((x) => f >= x && f < x + 4);
  if (!g) return <>{children}</>;
  const dx = (rnd(f, 1) - 0.5) * 34;
  return (
    <AbsoluteFill>
      <AbsoluteFill style={{ transform: `translateX(${dx}px)`, opacity: 0.6, filter: "drop-shadow(0 0 0 #ff6b5e)", mixBlendMode: "screen" }}>{children}</AbsoluteFill>
      <AbsoluteFill style={{ transform: `translateX(${-dx}px)`, opacity: 0.6, mixBlendMode: "screen", filter: "hue-rotate(90deg)" }}>{children}</AbsoluteFill>
      {children}
    </AbsoluteFill>
  );
};

const Hook: React.FC = () => {
  const f = useCurrentFrame();
  const phase = f < 34 ? 0 : f < 60 ? 1 : 2;
  const punch = spring({ frame: f - 60, fps: 30, config: { damping: 9, stiffness: 160 } });
  return (
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
      <Glitch frames={[33, 59]}>
        <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 70, flexDirection: "column" }}>
          {phase === 0 && (<>
            <Reveal delay={0}><Toggle on label="VPN on" /></Reveal>
            <Reveal delay={4}><Breaks icon="icons/wechat.png" app="WeChat" local={f} /></Reveal>
          </>)}
          {phase === 1 && (<>
            <Reveal delay={34}><Toggle on={false} label="VPN off" /></Reveal>
            <Reveal delay={37}><Breaks icon="icons/whatsapp.png" app="WhatsApp" local={f - 34} /></Reveal>
          </>)}
          {phase === 2 && (
            <div style={{ transform: `scale(${0.6 + 0.4 * punch})`, opacity: punch }}>
              <Title size={150}>Stop<br /><span style={{ color: C.lime }}>switching.</span></Title>
            </div>
          )}
        </AbsoluteFill>
      </Glitch>
    </AbsoluteFill>
  );
};

// MARK: — 2. Приветствие из приложения

const Splash: React.FC = () => {
  const f = useCurrentFrame();
  const zoom = interpolate(f, [0, 72], [1.08, 1], { ...clamp, easing: Easing.out(Easing.cubic) });
  return (
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", flexDirection: "column", gap: 40 }}>
      <div style={{ transform: `scale(${zoom})`,
        WebkitMaskImage: "radial-gradient(ellipse 50% 50% at 50% 50%, #000 62%, transparent 100%)",
        maskImage: "radial-gradient(ellipse 50% 50% at 50% 50%, #000 62%, transparent 100%)" }}>
        <ClipCrop src="clips/splash.mp4" startFrom={39} x={359} y={370} w={760} h={320} width={1040} radius={0} glow={false} srcW={1478} srcH={1060} />
      </div>
      <Reveal delay={34}>
        <div style={{ fontFamily: FONT, fontSize: 50, fontWeight: 600, color: C.text2, textAlign: "center" }}>
          Per‑app VPN routing for macOS
        </div>
      </Reveal>
    </AbsoluteFill>
  );
};

// MARK: — 3. Потоки

const Pill: React.FC<{ icon: string; app: string; to: string; color: string; delay: number }> = ({ icon, app, to, color, delay }) => {
  const f = useCurrentFrame();
  const s = spring({ frame: f - delay, fps: 30, config: { damping: 12, stiffness: 140 } });
  return (
    <div style={{
      display: "flex", alignItems: "center", gap: 20, padding: "18px 30px 18px 18px", borderRadius: 60,
      background: "#161616ee", border: `1.5px solid ${color}66`, boxShadow: `0 0 40px ${color}22`,
      fontFamily: FONT, fontSize: 40, fontWeight: 700, color: C.text,
      transform: `translateX(${(1 - s) * 160}px) scale(${0.85 + 0.15 * s})`, opacity: s,
    }}>
      <Img src={staticFile(icon)} style={{ width: 64, height: 64 }} />
      {app}
      <span style={{ color: C.text2, fontWeight: 500 }}>→</span>
      <span style={{ color }}>{to}</span>
    </div>
  );
};

const Routes: React.FC = () => {
  const f = useCurrentFrame();
  const t = interpolate(f, [0, 150], [0, 1], { ...clamp, easing: Easing.inOut(Easing.cubic) });
  const enter = spring({ frame: f, fps: 30, config: { damping: 18, stiffness: 70 } });
  return (
    <AbsoluteFill style={{ alignItems: "center" }}>
      <div style={{ marginTop: 200 }}>
        <Reveal delay={2}><Title size={96}>Every app takes</Title></Reveal>
        <Reveal delay={8}><Title size={96} color={C.lime}>its own path</Title></Reveal>
      </div>
      <div style={{ marginTop: 70, perspective: 1800 }}>
        <div style={{
          transform: `rotateX(${(1 - t) * 16}deg) rotateY(${(1 - t) * -18}deg) scale(${(0.55 + 0.45 * enter) * (1 + 0.12 * t)}) translateY(${(1 - enter) * 300}px)`,
          transformStyle: "preserve-3d",
        }}>
          <ClipCrop src="clips/routes.mp4" startFrom={10} x={92} y={0} w={1396} h={1000} width={1000} />
        </div>
      </div>
      <div style={{ position: "absolute", bottom: 150, display: "flex", flexDirection: "column", gap: 22, alignItems: "center" }}>
        <Pill icon="icons/whatsapp.png" app="WhatsApp" to="Tokyo VPN" color={C.lime} delay={40} />
        <Pill icon="icons/telegram.png" app="Telegram" to="Hong Kong VPN" color={C.violet} delay={52} />
        <Pill icon="icons/wechat.png" app="WeChat" to="Direct" color={C.blue} delay={64} />
      </div>
    </AbsoluteFill>
  );
};

// MARK: — 4. Три возможности

const Feature: React.FC<{ title: string; accent: string; sub: string; children: React.ReactNode }> = ({ title, accent, sub, children }) => {
  const f = useCurrentFrame();
  const zoom = interpolate(f, [0, 42], [1.12, 1.0], { ...clamp, easing: Easing.out(Easing.cubic) });
  return (
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", flexDirection: "column", gap: 70 }}>
      <div>
        <Reveal><Title size={104}>{title}</Title></Reveal>
        <Reveal delay={5}><Title size={104} color={C.lime}>{accent}</Title></Reveal>
        <Reveal delay={10}><div style={{ fontFamily: FONT, fontSize: 44, fontWeight: 600, color: C.text2, textAlign: "center", marginTop: 24 }}>{sub}</div></Reveal>
      </div>
      <div style={{ transform: `scale(${zoom})` }}>{children}</div>
    </AbsoluteFill>
  );
};

const Highlight: React.FC<{ top: number; height: number; color: string; delay?: number }> = ({ top, height, color, delay = 12 }) => {
  const f = useCurrentFrame();
  const o = interpolate(f, [delay, delay + 8], [0, 1], clamp) * (0.75 + 0.25 * Math.sin(f / 4));
  return <div style={{ position: "absolute", left: 0, right: 0, top, height, border: `3px solid ${color}`, borderRadius: 18, boxShadow: `0 0 40px ${color}88`, opacity: o }} />;
};

const Features: React.FC = () => (
  <>
    <Sequence durationInFrames={44}>
      <SceneFade len={44} inF={4} outF={4}>
        <Feature title="VPN · Direct" accent="or Block" sub="per app, in one click">
          <ClipCrop src="clips/apps.mp4" startFrom={20} x={100} y={385} w={900} h={455} width={980} />
        </Feature>
      </SceneFade>
    </Sequence>
    <Sequence from={42} durationInFrames={44}>
      <SceneFade len={44} inF={4} outF={4}>
        <Feature title="VPN dropped?" accent="Auto‑backup" sub="apps switch to another VPN">
          <div style={{ position: "relative" }}>
            <ClipCrop src="clips/servers.mp4" startFrom={20} x={100} y={275} w={940} h={180} width={1000} />
            <Highlight top={(393 - 275) * (1000 / 940)} height={60 * (1000 / 940)} color={C.lime} />
          </div>
        </Feature>
      </SceneFade>
    </Sequence>
    <Sequence from={84} durationInFrames={44}>
      <SceneFade len={44} inF={4} outF={6}>
        <Feature title="Blocked site?" accent="One‑click fix" sub="Splitroute spots it for you">
          <div style={{ position: "relative" }}>
            <ClipCrop src="clips/apps.mp4" startFrom={20} x={100} y={245} w={700} h={92} width={1000} />
            <Highlight top={0} height={92 * (1000 / 700)} color="#F5C542" delay={14} />
          </div>
        </Feature>
      </SceneFade>
    </Sequence>
    <Sweep at={42} />
    <Sweep at={84} />
  </>
);

// MARK: — 5. Строка меню

const MenuBar: React.FC = () => {
  const f = useCurrentFrame();
  const drop = spring({ frame: f - 14, fps: 30, config: { damping: 11, stiffness: 110 } });
  const k = 1.75;
  return (
    <AbsoluteFill style={{ alignItems: "center" }}>
      <div style={{ position: "absolute", top: 0, left: 0, right: 0, height: 74, background: "#1b1b1be6", borderBottom: `1px solid ${C.line}`,
        display: "flex", alignItems: "center", justifyContent: "flex-end", gap: 34, padding: "0 44px", fontFamily: FONT, fontSize: 30, fontWeight: 600, color: C.text }}>
        <div style={{ width: 40, height: 40, borderRadius: 11, background: f > 10 ? C.lime : "transparent", display: "flex", alignItems: "center", justifyContent: "center", transition: "none" }}>
          <svg width={26} height={26} viewBox="0 0 24 24" fill="none"><path d={SPLIT} stroke={f > 10 ? C.bg : C.text} strokeWidth={2.2} strokeLinecap="round" strokeLinejoin="round" /></svg>
        </div>
        <span style={{ opacity: 0.8 }}>Wi‑Fi</span>
        <span>9:41</span>
      </div>
      <div style={{ position: "absolute", top: 110, right: 70, transformOrigin: "top right",
        transform: `translateY(${(1 - drop) * -120}px) scale(${0.8 + 0.2 * drop})`, opacity: Math.min(1, drop * 1.4) }}>
        {/* Сверху у клипа — полоса заголовка отладочного окна (28 pt), её не показываем. */}
        <div style={{ width: 380 * k, height: (738 - 28) * k, borderRadius: 16 * k, overflow: "hidden", border: `1px solid ${C.line}`,
          position: "relative", boxShadow: `0 50px 140px #000000ee, 0 0 90px ${C.lime}22` }}>
          <OffthreadVideo src={staticFile("clips/panel.mp4")} startFrom={10} muted
            style={{ position: "absolute", top: -28 * k, left: 0, width: 380 * k, height: 738 * k, maxWidth: "none" }} />
        </div>
      </div>
      <div style={{ position: "absolute", bottom: 150, left: 0, right: 0 }}>
        <Reveal delay={20}><Title size={100}>Lives in your</Title></Reveal>
        <Reveal delay={26}><Title size={100} color={C.lime}>menu bar</Title></Reveal>
      </div>
    </AbsoluteFill>
  );
};

// MARK: — 6. Финал

const Outro: React.FC = () => {
  const f = useCurrentFrame();
  const logoIn = spring({ frame: f, fps: 30, config: { damping: 10, stiffness: 120 } });
  const draw = interpolate(f, [4, 26], [0, 1], { ...clamp, easing: Easing.inOut(Easing.cubic) });
  return (
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", flexDirection: "column", gap: 56 }}>
      <AbsoluteFill style={{ background: `radial-gradient(40% 25% at 50% 45%, ${C.lime}${Math.round(0x30 * logoIn).toString(16).padStart(2, "0")}, transparent 70%)` }} />
      <div style={{ transform: `scale(${0.6 + 0.4 * logoIn})`, opacity: logoIn }}><Logo size={230} draw={draw} /></div>
      <Reveal delay={14}><Title size={140}>Splitroute</Title></Reveal>
      <Reveal delay={22}>
        <div style={{ fontFamily: FONT, fontSize: 46, fontWeight: 600, color: C.text2, textAlign: "center" }}>
          Free & open source · macOS
        </div>
      </Reveal>
      <Reveal delay={30}>
        <div style={{ padding: "22px 40px", borderRadius: 50, background: C.lime, color: C.bg, fontFamily: FONT, fontSize: 40, fontWeight: 800 }}>
          github.com/Tolib-N8/Splitroute
        </div>
      </Reveal>
    </AbsoluteFill>
  );
};

// MARK: — Звук (promo/sfx.swift)

/** Кадр → эффект, громкость. Подогнано под анимации сцен выше. */
const CUES: [number, string, number][] = [
  [1, "click", 0.55], [4, "whoosh", 0.3], [12, "buzz", 0.55],             // VPN on → WeChat breaks
  [32, "glitch", 0.5], [34, "click-low", 0.55], [46, "buzz", 0.55],        // VPN off → WhatsApp breaks
  [58, "glitch", 0.55], [60, "impact", 0.85],                             // Stop switching.
  [74, "whoosh-long", 0.45], [79, "pop", 0.45], [101, "shimmer", 0.55],   // приветствие: логотип, частицы
  [144, "whoosh", 0.5], [150, "whoosh-long", 0.3],                        // окно с потоками
  [188, "pop", 0.4], [200, "pop", 0.4], [212, "pop", 0.4],                // плашки
  [298, "whoosh", 0.5], [340, "whoosh", 0.5], [354, "chime", 0.35],       // три кадра
  [382, "whoosh", 0.5], [398, "pop", 0.45],
  [424, "whoosh", 0.4], [436, "click", 0.5], [440, "whoosh", 0.3], [449, "thud", 0.6], // строка меню
  [484, "riser", 0.5], [516, "impact", 0.45], [518, "pop", 0.4], [522, "shimmer", 0.4], [546, "chime", 0.55], // финал
];

const SoundTrack: React.FC = () => (
  <>
    {CUES.map(([at, name, volume], i) => (
      <Sequence key={i} from={at}>
        <Audio src={staticFile(`sfx/${name}.wav`)} volume={volume} />
      </Sequence>
    ))}
  </>
);

// MARK: — Монтаж

export const Reel: React.FC = () => (
  <AbsoluteFill style={{ background: C.bg }}>
    <style>{fontFace}</style>
    <Background />
    <Sequence durationInFrames={80}><SceneFade len={80} inF={1} outF={6}><Hook /></SceneFade></Sequence>
    <Sequence from={76} durationInFrames={76}><SceneFade len={76} inF={8} outF={8}><Splash /></SceneFade></Sequence>
    <Sequence from={148} durationInFrames={156}><SceneFade len={156}><Routes /></SceneFade></Sequence>
    <Sequence from={300} durationInFrames={130}><Features /></Sequence>
    <Sequence from={426} durationInFrames={94}><SceneFade len={94}><MenuBar /></SceneFade></Sequence>
    <Sequence from={516} durationInFrames={84}><SceneFade len={84} outF={1}><Outro /></SceneFade></Sequence>
    <Sweep at={148} />
    <Sweep at={516} />
    <SoundTrack />
  </AbsoluteFill>
);
