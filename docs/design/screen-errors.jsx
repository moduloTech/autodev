/* Autodev — Errors / "À surveiller" (responsive) */

const ERRORS = [
  {
    id: 1, iid: 407, project: "Modulotech · CRM",
    title: "La recherche par email plante quand l'adresse contient un +",
    cause: "Impossible de cloner le dépôt",
    explain: "Autodev n'a pas pu récupérer le code source du projet. Cela arrive généralement quand le serveur GitLab est indisponible, ou si le jeton d'accès a expiré.",
    when: "il y a 1 h 04",
    suggested: "Réessayer maintenant",
    technical: "git clone git@gitlab.com:modulotech/crm.git failed: timeout after 60s",
    requester: "Karim Bensalem",
  },
  {
    id: 2, iid: 398, project: "Powerpanne · Web",
    title: "Régler le problème d'affichage du logo sur Safari",
    cause: "Tests automatiques en échec après 3 tentatives",
    explain: "Autodev a tenté de corriger le code 3 fois mais les tests automatiques échouent toujours. Un développeur devrait jeter un œil — il s'agit peut-être d'un test cassé, pas du code lui-même.",
    when: "il y a 3 h",
    suggested: "Transmettre à un développeur",
    technical: "tests/header.spec.ts > logo display > expected 'visible' but got 'hidden'. (run #3)",
    requester: "Sophie Lambert",
  },
  {
    id: 3, iid: 391, project: "Powerpanne · API",
    title: "Renommer le champ 'address' en 'street_address'",
    cause: "Question restée sans réponse",
    explain: "Autodev a posé une question il y a 2 jours pour confirmer la portée du changement (toutes les tables, ou juste users ?). Sans réponse, la demande est mise en pause.",
    when: "il y a 2 j",
    suggested: "Répondre à la question",
    technical: "Question posted on issue #391, no human response since 2025-01-20 14:32",
    requester: "Lucas Moreau",
  },
];

function ScreenErrors() {
  const w = useShellWidth();
  const mode = shellMode(w);
  const isMobile = mode === "mobile";
  const isDesktop = mode === "desktop";
  const [navOpen, setNavOpen] = React.useState(false);
  const [showTech, setShowTech] = React.useState({});

  return (
    <div style={{ display: "flex", height: "100%", background: "var(--bg)", flexDirection: isMobile ? "column" : "row" }}>
      {isDesktop && <Sidebar active="errors" counts={{ issues: 7, errors: ERRORS.length, chat: 3 }}/>}
      {!isDesktop && navOpen && <MobileNavOverlay active="errors" counts={{ issues: 7, errors: ERRORS.length, chat: 3 }} onClose={() => setNavOpen(false)}/>}

      <main style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", overflow: "hidden" }}>
        <Topbar
          compact={isMobile}
          onMenuClick={!isDesktop ? () => setNavOpen(true) : null}
          title="À surveiller"
          subtitle={isMobile ? null : "Demandes qui ont échoué ou attendent une intervention humaine."}
        />
        <div style={{ flex: 1, overflow: "auto", padding: isMobile ? 14 : 28 }}>
          <div style={{
            display: "flex", alignItems: isMobile ? "flex-start" : "center", gap: 14,
            padding: isMobile ? 14 : "14px 18px", marginBottom: isMobile ? 14 : 22,
            background: "var(--err-bg)", border: "1px solid var(--err-200)",
            borderRadius: "var(--r-md)", color: "var(--err-fg)",
            flexDirection: isMobile ? "column" : "row",
          }}>
            <Icon name="alert-tri" size={20}/>
            <div style={{ flex: 1, fontSize: 13, lineHeight: 1.5 }}>
              <strong>{ERRORS.length} demandes ont besoin de vous.</strong> Autodev s'arrête et vous appelle quand il rencontre un blocage qu'il ne peut pas résoudre seul.
            </div>
            <Button size="md" kind="ghost" full={isMobile}>Tout marquer comme lu</Button>
          </div>

          <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
            {ERRORS.map(err => (
              <Card key={err.id} padding={0}>
                <div style={{ padding: isMobile ? 16 : "18px 22px" }}>
                  <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 10, flexWrap: "wrap" }}>
                    <span style={{ fontSize: 11, fontFamily: "var(--font-mono)", color: "var(--text-muted)" }}>#{err.iid}</span>
                    <span style={{ fontSize: 11, color: "var(--text-muted)" }}>{err.project}</span>
                    <StatusPill status="error" size="sm"/>
                    <span style={{ marginLeft: "auto", fontSize: 11, color: "var(--text-muted)" }}>{err.when}</span>
                  </div>
                  <h3 style={{ margin: "0 0 14px", fontSize: isMobile ? 15 : 17, fontWeight: 600, color: "var(--text-strong)", lineHeight: 1.35 }}>{err.title}</h3>

                  <div style={{ display: "flex", alignItems: "flex-start", gap: 12, padding: 14, background: "var(--err-bg)", borderRadius: "var(--r-md)", marginBottom: 14 }}>
                    <span style={{ width: 28, height: 28, borderRadius: 8, background: "var(--paper)", display: "inline-flex", alignItems: "center", justifyContent: "center", color: "var(--err-fg)", flex: "0 0 auto" }}>
                      <Icon name="alert-tri" size={14}/>
                    </span>
                    <div>
                      <div style={{ fontSize: 13, fontWeight: 600, color: "var(--err-fg)", marginBottom: 4 }}>{err.cause}</div>
                      <div style={{ fontSize: 13, color: "var(--text)", lineHeight: 1.55 }}>{err.explain}</div>
                    </div>
                  </div>

                  <button onClick={() => setShowTech(s => ({ ...s, [err.id]: !s[err.id] }))} style={{
                    fontSize: 12, color: "var(--text-muted)", display: "inline-flex", alignItems: "center", gap: 6, marginBottom: showTech[err.id] ? 10 : 0,
                  }}>
                    <Icon name="chevron-d" size={12} strokeWidth={2}/>
                    {showTech[err.id] ? "Masquer" : "Afficher"} les détails techniques
                  </button>
                  {showTech[err.id] && (
                    <pre style={{
                      fontFamily: "var(--font-mono)", fontSize: 11, lineHeight: 1.6, color: "var(--code-fg)",
                      background: "var(--code-bg)", padding: 14, borderRadius: "var(--r-sm)", margin: 0,
                      overflow: "auto", whiteSpace: "pre-wrap",
                    }}>{err.technical}</pre>
                  )}
                </div>
                <div style={{
                  padding: "12px 18px", borderTop: "1px solid var(--divider)",
                  display: "flex", alignItems: "center", gap: 10,
                  background: "var(--paper-2)",
                  borderRadius: "0 0 var(--r-lg) var(--r-lg)",
                  flexWrap: "wrap",
                }}>
                  <Avatar name={err.requester} size={20}/>
                  <span style={{ fontSize: 12, color: "var(--text-muted)" }}>Demandé par {err.requester}</span>
                  <div style={{ marginLeft: "auto", display: "flex", gap: 8, flexWrap: "wrap" }}>
                    <Button size="sm">Voir le détail</Button>
                    <Button size="sm" kind="primary" icon={<Icon name="refresh" size={13}/>}>{err.suggested}</Button>
                  </div>
                </div>
              </Card>
            ))}
          </div>
        </div>
        {isMobile && <MobileBottomNav active="errors" counts={{ issues: 7, errors: ERRORS.length, chat: 3 }}/>}
      </main>
    </div>
  );
}

window.ScreenErrors = ScreenErrors;
