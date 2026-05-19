/* Shared primitives for Autodev mockups (theme-aware) */

// ── Logo ─────────────────────────────────────────────────────────────────
// Stacked-cards mark: light violet card on top with </> glyph, deeper violet
// behind it, and two small pin-circles + a dashed hint of automation flow.
function AutodevLogoMark({ size = 28 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 56 56" fill="none" aria-hidden style={{ flex: "0 0 auto", display: "block" }}>
      {/* Back card (deeper violet) */}
      <rect x="20" y="20" width="30" height="30" rx="7" fill="#4A35C9"/>
      {/* Dashed automation arc on the back card */}
      <path d="M48 38 Q 48 48 38 48" stroke="#B5A8FA" strokeWidth="1.6" strokeLinecap="round" strokeDasharray="2 3" fill="none" opacity="0.85"/>
      {/* Front card (light violet) */}
      <rect x="6" y="6" width="30" height="30" rx="7" fill="#8771F4"/>
      {/* </> glyph */}
      <path d="M16 16 L11 21 L16 26" stroke="white" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" fill="none"/>
      <path d="M26 16 L31 21 L26 26" stroke="white" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" fill="none"/>
      <path d="M24 14 L18 28" stroke="white" strokeWidth="2.4" strokeLinecap="round"/>
      {/* Top-right pin-circle */}
      <circle cx="42" cy="14" r="3.6" fill="#FFFFFF" stroke="#4A35C9" strokeWidth="2"/>
      {/* Bottom-left pin-circle */}
      <circle cx="14" cy="42" r="3.6" fill="#FFFFFF" stroke="#4A35C9" strokeWidth="2"/>
    </svg>
  );
}

// Avatar = same mark, used as Autodev's profile picture in chat etc.
function AutodevAvatar({ size = 28 }) { return <AutodevLogoMark size={size}/>; }

function AutodevLogo({ size = 24, withWord = true }) {
  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: 8, color: "var(--text-strong)" }}>
      <AutodevLogoMark size={size}/>
      {withWord && <span style={{ fontWeight: 700, letterSpacing: -0.4, fontSize: Math.round(size * 0.7) }}>autodev</span>}
    </span>
  );
}

// ── Status mapping ───────────────────────────────────────────────────────
const STATUS = {
  pending:               { label: "En attente",                tone: "neutral",  short: "À traiter",       step: 0 },
  cloning:               { label: "Préparation",               tone: "working",  short: "Préparation",     step: 1 },
  checking_spec:         { label: "Lecture du besoin",         tone: "working",  short: "Analyse",         step: 2 },
  needs_clarification:   { label: "Question pour vous",        tone: "warn",     short: "À clarifier",     step: 2 },
  implementing:          { label: "Développement en cours",    tone: "working",  short: "Développement",   step: 3 },
  committing:            { label: "Sauvegarde du travail",     tone: "working",  short: "Sauvegarde",      step: 4 },
  pushing:               { label: "Envoi sur GitLab",          tone: "working",  short: "Envoi",           step: 4 },
  creating_mr:           { label: "Création de la demande",    tone: "working",  short: "Création MR",     step: 5 },
  reviewing:             { label: "Relecture automatique",     tone: "working",  short: "Relecture",       step: 6 },
  checking_pipeline:     { label: "Vérifications auto.",       tone: "working",  short: "Vérifications",   step: 6 },
  fixing_discussions:    { label: "Corrections après revue",   tone: "working",  short: "Corrections",     step: 7 },
  fixing_pipeline:       { label: "Correction des tests",      tone: "working",  short: "Tests à corriger",step: 7 },
  running_post_completion:{label: "Finalisation",              tone: "working",  short: "Finalisation",    step: 8 },
  answering_question:    { label: "Réponse en préparation",    tone: "working",  short: "Réponse",         step: 3 },
  done:                  { label: "Terminé",                   tone: "ok",       short: "Terminé",         step: 9 },
  error:                 { label: "Échec — action requise",    tone: "err",      short: "Échec",           step: -1 },
};

function statusOf(key) { return STATUS[key] || { label: key, tone: "neutral", short: key, step: 0 }; }

const TONE_VARS = {
  neutral: { bg: "var(--paper-2)",  fg: "var(--text-muted)", dot: "var(--text-subtle)" },
  working: { bg: "var(--work-bg)",  fg: "var(--work-fg)",    dot: "var(--work-500)" },
  ok:      { bg: "var(--ok-bg)",    fg: "var(--ok-fg)",      dot: "var(--ok-500)" },
  warn:    { bg: "var(--warn-bg)",  fg: "var(--warn-fg)",    dot: "var(--warn-500)" },
  err:     { bg: "var(--err-bg)",   fg: "var(--err-fg)",     dot: "var(--err-500)" },
  info:    { bg: "var(--info-bg)",  fg: "var(--info-fg)",    dot: "var(--info-500)" },
  accent:  { bg: "var(--accent-bg)",fg: "var(--accent-fg)",  dot: "var(--accent-solid)" },
};

// ── Status pill ──────────────────────────────────────────────────────────
function StatusPill({ status, size = "md", withDot = true }) {
  const s = statusOf(status);
  const t = TONE_VARS[s.tone] || TONE_VARS.neutral;
  const sizes = {
    sm: { padding: "2px 8px", fontSize: 11, gap: 5, dot: 5 },
    md: { padding: "3px 10px", fontSize: 12, gap: 6, dot: 6 },
    lg: { padding: "5px 12px", fontSize: 13, gap: 7, dot: 7 },
  };
  const z = sizes[size];
  const animated = s.tone === "working";
  return (
    <span style={{
      display: "inline-flex", alignItems: "center", gap: z.gap,
      padding: z.padding, fontSize: z.fontSize, fontWeight: 500,
      background: t.bg, color: t.fg, borderRadius: "var(--r-pill)",
      whiteSpace: "nowrap", lineHeight: 1.4,
    }}>
      {withDot && (
        <span style={{
          width: z.dot, height: z.dot, borderRadius: "50%", background: t.dot,
          animation: animated ? "pulse 1.6s ease-out infinite" : "none",
        }}/>
      )}
      {s.label}
    </span>
  );
}

// ── Buttons ──────────────────────────────────────────────────────────────
function Button({ children, kind = "secondary", size = "md", icon, iconRight, full, disabled, onClick, style }) {
  const sizes = {
    sm: { padding: "5px 10px", fontSize: 12, gap: 6, radius: "var(--r-sm)" },
    md: { padding: "8px 14px", fontSize: 13, gap: 8, radius: "var(--r-md)" },
    lg: { padding: "11px 18px", fontSize: 14, gap: 10, radius: "var(--r-md)" },
  };
  const z = sizes[size];
  const variants = {
    primary:     { background: "var(--accent-solid)", color: "var(--text-on-accent)", border: "1px solid var(--accent-solid-hover)", boxShadow: "0 1px 0 rgba(0,0,0,0.06), inset 0 1px 0 rgba(255,255,255,0.12)" },
    secondary:   { background: "var(--paper)",        color: "var(--text)",           border: "1px solid var(--border)",            boxShadow: "var(--shadow-xs)" },
    ghost:       { background: "transparent",         color: "var(--text-muted)",     border: "1px solid transparent" },
    danger:      { background: "var(--paper)",        color: "var(--err-fg)",         border: "1px solid var(--err-200)" },
    dangerSolid: { background: "var(--err-500)",      color: "white",                  border: "1px solid var(--err-700)" },
    okSolid:     { background: "var(--ok-500)",       color: "white",                  border: "1px solid var(--ok-700)" },
  };
  const v = variants[kind] || variants.secondary;
  return (
    <button onClick={onClick} disabled={disabled} style={{
      display: "inline-flex", alignItems: "center", justifyContent: "center", gap: z.gap,
      padding: z.padding, fontSize: z.fontSize, fontWeight: 500,
      borderRadius: z.radius, ...v, width: full ? "100%" : "auto",
      opacity: disabled ? 0.5 : 1, cursor: disabled ? "not-allowed" : "pointer",
      ...style,
    }}>
      {icon}
      {children}
      {iconRight}
    </button>
  );
}

function IconButton({ icon, size = 30, onClick, label, active }) {
  return (
    <button aria-label={label} onClick={onClick} style={{
      width: size, height: size, borderRadius: 8,
      display: "inline-flex", alignItems: "center", justifyContent: "center",
      color: active ? "var(--accent-fg)" : "var(--text-muted)",
      background: active ? "var(--accent-bg)" : "transparent",
      border: "1px solid transparent",
    }}>{icon}</button>
  );
}

// ── Card ─────────────────────────────────────────────────────────────────
function Card({ children, padding = 20, style }) {
  return (
    <div style={{
      background: "var(--paper)", border: "1px solid var(--border)",
      borderRadius: "var(--r-lg)", padding, boxShadow: "var(--shadow-xs)", ...style,
    }}>{children}</div>
  );
}

// ── Avatars ──────────────────────────────────────────────────────────────
function Avatar({ name, size = 28, color }) {
  const initials = (name || "?").split(" ").filter(Boolean).slice(0, 2).map(s => s[0]).join("").toUpperCase();
  const palette = ["#5E47E8", "#2A6FDB", "#1F8A7E", "#B57A12", "#C4413B", "#8E2A26", "#4A35C9"];
  const pick = color || palette[(name || "").charCodeAt(0) % palette.length];
  return (
    <span style={{
      display: "inline-flex", alignItems: "center", justifyContent: "center",
      width: size, height: size, borderRadius: "50%",
      background: pick, color: "white", fontSize: size * 0.4, fontWeight: 600,
      flex: "0 0 auto",
    }}>{initials}</span>
  );
}

// "Claude / Autodev" avatar — same as AutodevAvatar (the agent IS Autodev in this UI)
function ClaudeAvatar({ size = 28 }) { return <AutodevAvatar size={size}/>; }

// ── Icons ──────────────────────────────────────────────────────────────
function Icon({ name, size = 16, color = "currentColor", strokeWidth = 1.6 }) {
  const props = { width: size, height: size, viewBox: "0 0 24 24", fill: "none", stroke: color, strokeWidth, strokeLinecap: "round", strokeLinejoin: "round" };
  switch (name) {
    case "search":   return <svg {...props}><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>;
    case "filter":   return <svg {...props}><path d="M3 5h18M6 12h12M10 19h4"/></svg>;
    case "plus":     return <svg {...props}><path d="M12 5v14M5 12h14"/></svg>;
    case "send":     return <svg {...props}><path d="m4 12 16-8-6 18-3-7-7-3z"/></svg>;
    case "paperclip":return <svg {...props}><path d="M21 11.5 12 20.5a5.5 5.5 0 0 1-7.78-7.78l9.4-9.4a3.7 3.7 0 0 1 5.23 5.23l-9.4 9.4a1.85 1.85 0 0 1-2.62-2.62l8.34-8.34"/></svg>;
    case "image":    return <svg {...props}><rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-5-5L5 21"/></svg>;
    case "check":    return <svg {...props}><path d="M5 12.5 10 17 19 7"/></svg>;
    case "x":        return <svg {...props}><path d="M6 6l12 12M18 6 6 18"/></svg>;
    case "alert":    return <svg {...props}><path d="M10.3 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><path d="M12 9v4M12 17h.01"/></svg>;
    case "info":     return <svg {...props}><circle cx="12" cy="12" r="9"/><path d="M12 8v.01M11 12h1v4h1"/></svg>;
    case "play":     return <svg {...props}><path d="M6 4v16l14-8z"/></svg>;
    case "pause":    return <svg {...props}><rect x="6" y="4" width="4" height="16"/><rect x="14" y="4" width="4" height="16"/></svg>;
    case "refresh":  return <svg {...props}><path d="M3 12a9 9 0 0 1 15.5-6.36L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-15.5 6.36L3 16"/><path d="M3 21v-5h5"/></svg>;
    case "branch":   return <svg {...props}><circle cx="6" cy="6" r="2"/><circle cx="6" cy="18" r="2"/><circle cx="18" cy="6" r="2"/><path d="M6 8v8"/><path d="M18 8v2a4 4 0 0 1-4 4H8"/></svg>;
    case "git-mr":   return <svg {...props}><circle cx="6" cy="6" r="2"/><circle cx="6" cy="18" r="2"/><circle cx="18" cy="18" r="2"/><path d="M6 8v8"/><path d="M18 16V8a4 4 0 0 0-4-4h-3"/><path d="m13 1-3 3 3 3"/></svg>;
    case "external": return <svg {...props}><path d="M14 4h6v6"/><path d="M20 4 10 14"/><path d="M19 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h6"/></svg>;
    case "chevron-r":return <svg {...props}><path d="m9 6 6 6-6 6"/></svg>;
    case "chevron-l":return <svg {...props}><path d="m15 6-6 6 6 6"/></svg>;
    case "chevron-d":return <svg {...props}><path d="m6 9 6 6 6-6"/></svg>;
    case "more":     return <svg {...props}><circle cx="6" cy="12" r="1.5"/><circle cx="12" cy="12" r="1.5"/><circle cx="18" cy="12" r="1.5"/></svg>;
    case "home":     return <svg {...props}><path d="M3 11.5 12 4l9 7.5V20a1 1 0 0 1-1 1h-5v-7H9v7H4a1 1 0 0 1-1-1z"/></svg>;
    case "list":     return <svg {...props}><path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/></svg>;
    case "alert-tri":return <svg {...props}><path d="M10.3 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><path d="M12 9v4M12 17h.01"/></svg>;
    case "messages": return <svg {...props}><path d="M21 11.5a8.4 8.4 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.4 8.4 0 0 1-3.8-.9L3 21l1.9-5.7a8.4 8.4 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.4 8.4 0 0 1 3.8-.9h.5a8.5 8.5 0 0 1 8 8z"/></svg>;
    case "folder":   return <svg {...props}><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>;
    case "settings": return <svg {...props}><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>;
    case "arrow-r":  return <svg {...props}><path d="M5 12h14M13 5l7 7-7 7"/></svg>;
    case "arrow-l":  return <svg {...props}><path d="M19 12H5M12 5l-7 7 7 7"/></svg>;
    case "sparkles": return <svg {...props}><path d="M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M5.6 18.4l2.1-2.1M16.3 7.7l2.1-2.1"/></svg>;
    case "code":     return <svg {...props}><path d="m16 18 6-6-6-6M8 6l-6 6 6 6"/></svg>;
    case "clock":    return <svg {...props}><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>;
    case "user":     return <svg {...props}><circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/></svg>;
    case "users":    return <svg {...props}><circle cx="9" cy="8" r="3.5"/><path d="M2 21a7 7 0 0 1 14 0"/><circle cx="17" cy="8" r="3"/><path d="M22 21a6 6 0 0 0-5-5.91"/></svg>;
    case "thumb-up": return <svg {...props}><path d="M7 22V11M2 13v7a2 2 0 0 0 2 2h13.5a2 2 0 0 0 1.96-1.6l1.5-7a2 2 0 0 0-1.96-2.4H15V5a3 3 0 0 0-3-3l-3 7v13"/></svg>;
    case "thumb-dn": return <svg {...props}><path d="M17 2v11M22 11V4a2 2 0 0 0-2-2H6.5a2 2 0 0 0-1.96 1.6L3 10.6A2 2 0 0 0 5 13h4v4a3 3 0 0 0 3 3l3-7V2"/></svg>;
    case "copy":     return <svg {...props}><rect x="8" y="8" width="13" height="13" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/></svg>;
    case "download": return <svg {...props}><path d="M12 3v12M7 10l5 5 5-5M5 21h14"/></svg>;
    case "logout":   return <svg {...props}><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/></svg>;
    case "bell":     return <svg {...props}><path d="M18 8a6 6 0 1 0-12 0c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.7 21a2 2 0 0 1-3.4 0"/></svg>;
    case "moon":     return <svg {...props}><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg>;
    case "sun":      return <svg {...props}><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.4 1.4M17.6 17.6 19 19M5 19l1.4-1.4M17.6 6.4 19 5"/></svg>;
    case "menu":     return <svg {...props}><path d="M3 6h18M3 12h18M3 18h18"/></svg>;
    case "rocket":   return <svg {...props}><path d="M4.5 16.5c-1.5 1.26-2 5-2 5s3.74-.5 5-2c.71-.84.7-2.13-.09-2.91a2.18 2.18 0 0 0-2.91-.09z"/><path d="M12 15l-3-3a22 22 0 0 1 2-3.95 12.88 12.88 0 0 1 9-6c0 3-1 7-6 9a22 22 0 0 1-2 3z"/><path d="M9 12H4s.55-3.03 2-4c1.62-1.08 5 0 5 0"/></svg>;
    default: return null;
  }
}

// ── Step indicator ───────────────────────────────────────────────────────
const WORKFLOW_STEPS = [
  { id: "spec",    label: "Demande" },
  { id: "dev",     label: "Développement" },
  { id: "review",  label: "Vérifications" },
  { id: "fix",     label: "Corrections" },
  { id: "done",    label: "Livré" },
];

function workflowStepFor(status) {
  const s = statusOf(status);
  if (s.step <= 0) return 0;
  if (s.step <= 2) return 0;
  if (s.step <= 4) return 1;
  if (s.step <= 6) return 2;
  if (s.step <= 8) return 3;
  return 4;
}

function StepBar({ status, error, compact = false }) {
  const current = error ? -1 : workflowStepFor(status);
  return (
    <div style={{ display: "flex", alignItems: "center", gap: compact ? 4 : 8, flexWrap: "wrap" }}>
      {WORKFLOW_STEPS.map((step, i) => {
        const done = i < current;
        const isCurrent = i === current;
        const isErr = error && i === 1;
        return (
          <React.Fragment key={step.id}>
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <div style={{
                width: 22, height: 22, borderRadius: "50%",
                display: "inline-flex", alignItems: "center", justifyContent: "center",
                background: done ? "var(--ok-500)" : isErr ? "var(--err-500)" : isCurrent ? "var(--accent-solid)" : "var(--paper-2)",
                color: done || isCurrent || isErr ? "white" : "var(--text-muted)",
                fontSize: 11, fontWeight: 600,
                boxShadow: isCurrent ? "0 0 0 4px var(--accent-bg)" : "none",
                border: !done && !isCurrent && !isErr ? "1px solid var(--border)" : "none",
              }}>
                {done ? <Icon name="check" size={12} strokeWidth={2.4}/> : isErr ? "!" : i + 1}
              </div>
              {!compact && (
                <span style={{
                  fontSize: 12, fontWeight: 500,
                  color: isCurrent ? "var(--text-strong)" : isErr ? "var(--err-fg)" : done ? "var(--text)" : "var(--text-muted)",
                }}>{step.label}</span>
              )}
            </div>
            {i < WORKFLOW_STEPS.length - 1 && (
              <div style={{ flex: compact ? "1 1 8px" : "0 0 24px", height: 1, background: "var(--border)" }}/>
            )}
          </React.Fragment>
        );
      })}
    </div>
  );
}

// ── Theme context ───────────────────────────────────────────────────────
const ThemeContext = React.createContext({ theme: "light", setTheme: () => {} });

function ThemeToggle({ small }) {
  const { theme, setTheme } = React.useContext(ThemeContext);
  const dark = theme === "dark";
  if (small) {
    return (
      <button onClick={() => setTheme(dark ? "light" : "dark")} aria-label="Changer le thème" style={{
        width: 28, height: 28, borderRadius: 8, color: "var(--text-muted)",
        display: "inline-flex", alignItems: "center", justifyContent: "center",
      }}>
        <Icon name={dark ? "sun" : "moon"} size={15}/>
      </button>
    );
  }
  return (
    <div style={{
      display: "inline-flex", padding: 3, background: "var(--paper-2)",
      borderRadius: "var(--r-pill)", border: "1px solid var(--border)",
    }}>
      {[
        { id: "light", icon: "sun" },
        { id: "dark",  icon: "moon" },
      ].map(o => (
        <button key={o.id} onClick={() => setTheme(o.id)} style={{
          width: 28, height: 24, borderRadius: "var(--r-pill)",
          background: theme === o.id ? "var(--paper)" : "transparent",
          color: theme === o.id ? "var(--text)" : "var(--text-muted)",
          boxShadow: theme === o.id ? "var(--shadow-xs)" : "none",
          display: "inline-flex", alignItems: "center", justifyContent: "center",
        }}>
          <Icon name={o.icon} size={13}/>
        </button>
      ))}
    </div>
  );
}

// ── Sidebar (desktop) ───────────────────────────────────────────────────
function Sidebar({ active = "dashboard", counts = {}, onNavigate, onClose }) {
  const items = [
    { id: "dashboard", label: "Tableau de bord", icon: "home" },
    { id: "issues",    label: "Demandes",        icon: "list",     count: counts.issues },
    { id: "errors",    label: "À surveiller",    icon: "alert-tri",count: counts.errors,  tone: "err" },
    { id: "chat",      label: "Conversations",   icon: "messages", count: counts.chat },
    { id: "projects",  label: "Projets",         icon: "folder" },
  ];
  return (
    <aside style={{
      width: 240, background: "var(--paper)", borderRight: "1px solid var(--border)",
      padding: "18px 14px", display: "flex", flexDirection: "column", gap: 4,
      flex: "0 0 240px", height: "100%",
    }}>
      <div style={{ padding: "4px 8px 14px", display: "flex", alignItems: "center", justifyContent: "space-between" }}>
        <AutodevLogo/>
        <div style={{ display: "flex", gap: 2 }}>
          <ThemeToggle small/>
          <IconButton icon={<Icon name="bell" size={15}/>} size={28} label="Notifications"/>
          {onClose && <IconButton icon={<Icon name="x" size={15}/>} size={28} label="Fermer" onClick={onClose}/>}
        </div>
      </div>
      <div style={{ padding: "4px 6px 10px" }}>
        <div style={{
          display: "flex", alignItems: "center", gap: 8, padding: "7px 10px",
          background: "var(--paper-2)", borderRadius: "var(--r-md)",
          color: "var(--text-muted)", fontSize: 13,
        }}>
          <Icon name="search" size={14}/>
          <span>Rechercher…</span>
          <span style={{ marginLeft: "auto", fontSize: 11, color: "var(--text-subtle)", border: "1px solid var(--border)", padding: "1px 5px", borderRadius: 4 }}>⌘K</span>
        </div>
      </div>
      {items.map(i => {
        const isActive = active === i.id;
        return (
          <a key={i.id} href="#" onClick={e => { e.preventDefault(); onNavigate?.(i.id); }} style={{
            display: "flex", alignItems: "center", gap: 10, padding: "8px 10px",
            borderRadius: "var(--r-md)", fontSize: 13, fontWeight: 500,
            background: isActive ? "var(--accent-bg)" : "transparent",
            color: isActive ? "var(--accent-fg)" : "var(--text)",
          }}>
            <Icon name={i.icon} size={16} color={isActive ? "var(--accent-fg)" : (i.tone === "err" ? "var(--err-500)" : "var(--text-muted)")}/>
            <span style={{ flex: 1 }}>{i.label}</span>
            {i.count != null && (
              <span style={{
                fontSize: 11, fontWeight: 600, padding: "1px 7px", borderRadius: "var(--r-pill)",
                background: i.tone === "err" ? "var(--err-bg)" : (isActive ? "var(--accent-bg-strong)" : "var(--paper-2)"),
                color: i.tone === "err" ? "var(--err-fg)" : (isActive ? "var(--accent-fg)" : "var(--text-muted)"),
              }}>{i.count}</span>
            )}
          </a>
        );
      })}
      <div style={{ flex: 1 }}/>
      <div style={{
        padding: 12, background: "linear-gradient(140deg, var(--accent-bg), var(--paper-2))",
        border: "1px solid var(--accent-bg-strong)", borderRadius: "var(--r-md)",
        fontSize: 12, color: "var(--text)",
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: 6, fontWeight: 600, color: "var(--accent-fg)", marginBottom: 4 }}>
          <Icon name="sparkles" size={14}/> Nouveau ticket
        </div>
        <div style={{ color: "var(--text-muted)", lineHeight: 1.45 }}>Décrivez votre besoin à Autodev, il s'occupe du reste.</div>
        <div style={{ marginTop: 10 }}>
          <Button kind="primary" size="sm" full icon={<Icon name="plus" size={13}/>}>Démarrer</Button>
        </div>
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "10px 8px", marginTop: 8, borderTop: "1px solid var(--border)" }}>
        <Avatar name="Marine Petit" size={28}/>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 13, fontWeight: 500, color: "var(--text)" }}>Marine Petit</div>
          <div style={{ fontSize: 11, color: "var(--text-muted)" }}>Support client</div>
        </div>
      </div>
    </aside>
  );
}

// ── Topbar ──────────────────────────────────────────────────────────────
function Topbar({ title, subtitle, actions, breadcrumb, onMenuClick, compact }) {
  return (
    <div style={{
      padding: compact ? "14px 16px" : "20px 32px", borderBottom: "1px solid var(--border)",
      background: "var(--paper)", display: "flex", alignItems: "center", gap: compact ? 12 : 24,
      flex: "0 0 auto",
    }}>
      {onMenuClick && (
        <IconButton icon={<Icon name="menu" size={18}/>} size={36} label="Menu" onClick={onMenuClick}/>
      )}
      <div style={{ flex: 1, minWidth: 0 }}>
        {breadcrumb && (
          <div style={{ fontSize: 12, color: "var(--text-muted)", marginBottom: 4, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{breadcrumb}</div>
        )}
        <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
          <h1 style={{
            margin: 0, fontSize: compact ? 17 : 22, fontWeight: 600, letterSpacing: -0.3,
            color: "var(--text-strong)",
            overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
          }}>{title}</h1>
        </div>
        {subtitle && !compact && <div style={{ fontSize: 13, color: "var(--text-muted)", marginTop: 4 }}>{subtitle}</div>}
      </div>
      {actions && <div style={{ display: "flex", gap: 8, alignItems: "center" }}>{actions}</div>}
    </div>
  );
}

// ── Mobile bottom nav ───────────────────────────────────────────────────
function MobileBottomNav({ active, onNavigate, counts = {} }) {
  const items = [
    { id: "dashboard", label: "Accueil",   icon: "home" },
    { id: "issues",    label: "Demandes",  icon: "list", count: counts.issues },
    { id: "chat",      label: "Discuter",  icon: "messages", primary: true },
    { id: "errors",    label: "Surveil.",  icon: "alert-tri", count: counts.errors, tone: "err" },
    { id: "projects",  label: "Projets",   icon: "folder" },
  ];
  return (
    <nav style={{
      flex: "0 0 auto", display: "flex", justifyContent: "space-around",
      borderTop: "1px solid var(--border)", background: "var(--paper)",
      padding: "6px 4px 8px", gap: 2,
    }}>
      {items.map(i => {
        const isActive = active === i.id;
        if (i.primary) {
          return (
            <button key={i.id} onClick={() => onNavigate?.(i.id)} style={{
              flex: 1, display: "flex", flexDirection: "column", alignItems: "center", gap: 2,
              padding: "4px 6px", color: "var(--accent-fg)",
            }}>
              <span style={{
                width: 44, height: 44, borderRadius: 14, marginTop: -16,
                background: "var(--accent-solid)", color: "white",
                display: "inline-flex", alignItems: "center", justifyContent: "center",
                boxShadow: "0 8px 18px rgba(94,71,232,0.3)",
              }}>
                <Icon name={i.icon} size={18}/>
              </span>
              <span style={{ fontSize: 10, fontWeight: 500, color: "var(--text-muted)" }}>{i.label}</span>
            </button>
          );
        }
        return (
          <button key={i.id} onClick={() => onNavigate?.(i.id)} style={{
            flex: 1, display: "flex", flexDirection: "column", alignItems: "center", gap: 3,
            padding: "6px 4px", color: isActive ? "var(--accent-fg)" : "var(--text-muted)",
            position: "relative",
          }}>
            <span style={{ position: "relative" }}>
              <Icon name={i.icon} size={18}/>
              {i.count != null && i.count > 0 && (
                <span style={{
                  position: "absolute", top: -4, right: -7, minWidth: 14, height: 14,
                  borderRadius: 7, fontSize: 9, fontWeight: 700, padding: "0 4px",
                  background: i.tone === "err" ? "var(--err-500)" : "var(--accent-solid)",
                  color: "white", display: "inline-flex", alignItems: "center", justifyContent: "center",
                }}>{i.count}</span>
              )}
            </span>
            <span style={{ fontSize: 10, fontWeight: 500 }}>{i.label}</span>
          </button>
        );
      })}
    </nav>
  );
}

// ── Layout shell — picks layout based on viewport ───────────────────────
// Each shell reads its width from the nearest ancestor that has --shell-width
// set (typically a .shell-frame wrapper around the artboard).
const ShellWidthContext = React.createContext(null);
function ShellSizer({ width, children }) {
  return (
    <div className="shell-frame" style={{ width: "100%", height: "100%", "--shell-width": `${width}px` }}>
      <ShellWidthContext.Provider value={width}>{children}</ShellWidthContext.Provider>
    </div>
  );
}
function useShellWidth() {
  const ctx = React.useContext(ShellWidthContext);
  if (ctx != null) return ctx;
  return typeof window !== "undefined" ? window.innerWidth : 1280;
}

// Breakpoints
function shellMode(width) {
  if (width < 640) return "mobile";
  if (width < 1024) return "tablet";
  return "desktop";
}

Object.assign(window, {
  AutodevLogo, AutodevLogoMark, AutodevAvatar, ClaudeAvatar,
  STATUS, statusOf, StatusPill, TONE_VARS,
  Button, IconButton, Card, Avatar, Icon,
  StepBar, WORKFLOW_STEPS, workflowStepFor,
  Sidebar, Topbar, MobileBottomNav,
  ThemeContext, ThemeToggle,
  useShellWidth, shellMode, ShellSizer, ShellWidthContext,
});
