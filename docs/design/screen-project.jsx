/* Autodev — Project page (responsive) */

const PROJECT = {
  slug: "powerpanne/web",
  label: "Powerpanne · Web",
  description: "Application web pour les techniciens de terrain : gestion des interventions, devis et factures.",
  color: "#2A6FDB",
  repo: "gitlab.com/powerpanne/web",
  branch: "main",
  framework: "Rails 7 · Hotwire",
  active: 2, total: 31, errors: 1, doneThisMonth: 18, avgTime: "27 min",
};

const PROJECT_ISSUES = SAMPLE_ISSUES.filter(i => i.project === "powerpanne/web");

const TEAM = [
  { name: "Marine Petit", role: "Support client", level: "Membre" },
  { name: "Sophie Lambert", role: "Product Owner", level: "Mainteneur" },
  { name: "Karim Bensalem", role: "Lead Dev", level: "Mainteneur" },
  { name: "Lucas Moreau", role: "Dev backend", level: "Membre" },
];

function ScreenProject() {
  const w = useShellWidth();
  const mode = shellMode(w);
  const isMobile = mode === "mobile";
  const isDesktop = mode === "desktop";
  const [navOpen, setNavOpen] = React.useState(false);
  const [tab, setTab] = React.useState("overview");

  return (
    <div style={{ display: "flex", height: "100%", background: "var(--bg)", flexDirection: isMobile ? "column" : "row" }}>
      {isDesktop && <Sidebar active="projects" counts={{ issues: 7, errors: 1, chat: 3 }}/>}
      {!isDesktop && navOpen && <MobileNavOverlay active="projects" counts={{ issues: 7, errors: 1, chat: 3 }} onClose={() => setNavOpen(false)}/>}

      <main style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", overflow: "hidden" }}>
        <Topbar
          compact={isMobile}
          onMenuClick={!isDesktop ? () => setNavOpen(true) : null}
          breadcrumb={isMobile ? null : "Projets › Powerpanne · Web"}
          title={isMobile ? PROJECT.label : PROJECT.label}
          subtitle={isMobile ? null : PROJECT.description}
          actions={isMobile
            ? <IconButton icon={<Icon name="settings" size={16}/>} size={36} label="Réglages"/>
            : <>
                <Button size="md" icon={<Icon name="external" size={14}/>}>Voir sur GitLab</Button>
                <Button kind="primary" size="md" icon={<Icon name="plus" size={14}/>}>Nouvelle demande</Button>
              </>
          }
        />

        {/* Tabs */}
        <div style={{
          background: "var(--paper)", borderBottom: "1px solid var(--border)",
          padding: isMobile ? "0 8px" : "0 32px", display: "flex", gap: 4, overflowX: "auto",
        }}>
          {[
            { id: "overview", label: "Vue d'ensemble" },
            { id: "issues", label: "Demandes", count: PROJECT.total },
            { id: "config", label: "Configuration Autodev" },
            { id: "team", label: "Équipe" },
          ].map(t => {
            const active = tab === t.id;
            return (
              <button key={t.id} onClick={() => setTab(t.id)} style={{
                padding: "12px 14px", fontSize: 13, fontWeight: 500,
                color: active ? "var(--text-strong)" : "var(--text-muted)",
                borderBottom: active ? "2px solid var(--accent-solid)" : "2px solid transparent",
                whiteSpace: "nowrap", display: "inline-flex", alignItems: "center", gap: 6,
              }}>
                {t.label}
                {t.count != null && <span style={{ fontSize: 11, padding: "0 6px", borderRadius: "var(--r-pill)", background: "var(--paper-2)", color: "var(--text-muted)", border: "1px solid var(--border)" }}>{t.count}</span>}
              </button>
            );
          })}
        </div>

        <div style={{ flex: 1, overflow: "auto", padding: isMobile ? 14 : 28 }}>
          {tab === "overview" && <ProjectOverview isMobile={isMobile} isDesktop={isDesktop}/>}
          {tab === "issues" && <ProjectIssuesTable isMobile={isMobile}/>}
          {tab === "config" && <ProjectConfig isMobile={isMobile} isDesktop={isDesktop}/>}
          {tab === "team" && <ProjectTeam isMobile={isMobile}/>}
        </div>
        {isMobile && <MobileBottomNav active="projects" counts={{ issues: 7, errors: 1, chat: 3 }}/>}
      </main>
    </div>
  );
}

function ProjectOverview({ isMobile, isDesktop }) {
  return (
    <div style={{ display: "grid", gridTemplateColumns: isDesktop ? "1.5fr 1fr" : "1fr", gap: isMobile ? 14 : 22 }}>
      <div style={{ display: "flex", flexDirection: "column", gap: isMobile ? 14 : 22 }}>
        {/* Hero card */}
        <Card padding={0}>
          <div style={{
            background: `linear-gradient(135deg, ${PROJECT.color}22, var(--paper) 75%)`,
            padding: isMobile ? 18 : 24,
            borderTopLeftRadius: "var(--r-lg)", borderTopRightRadius: "var(--r-lg)",
            borderBottom: "1px solid var(--divider)",
          }}>
            <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 12 }}>
              <span style={{
                width: 40, height: 40, borderRadius: 10, background: PROJECT.color,
                color: "white", fontSize: 18, fontWeight: 700,
                display: "inline-flex", alignItems: "center", justifyContent: "center",
              }}>P</span>
              <div>
                <div style={{ fontSize: 16, fontWeight: 600, color: "var(--text-strong)" }}>{PROJECT.label}</div>
                <div style={{ fontSize: 12, color: "var(--text-muted)", fontFamily: "var(--font-mono)" }}>{PROJECT.repo}</div>
              </div>
            </div>
            <p style={{ margin: 0, fontSize: 13, color: "var(--text)", lineHeight: 1.55 }}>{PROJECT.description}</p>
          </div>
          <div style={{ padding: isMobile ? 14 : 18, display: "grid", gridTemplateColumns: isMobile ? "1fr 1fr" : "repeat(4, 1fr)", gap: isMobile ? 10 : 14 }}>
            <Stat label="Demandes en cours" value={PROJECT.active} tone="working"/>
            <Stat label="Échecs à traiter" value={PROJECT.errors} tone="err"/>
            <Stat label="Livrés ce mois" value={PROJECT.doneThisMonth} tone="ok"/>
            <Stat label="Temps moyen" value={PROJECT.avgTime}/>
          </div>
        </Card>

        {/* Recent activity */}
        <Card padding={0}>
          <div style={{ padding: "14px 18px", borderBottom: "1px solid var(--border)", display: "flex", alignItems: "center", justifyContent: "space-between" }}>
            <h3 style={{ margin: 0, fontSize: 14, fontWeight: 600, color: "var(--text-strong)" }}>Demandes récentes</h3>
            <Button size="sm" kind="ghost" iconRight={<Icon name="chevron-r" size={13}/>}>Tout voir</Button>
          </div>
          <div>
            {PROJECT_ISSUES.slice(0, 4).map((it, i) => (
              <div key={it.id} style={{
                display: "grid",
                gridTemplateColumns: isMobile ? "auto 1fr auto" : "auto 1fr auto auto",
                alignItems: "center", gap: 12,
                padding: "11px 18px",
                borderBottom: i === Math.min(3, PROJECT_ISSUES.length - 1) ? "none" : "1px solid var(--divider)",
              }}>
                <span style={{ fontFamily: "var(--font-mono)", fontSize: 11, color: "var(--text-muted)" }}>#{it.iid}</span>
                <div style={{ minWidth: 0 }}>
                  <div style={{ fontSize: 13, color: "var(--text-strong)", whiteSpace: "nowrap", textOverflow: "ellipsis", overflow: "hidden" }}>{it.title}</div>
                  {!isMobile && <div style={{ fontSize: 11, color: "var(--text-muted)", marginTop: 2 }}>{it.lastActivity}</div>}
                </div>
                <StatusPill status={it.status} size="sm"/>
                {!isMobile && <span style={{ fontSize: 11, color: "var(--text-muted)" }}>{it.waitingSince}</span>}
              </div>
            ))}
          </div>
        </Card>
      </div>

      {/* Right column */}
      <div style={{ display: "flex", flexDirection: "column", gap: isMobile ? 14 : 22 }}>
        <Card>
          <h3 style={{ margin: "0 0 14px", fontSize: 13, fontWeight: 600, color: "var(--text-strong)", textTransform: "uppercase", letterSpacing: 0.6 }}>Détails techniques</h3>
          <div style={{ display: "grid", gap: 12 }}>
            <KV label="Branche par défaut" value={<code style={{ fontFamily: "var(--font-mono)", fontSize: 12, color: "var(--text)" }}>{PROJECT.branch}</code>}/>
            <KV label="Framework" value={PROJECT.framework}/>
            <KV label="Statut Autodev" value={<span style={{ fontSize: 12, color: "var(--ok-fg)", display: "inline-flex", alignItems: "center", gap: 6 }}><span style={{ width: 6, height: 6, borderRadius: "50%", background: "var(--ok-500)" }}/>Actif</span>}/>
            <KV label="Webhook GitLab" value={<span style={{ fontSize: 12, color: "var(--ok-fg)" }}>Connecté</span>}/>
            <KV label="Dernière synchro" value={<span style={{ fontSize: 12, color: "var(--text-muted)" }}>il y a 12 s</span>}/>
          </div>
        </Card>
        <Card>
          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 14 }}>
            <h3 style={{ margin: 0, fontSize: 13, fontWeight: 600, color: "var(--text-strong)", textTransform: "uppercase", letterSpacing: 0.6 }}>Équipe</h3>
            <Button size="sm" kind="ghost">Voir tout</Button>
          </div>
          <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
            {TEAM.slice(0, 4).map(m => (
              <div key={m.name} style={{ display: "flex", alignItems: "center", gap: 10 }}>
                <Avatar name={m.name} size={28}/>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 13, fontWeight: 500, color: "var(--text)" }}>{m.name}</div>
                  <div style={{ fontSize: 11, color: "var(--text-muted)" }}>{m.role}</div>
                </div>
                <span style={{ fontSize: 10, padding: "1px 7px", borderRadius: "var(--r-pill)", background: m.level === "Mainteneur" ? "var(--accent-bg)" : "var(--paper-2)", color: m.level === "Mainteneur" ? "var(--accent-fg)" : "var(--text-muted)" }}>{m.level}</span>
              </div>
            ))}
          </div>
        </Card>
      </div>
    </div>
  );
}

function Stat({ label, value, tone }) {
  const tones = {
    working: "var(--work-fg)",
    err:     "var(--err-fg)",
    ok:      "var(--ok-fg)",
  };
  return (
    <div>
      <div style={{ fontSize: 11, color: "var(--text-muted)", marginBottom: 4 }}>{label}</div>
      <div style={{ fontSize: 22, fontWeight: 600, letterSpacing: -0.5, color: tones[tone] || "var(--text-strong)", lineHeight: 1, fontFeatureSettings: '"tnum"' }}>{value}</div>
    </div>
  );
}

function KV({ label, value }) {
  return (
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", gap: 10 }}>
      <span style={{ fontSize: 12, color: "var(--text-muted)" }}>{label}</span>
      <span style={{ fontSize: 13, color: "var(--text)" }}>{value}</span>
    </div>
  );
}

function ProjectIssuesTable({ isMobile }) {
  return (
    <div style={{ background: "var(--paper)", border: "1px solid var(--border)", borderRadius: "var(--r-lg)", overflow: "hidden" }}>
      {PROJECT_ISSUES.map((it, i) => (
        <div key={it.id} style={{
          padding: isMobile ? 14 : "13px 18px",
          borderBottom: i === PROJECT_ISSUES.length - 1 ? "none" : "1px solid var(--divider)",
          display: "flex", alignItems: isMobile ? "flex-start" : "center", gap: 12, flexWrap: "wrap",
        }}>
          <span style={{ fontFamily: "var(--font-mono)", fontSize: 11, color: "var(--text-muted)", flex: "0 0 auto" }}>#{it.iid}</span>
          <div style={{ flex: 1, minWidth: 200 }}>
            <div style={{ fontSize: 13, fontWeight: 500, color: "var(--text-strong)" }}>{it.title}</div>
            <div style={{ fontSize: 11, color: "var(--text-muted)", marginTop: 2 }}>{it.requester} · {it.waitingSince}</div>
          </div>
          <StatusPill status={it.status} size="sm"/>
        </div>
      ))}
    </div>
  );
}

function ProjectConfig({ isMobile, isDesktop }) {
  // Show a YAML-like config viewer + a few toggles
  const yaml = `# .autodev.yml — config du projet
project:
  name: powerpanne-web
  language: ruby
  framework: rails

triggers:
  labels: [autodev, "Autodev::go"]
  on_assign: true
  auto_fix_pipeline: true

review:
  require_human_approval: true
  fix_max_attempts: 3

testing:
  command: bundle exec rspec
  must_pass_before_mr: true

merge:
  strategy: merge_request    # never directly to main
  draft_first: true`;

  return (
    <div style={{ display: "grid", gridTemplateColumns: isDesktop ? "1.4fr 1fr" : "1fr", gap: isMobile ? 14 : 22 }}>
      <Card padding={0}>
        <div style={{ padding: "12px 18px", borderBottom: "1px solid var(--border)", display: "flex", alignItems: "center", justifyContent: "space-between" }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <Icon name="settings" size={14} color="var(--text-muted)"/>
            <span style={{ fontSize: 12, fontWeight: 600, color: "var(--text-strong)", fontFamily: "var(--font-mono)" }}>.autodev.yml</span>
          </div>
          <Button size="sm" icon={<Icon name="copy" size={12}/>}>Copier</Button>
        </div>
        <pre style={{
          margin: 0, padding: 18, background: "var(--code-bg)",
          color: "var(--code-fg)", fontFamily: "var(--font-mono)",
          fontSize: 12, lineHeight: 1.7, overflow: "auto",
          borderBottomLeftRadius: "var(--r-lg)", borderBottomRightRadius: "var(--r-lg)",
        }}>{yaml}</pre>
      </Card>

      <div style={{ display: "flex", flexDirection: "column", gap: isMobile ? 14 : 22 }}>
        <Card>
          <h3 style={{ margin: "0 0 14px", fontSize: 13, fontWeight: 600, color: "var(--text-strong)", textTransform: "uppercase", letterSpacing: 0.6 }}>Comportement</h3>
          <ToggleRow label="Démarrer sur étiquette « autodev »" hint="Autodev se déclenche quand on pose ce label." on={true}/>
          <ToggleRow label="Démarrer à l'assignation" hint="Quand l'issue est assignée à @autodev." on={true}/>
          <ToggleRow label="Corriger les tests automatiquement" hint="Réessaye jusqu'à 3 fois avant d'alerter." on={true}/>
          <ToggleRow label="Requérir une revue humaine" hint="Le MR ne peut pas être fusionné sans validation." on={true} last/>
        </Card>
        <Card>
          <h3 style={{ margin: "0 0 14px", fontSize: 13, fontWeight: 600, color: "var(--text-strong)", textTransform: "uppercase", letterSpacing: 0.6 }}>Sécurité</h3>
          <ToggleRow label="Interdire les modifications de schema.rb" hint="Autodev demandera systématiquement une revue." on={true}/>
          <ToggleRow label="Bloquer le push direct sur main" hint="Toujours passer par une MR." on={true} last/>
        </Card>
      </div>
    </div>
  );
}

function ToggleRow({ label, hint, on, last }) {
  const [v, setV] = React.useState(on);
  return (
    <div style={{
      display: "flex", alignItems: "center", gap: 12, padding: "12px 0",
      borderBottom: last ? "none" : "1px solid var(--divider)",
    }}>
      <div style={{ flex: 1 }}>
        <div style={{ fontSize: 13, color: "var(--text-strong)", fontWeight: 500 }}>{label}</div>
        <div style={{ fontSize: 11, color: "var(--text-muted)", marginTop: 2 }}>{hint}</div>
      </div>
      <button onClick={() => setV(!v)} aria-pressed={v} style={{
        width: 36, height: 22, borderRadius: 12, padding: 2,
        background: v ? "var(--accent-solid)" : "var(--border-strong)",
        display: "inline-flex", alignItems: "center", flex: "0 0 auto",
        transition: "background 0.15s",
      }}>
        <span style={{
          width: 18, height: 18, borderRadius: "50%", background: "white",
          transform: v ? "translateX(14px)" : "translateX(0)",
          transition: "transform 0.15s",
          boxShadow: "0 1px 2px rgba(0,0,0,0.2)",
        }}/>
      </button>
    </div>
  );
}

function ProjectTeam({ isMobile }) {
  return (
    <Card padding={0}>
      {TEAM.map((m, i) => (
        <div key={m.name} style={{
          display: "flex", alignItems: "center", gap: 12,
          padding: "14px 18px",
          borderBottom: i === TEAM.length - 1 ? "none" : "1px solid var(--divider)",
        }}>
          <Avatar name={m.name} size={36}/>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 14, fontWeight: 500, color: "var(--text-strong)" }}>{m.name}</div>
            <div style={{ fontSize: 12, color: "var(--text-muted)" }}>{m.role}</div>
          </div>
          <span style={{ fontSize: 11, padding: "3px 9px", borderRadius: "var(--r-pill)", background: m.level === "Mainteneur" ? "var(--accent-bg)" : "var(--paper-2)", color: m.level === "Mainteneur" ? "var(--accent-fg)" : "var(--text-muted)" }}>{m.level}</span>
          {!isMobile && <Button size="sm" kind="ghost">Réglages</Button>}
        </div>
      ))}
    </Card>
  );
}

window.ScreenProject = ScreenProject;
