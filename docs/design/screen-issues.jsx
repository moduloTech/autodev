/* Autodev — Issues list (responsive) */

function ScreenIssues() {
  const w = useShellWidth();
  const mode = shellMode(w);
  const isMobile = mode === "mobile";
  const isDesktop = mode === "desktop";
  const [navOpen, setNavOpen] = React.useState(false);
  const [tab, setTab] = React.useState("active");
  const errors = SAMPLE_ISSUES.filter(i => i.status === "error").length;

  const tabs = [
    { id: "active", label: "En cours", count: SAMPLE_ISSUES.filter(i => i.status !== "done" && i.status !== "error").length },
    { id: "errors", label: "Échecs", count: errors, tone: "err" },
    { id: "waiting", label: "Question en attente", count: 1, tone: "warn" },
    { id: "done", label: "Livrés", count: SAMPLE_ISSUES.filter(i => i.status === "done").length },
    { id: "all", label: "Tous", count: SAMPLE_ISSUES.length },
  ];

  let visible = SAMPLE_ISSUES;
  if (tab === "active") visible = SAMPLE_ISSUES.filter(i => i.status !== "done" && i.status !== "error");
  if (tab === "errors") visible = SAMPLE_ISSUES.filter(i => i.status === "error");
  if (tab === "done") visible = SAMPLE_ISSUES.filter(i => i.status === "done");
  if (tab === "waiting") visible = SAMPLE_ISSUES.filter(i => i.status === "needs_clarification");

  return (
    <div style={{ display: "flex", height: "100%", background: "var(--bg)", flexDirection: isMobile ? "column" : "row" }}>
      {isDesktop && <Sidebar active="issues" counts={{ issues: 7, errors, chat: 3 }}/>}
      {!isDesktop && navOpen && <MobileNavOverlay active="issues" counts={{ issues: 7, errors, chat: 3 }} onClose={() => setNavOpen(false)}/>}

      <main style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", overflow: "hidden" }}>
        <Topbar
          compact={isMobile}
          onMenuClick={!isDesktop ? () => setNavOpen(true) : null}
          title="Demandes"
          subtitle={isMobile ? null : "Toutes les tâches confiées à Autodev sur vos projets."}
          actions={isMobile
            ? <IconButton icon={<Icon name="plus" size={18}/>} size={36} active label="Nouvelle"/>
            : <Button kind="primary" size="md" icon={<Icon name="plus" size={14}/>}>Nouvelle demande</Button>
          }
        />

        {/* Filter bar */}
        <div style={{
          padding: isMobile ? "10px 14px" : "12px 32px",
          background: "var(--paper)", borderBottom: "1px solid var(--border)",
          display: "flex", alignItems: "center", gap: 12, flexWrap: "wrap",
        }}>
          <div style={{ display: "flex", gap: 4, overflowX: "auto", flex: 1, minWidth: 0 }}>
            {tabs.map(t => {
              const active = tab === t.id;
              return (
                <button key={t.id} onClick={() => setTab(t.id)} style={{
                  display: "inline-flex", alignItems: "center", gap: 6,
                  padding: "6px 12px", borderRadius: "var(--r-pill)",
                  fontSize: 13, fontWeight: 500, whiteSpace: "nowrap",
                  background: active ? "var(--paper-2)" : "transparent",
                  color: active ? "var(--text-strong)" : "var(--text-muted)",
                  border: active ? "1px solid var(--border)" : "1px solid transparent",
                }}>
                  {t.label}
                  <span style={{
                    fontSize: 11, padding: "0px 6px", borderRadius: "var(--r-pill)",
                    background: t.tone === "err" ? "var(--err-bg)" : t.tone === "warn" ? "var(--warn-bg)" : (active ? "var(--paper)" : "var(--paper-2)"),
                    color: t.tone === "err" ? "var(--err-fg)" : t.tone === "warn" ? "var(--warn-fg)" : "var(--text-muted)",
                    border: t.tone === "err" || t.tone === "warn" ? "none" : "1px solid var(--border)",
                  }}>{t.count}</span>
                </button>
              );
            })}
          </div>
          {!isMobile && (
            <div style={{ display: "flex", gap: 8 }}>
              <div style={{ display: "flex", alignItems: "center", gap: 6, padding: "5px 10px 5px 8px", border: "1px solid var(--border)", borderRadius: "var(--r-md)", background: "var(--paper)" }}>
                <Icon name="search" size={14} color="var(--text-muted)"/>
                <input placeholder="Rechercher…" style={{ border: "none", outline: "none", fontSize: 13, width: 180, background: "transparent" }}/>
              </div>
              <Button size="md" icon={<Icon name="filter" size={14}/>}>Filtrer</Button>
            </div>
          )}
        </div>

        {/* Table or cards */}
        <div style={{ flex: 1, overflow: "auto", padding: isMobile ? 12 : 24 }}>
          {isMobile ? (
            <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
              {visible.map(it => <IssueCard key={it.id} issue={it}/>)}
            </div>
          ) : (
            <div style={{ background: "var(--paper)", border: "1px solid var(--border)", borderRadius: "var(--r-lg)", overflow: "hidden", boxShadow: "var(--shadow-xs)" }}>
              <div style={{
                display: "grid", gridTemplateColumns: "60px 1fr 220px 180px 140px 32px",
                padding: "11px 18px", background: "var(--paper-2)", borderBottom: "1px solid var(--border)",
                fontSize: 11, color: "var(--text-muted)", fontWeight: 600, textTransform: "uppercase", letterSpacing: 0.5,
              }}>
                <span>#</span><span>Titre</span><span>Statut</span><span>Demandeur</span><span>Activité</span><span/>
              </div>
              {visible.map((it, idx) => (
                <div key={it.id} style={{
                  display: "grid", gridTemplateColumns: "60px 1fr 220px 180px 140px 32px",
                  padding: "13px 18px", alignItems: "center",
                  borderBottom: idx === visible.length - 1 ? "none" : "1px solid var(--divider)",
                  fontSize: 13,
                }}>
                  <span style={{ fontFamily: "var(--font-mono)", color: "var(--text-muted)", fontSize: 12 }}>#{it.iid}</span>
                  <div style={{ minWidth: 0 }}>
                    <div style={{ color: "var(--text-strong)", fontWeight: 500, whiteSpace: "nowrap", textOverflow: "ellipsis", overflow: "hidden" }}>{it.title}</div>
                    <div style={{ color: "var(--text-muted)", fontSize: 11, marginTop: 2 }}>{it.projectLabel}</div>
                  </div>
                  <StatusPill status={it.status} size="sm"/>
                  <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                    <Avatar name={it.requester} size={22}/>
                    <span style={{ fontSize: 12 }}>{it.requester}</span>
                  </div>
                  <span style={{ fontSize: 12, color: "var(--text-muted)" }}>{it.waitingSince}</span>
                  <button style={{ color: "var(--text-muted)", padding: 4 }}><Icon name="more" size={16}/></button>
                </div>
              ))}
            </div>
          )}
        </div>
        {isMobile && <MobileBottomNav active="issues" counts={{ issues: 7, errors, chat: 3 }}/>}
      </main>
    </div>
  );
}

function IssueCard({ issue }) {
  return (
    <div style={{
      background: "var(--paper)", border: "1px solid var(--border)",
      borderRadius: "var(--r-lg)", padding: 14, boxShadow: "var(--shadow-xs)",
      display: "flex", flexDirection: "column", gap: 10,
    }}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10 }}>
        <span style={{ fontFamily: "var(--font-mono)", fontSize: 11, color: "var(--text-muted)" }}>#{issue.iid} · {issue.projectLabel}</span>
        <StatusPill status={issue.status} size="sm"/>
      </div>
      <div style={{ fontSize: 14, fontWeight: 500, color: "var(--text-strong)", lineHeight: 1.35 }}>{issue.title}</div>
      <div style={{ display: "flex", alignItems: "center", gap: 8, color: "var(--text-muted)", fontSize: 12 }}>
        <Avatar name={issue.requester} size={20}/>
        <span>{issue.requester}</span>
        <span style={{ marginLeft: "auto" }}>{issue.waitingSince}</span>
      </div>
    </div>
  );
}

window.ScreenIssues = ScreenIssues;
