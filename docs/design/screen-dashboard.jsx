/* Autodev — Dashboard (responsive: mobile / tablet / desktop) */

function ScreenDashboard() {
  const w = useShellWidth();
  const mode = shellMode(w);
  const [navOpen, setNavOpen] = React.useState(false);

  const counts = SAMPLE_ISSUES.reduce((acc, i) => { acc[i.status] = (acc[i.status] || 0) + 1; return acc; }, {});
  const active = SAMPLE_ISSUES.filter(i => i.status !== "done" && i.status !== "error");
  const errors = SAMPLE_ISSUES.filter(i => i.status === "error");

  const isDesktop = mode === "desktop";
  const isMobile = mode === "mobile";

  return (
    <div style={{ display: "flex", height: "100%", background: "var(--bg)", flexDirection: isMobile ? "column" : "row" }}>
      {isDesktop && <Sidebar active="dashboard" counts={{ issues: 7, errors: errors.length, chat: 3 }}/>}
      {!isDesktop && navOpen && <MobileNavOverlay active="dashboard" counts={{ issues: 7, errors: errors.length, chat: 3 }} onClose={() => setNavOpen(false)}/>}

      <main style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", overflow: "hidden" }}>
        <Topbar
          compact={isMobile}
          onMenuClick={!isDesktop ? () => setNavOpen(true) : null}
          title={isMobile ? "Bonjour Marine 👋" : "Bonjour Marine 👋"}
          subtitle={isMobile ? null : "Voici ce qui se passe sur vos projets aujourd'hui."}
          actions={isMobile
            ? <IconButton icon={<Icon name="plus" size={18}/>} size={36} active label="Nouvelle demande"/>
            : <>
                <Button icon={<Icon name="refresh" size={14}/>} size="md">Actualiser</Button>
                <Button kind="primary" size="md" icon={<Icon name="plus" size={14}/>}>Nouvelle demande</Button>
              </>
          }
        />
        <div style={{ flex: 1, overflow: "auto", padding: isMobile ? 16 : isDesktop ? 32 : 22 }}>
          {/* KPIs — 4 cols desktop, 2 cols tablet/mobile */}
          <div style={{
            display: "grid",
            gridTemplateColumns: isDesktop ? "repeat(4, 1fr)" : "repeat(2, 1fr)",
            gap: isMobile ? 10 : 16, marginBottom: isMobile ? 16 : 24,
          }}>
            <KPI label="En cours" value={active.length} hint="Autodev travaille dessus" tone="working" icon="play" compact={isMobile}/>
            <KPI label="À surveiller" value={errors.length} hint="Échec, intervention requise" tone="err" icon="alert-tri" compact={isMobile}/>
            <KPI label="En attente d'une réponse" value={1} hint="Autodev a une question" tone="warn" icon="messages" compact={isMobile}/>
            <KPI label="Livrés cette semaine" value={14} hint="+ 3 par rapport à la semaine passée" tone="ok" icon="check" compact={isMobile}/>
          </div>

          <div style={{
            display: "grid",
            gridTemplateColumns: isDesktop ? "1.6fr 1fr" : "1fr",
            gap: isMobile ? 14 : 20,
          }}>
            <Card padding={0}>
              <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", padding: "16px 20px", borderBottom: "1px solid var(--border)" }}>
                <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                  <h3 style={{ margin: 0, fontSize: 14, fontWeight: 600, color: "var(--text-strong)" }}>Demandes en cours</h3>
                  <span style={{ fontSize: 12, color: "var(--text-muted)" }}>{active.length} actives</span>
                </div>
                <Button size="sm" kind="ghost" iconRight={<Icon name="chevron-r" size={13}/>}>Tout voir</Button>
              </div>
              <div>
                {active.slice(0, 5).map((it, idx) => (
                  <ActiveRow key={it.id} issue={it} last={idx === Math.min(active.length, 5) - 1} compact={isMobile}/>
                ))}
              </div>
            </Card>

            <div style={{ display: "flex", flexDirection: "column", gap: isMobile ? 14 : 20 }}>
              <Card>
                <h3 style={{ margin: "0 0 14px", fontSize: 14, fontWeight: 600, color: "var(--text-strong)" }}>Activité de la semaine</h3>
                <Sparkline/>
                <div style={{ display: "flex", justifyContent: "space-between", marginTop: 12, fontSize: 11, color: "var(--text-muted)" }}>
                  <span>Lun</span><span>Mar</span><span>Mer</span><span>Jeu</span><span>Ven</span><span>Sam</span><span>Dim</span>
                </div>
              </Card>

              <Card padding={0}>
                <div style={{ padding: "14px 18px 10px", borderBottom: "1px solid var(--border)" }}>
                  <h3 style={{ margin: 0, fontSize: 14, fontWeight: 600, color: "var(--text-strong)" }}>Vos projets</h3>
                </div>
                <div>
                  {SAMPLE_PROJECTS.map((p, i) => (
                    <div key={p.slug} style={{
                      display: "flex", alignItems: "center", gap: 12, padding: "11px 18px",
                      borderBottom: i === SAMPLE_PROJECTS.length - 1 ? "none" : "1px solid var(--divider)",
                    }}>
                      <span style={{ width: 8, height: 8, borderRadius: 2, background: p.color, flex: "0 0 auto" }}/>
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ fontSize: 13, fontWeight: 500, color: "var(--text)" }}>{p.label}</div>
                        <div style={{ fontSize: 11, color: "var(--text-muted)" }}>{p.total} demandes au total</div>
                      </div>
                      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                        {p.error > 0 && <span style={{ fontSize: 11, color: "var(--err-fg)", background: "var(--err-bg)", padding: "2px 7px", borderRadius: "var(--r-pill)" }}>{p.error} échec</span>}
                        <span style={{ fontSize: 11, fontWeight: 600, color: "var(--text)" }}>{p.active} actives</span>
                      </div>
                    </div>
                  ))}
                </div>
              </Card>
            </div>
          </div>

          {errors.length > 0 && (
            <div style={{ marginTop: isMobile ? 14 : 20 }}>
              <Card padding={0} style={{ borderColor: "var(--err-200)", background: "linear-gradient(180deg, var(--err-bg), var(--paper) 60%)" }}>
                <div style={{
                  display: "flex", alignItems: isMobile ? "flex-start" : "center", gap: 14,
                  padding: isMobile ? "14px 16px" : "16px 20px",
                  flexDirection: isMobile ? "column" : "row",
                }}>
                  <div style={{ display: "flex", alignItems: "center", gap: 14, flex: 1 }}>
                    <span style={{ width: 36, height: 36, borderRadius: 10, background: "var(--err-bg)", display: "inline-flex", alignItems: "center", justifyContent: "center", color: "var(--err-fg)", flex: "0 0 auto" }}>
                      <Icon name="alert-tri" size={18}/>
                    </span>
                    <div>
                      <div style={{ fontSize: 14, fontWeight: 600, color: "var(--text-strong)" }}>{errors.length} demande{errors.length > 1 ? "s" : ""} a échoué et attend une intervention</div>
                      <div style={{ fontSize: 12, color: "var(--text-muted)", marginTop: 2 }}>Vous pouvez les relancer en un clic ou consulter le détail.</div>
                    </div>
                  </div>
                  <Button kind="danger" size="md" full={isMobile}>Voir les échecs</Button>
                </div>
              </Card>
            </div>
          )}
        </div>
        {isMobile && <MobileBottomNav active="dashboard" counts={{ issues: 7, errors: errors.length, chat: 3 }}/>}
      </main>
    </div>
  );
}

function MobileNavOverlay({ active, counts, onClose }) {
  return (
    <div style={{
      position: "absolute", inset: 0, zIndex: 60, display: "flex",
    }}>
      <div onClick={onClose} style={{ position: "absolute", inset: 0, background: "rgba(11,13,18,0.5)" }}/>
      <div style={{ position: "relative", height: "100%" }}>
        <Sidebar active={active} counts={counts} onClose={onClose}/>
      </div>
    </div>
  );
}

function KPI({ label, value, hint, tone, icon, compact }) {
  const tones = {
    working: { bg: "var(--work-bg)",  fg: "var(--work-fg)" },
    ok:      { bg: "var(--ok-bg)",    fg: "var(--ok-fg)"   },
    warn:    { bg: "var(--warn-bg)",  fg: "var(--warn-fg)" },
    err:     { bg: "var(--err-bg)",   fg: "var(--err-fg)"  },
  };
  const t = tones[tone] || tones.working;
  return (
    <Card padding={compact ? 14 : 18} style={{ display: "flex", flexDirection: "column", gap: compact ? 6 : 10 }}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
        <span style={{ fontSize: 11, color: "var(--text-muted)", fontWeight: 500, lineHeight: 1.3 }}>{label}</span>
        <span style={{ width: 26, height: 26, borderRadius: 8, background: t.bg, color: t.fg, display: "inline-flex", alignItems: "center", justifyContent: "center" }}>
          <Icon name={icon} size={13}/>
        </span>
      </div>
      <div style={{ fontSize: compact ? 24 : 30, fontWeight: 600, letterSpacing: -1, color: "var(--text-strong)", lineHeight: 1, fontFeatureSettings: '"tnum"' }}>{value}</div>
      {!compact && <div style={{ fontSize: 11, color: "var(--text-muted)" }}>{hint}</div>}
    </Card>
  );
}

function ActiveRow({ issue, last, compact }) {
  return (
    <div style={{
      display: "grid",
      gridTemplateColumns: compact ? "auto 1fr auto" : "auto 1fr auto auto",
      alignItems: "center", gap: compact ? 10 : 14,
      padding: compact ? "12px 16px" : "12px 20px",
      borderBottom: last ? "none" : "1px solid var(--divider)",
    }}>
      <div style={{
        width: compact ? 26 : 32, height: compact ? 26 : 32, borderRadius: 8, background: "var(--paper-2)",
        display: "inline-flex", alignItems: "center", justifyContent: "center",
        fontSize: 10, fontWeight: 600, color: "var(--text-muted)", fontFamily: "var(--font-mono)",
      }}>#{issue.iid}</div>
      <div style={{ minWidth: 0 }}>
        <div style={{ fontSize: 13, fontWeight: 500, color: "var(--text-strong)", whiteSpace: "nowrap", textOverflow: "ellipsis", overflow: "hidden" }}>{issue.title}</div>
        <div style={{ fontSize: 11, color: "var(--text-muted)", marginTop: 2, whiteSpace: "nowrap", textOverflow: "ellipsis", overflow: "hidden" }}>{issue.projectLabel} · {issue.lastActivity}</div>
      </div>
      <StatusPill status={issue.status} size="sm"/>
      {!compact && <span style={{ fontSize: 11, color: "var(--text-muted)" }}>{issue.waitingSince}</span>}
    </div>
  );
}

function Sparkline() {
  const days = [3, 5, 4, 7, 6, 9, 8];
  const max = Math.max(...days);
  return (
    <div style={{ display: "flex", alignItems: "flex-end", gap: 8, height: 64 }}>
      {days.map((v, i) => (
        <div key={i} style={{
          flex: 1, height: `${(v / max) * 100}%`,
          background: i === days.length - 1 ? "var(--accent-solid)" : "var(--accent-bg-strong)",
          borderRadius: 4, minHeight: 6,
        }}/>
      ))}
    </div>
  );
}

window.ScreenDashboard = ScreenDashboard;
window.MobileNavOverlay = MobileNavOverlay;
