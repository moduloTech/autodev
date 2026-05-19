/* Autodev — Issue detail (chat with Claude/Autodev while it works) — responsive */

const TIMELINE = [
  { at: "10:42", kind: "system", title: "Demande reçue", detail: "Marine Petit a confié l'issue #412 à Autodev." },
  { at: "10:42", kind: "system", title: "Préparation",   detail: "Récupération du code source — Powerpanne · Web." },
  { at: "10:43", kind: "claude", title: "Plan proposé", detail: "1. Reproduire l'erreur 500 sur la validation. 2. Corriger la conversion du montant. 3. Ajouter un test pour éviter la régression." },
  { at: "10:43", kind: "claude", title: "Modification de fichier", detail: "app/controllers/invoices_controller.rb · +12 -4" },
  { at: "10:44", kind: "claude", title: "Modification de fichier", detail: "app/models/invoice.rb · +3 -1" },
  { at: "10:44", kind: "claude", title: "Test ajouté",  detail: "test/controllers/invoices_controller_test.rb · +24" },
  { at: "10:45", kind: "claude", title: "Tests locaux", detail: "Suite complète passée en 12,4 s." },
];

const CONVERSATION = [
  { who: "user", at: "10:43", text: "Salut, est-ce que tu peux aussi vérifier ce qui se passe quand le montant est négatif ? On a déjà eu un bug là-dessus." },
  { who: "claude", at: "10:43", text: "Bonne question. Je vais ajouter un test explicite pour les montants négatifs. Est-ce qu'on les rejette avec un message d'erreur clair, ou est-ce qu'on les autorise (par exemple pour un avoir) ?" },
  { who: "user", at: "10:44", text: "On les rejette avec un message « Le montant doit être positif »." },
  { who: "claude", at: "10:44", text: "Compris, j'ajoute la validation et le message. Je continue le travail." },
];

function ScreenIssueDetail() {
  const w = useShellWidth();
  const mode = shellMode(w);
  const isMobile = mode === "mobile";
  const isDesktop = mode === "desktop";
  const [navOpen, setNavOpen] = React.useState(false);
  const [tab, setTab] = React.useState(isMobile ? "activity" : "both");
  const [draft, setDraft] = React.useState("");

  const showTimeline = !isMobile || tab === "activity";
  const showChat = !isMobile || tab === "chat";

  return (
    <div style={{ display: "flex", height: "100%", background: "var(--bg)", flexDirection: isMobile ? "column" : "row" }}>
      {isDesktop && <Sidebar active="issues" counts={{ issues: 7, errors: 1, chat: 3 }}/>}
      {!isDesktop && navOpen && <MobileNavOverlay active="issues" counts={{ issues: 7, errors: 1, chat: 3 }} onClose={() => setNavOpen(false)}/>}

      <main style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", overflow: "hidden" }}>
        <Topbar
          compact={isMobile}
          onMenuClick={!isDesktop ? () => setNavOpen(true) : null}
          breadcrumb={isMobile ? null : "Demandes › Powerpanne · Web › #412"}
          title={isMobile ? "#412 · Bouton Valider" : "Le bouton « Valider » de la page facture renvoie une erreur 500"}
          subtitle={isMobile ? null : null}
          actions={isMobile
            ? <IconButton icon={<Icon name="external" size={16}/>} size={36} label="GitLab"/>
            : <>
                <Button size="md" icon={<Icon name="external" size={14}/>}>Voir sur GitLab</Button>
                <Button size="md" kind="ghost" icon={<Icon name="more" size={14}/>}/>
              </>
          }
        />

        {/* Step bar */}
        <div style={{
          padding: isMobile ? "12px 14px" : "14px 32px", background: "var(--paper)",
          borderBottom: "1px solid var(--border)", display: "flex", alignItems: "center", gap: 16,
          flexWrap: "wrap",
        }}>
          <div style={{ flex: 1, minWidth: 220 }}>
            <StepBar status="implementing" compact={isMobile}/>
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: 10, fontSize: 12, color: "var(--text-muted)" }}>
            <Icon name="clock" size={14}/>
            <span>En cours depuis 4 min</span>
          </div>
        </div>

        {/* Mobile tabs to toggle activity / chat */}
        {isMobile && (
          <div style={{ display: "flex", padding: "8px 12px 0", gap: 6, background: "var(--paper)", borderBottom: "1px solid var(--border)" }}>
            {[{ id: "activity", label: "Activité" }, { id: "chat", label: "Discussion", badge: 4 }].map(t => {
              const active = tab === t.id;
              return (
                <button key={t.id} onClick={() => setTab(t.id)} style={{
                  flex: 1, padding: "9px 10px", fontSize: 13, fontWeight: 500,
                  color: active ? "var(--accent-fg)" : "var(--text-muted)",
                  borderBottom: active ? "2px solid var(--accent-solid)" : "2px solid transparent",
                  display: "inline-flex", alignItems: "center", justifyContent: "center", gap: 6,
                }}>
                  {t.label}
                  {t.badge && <span style={{ fontSize: 10, fontWeight: 700, padding: "1px 6px", borderRadius: "var(--r-pill)", background: "var(--accent-bg)", color: "var(--accent-fg)" }}>{t.badge}</span>}
                </button>
              );
            })}
          </div>
        )}

        <div style={{ flex: 1, minHeight: 0, display: "flex", flexDirection: isMobile ? "column" : "row" }}>
          {/* Timeline */}
          {showTimeline && (
            <div style={{ flex: 1, overflow: "auto", padding: isMobile ? 14 : 28, minWidth: 0 }}>
              {!isMobile && (
                <div style={{ marginBottom: 18 }}>
                  <h2 style={{ margin: "0 0 12px", fontSize: 14, fontWeight: 600, color: "var(--text-strong)", textTransform: "uppercase", letterSpacing: 0.6 }}>Description</h2>
                  <Card>
                    <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 8 }}>
                      <Avatar name="Marine Petit" size={24}/>
                      <span style={{ fontSize: 13, fontWeight: 500 }}>Marine Petit</span>
                      <span style={{ fontSize: 11, color: "var(--text-muted)" }}>il y a 5 min</span>
                    </div>
                    <p style={{ margin: 0, fontSize: 13, lineHeight: 1.6, color: "var(--text)" }}>
                      Quand un commercial clique sur « Valider » sur une facture brouillon avec un montant à virgule (ex. 124,50 €), la page affiche une erreur 500. Vu chez 3 clients aujourd'hui, c'est urgent.
                    </p>
                  </Card>
                </div>
              )}

              <h2 style={{ margin: "0 0 12px", fontSize: 14, fontWeight: 600, color: "var(--text-strong)", textTransform: "uppercase", letterSpacing: 0.6 }}>Activité</h2>
              <div style={{ position: "relative", paddingLeft: 28 }}>
                <div style={{ position: "absolute", left: 11, top: 6, bottom: 6, width: 2, background: "var(--divider)" }}/>
                {TIMELINE.map((e, i) => (
                  <div key={i} style={{ position: "relative", paddingBottom: 16 }}>
                    <span style={{
                      position: "absolute", left: -24, top: 2,
                      width: 24, height: 24, borderRadius: "50%",
                      background: e.kind === "claude" ? "transparent" : "var(--paper)",
                      border: e.kind === "claude" ? "none" : "2px solid var(--border)",
                      display: "inline-flex", alignItems: "center", justifyContent: "center",
                    }}>
                      {e.kind === "claude" ? <AutodevAvatar size={24}/> : <Icon name="check" size={11} color="var(--text-muted)"/>}
                    </span>
                    <Card padding={12} style={{ background: e.kind === "claude" ? "var(--accent-bg)" : "var(--paper)", borderColor: e.kind === "claude" ? "var(--accent-bg-strong)" : "var(--border)" }}>
                      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 4 }}>
                        <span style={{ fontSize: 12, fontWeight: 600, color: e.kind === "claude" ? "var(--accent-fg)" : "var(--text-strong)" }}>{e.title}</span>
                        <span style={{ fontSize: 11, color: "var(--text-muted)", fontFamily: "var(--font-mono)" }}>{e.at}</span>
                      </div>
                      <div style={{ fontSize: 12, color: "var(--text)", lineHeight: 1.55 }}>{e.detail}</div>
                    </Card>
                  </div>
                ))}
                <div style={{ position: "relative", paddingBottom: 8 }}>
                  <span style={{
                    position: "absolute", left: -24, top: 2,
                    width: 24, height: 24, borderRadius: "50%",
                    display: "inline-flex", alignItems: "center", justifyContent: "center",
                  }}>
                    <AutodevAvatar size={24}/>
                  </span>
                  <Card padding={12} style={{ background: "var(--accent-bg)", borderColor: "var(--accent-bg-strong)" }}>
                    <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                      <span style={{ display: "inline-flex", gap: 3 }}>
                        {[0, 1, 2].map(i => (
                          <span key={i} style={{ width: 5, height: 5, borderRadius: "50%", background: "var(--accent-solid)", animation: `pulse 1.4s ${i * 0.2}s ease-out infinite` }}/>
                        ))}
                      </span>
                      <span style={{ fontSize: 12, color: "var(--accent-fg)", fontWeight: 500 }}>Autodev rédige le test pour les montants négatifs…</span>
                    </div>
                  </Card>
                </div>
              </div>
            </div>
          )}

          {/* Chat panel */}
          {showChat && (
            <div style={{
              width: isMobile ? "100%" : 380,
              flex: isMobile ? 1 : "0 0 380px",
              minHeight: 0,
              borderLeft: isMobile ? "none" : "1px solid var(--border)",
              background: "var(--paper)",
              display: "flex", flexDirection: "column",
            }}>
              {!isMobile && (
                <div style={{ padding: "16px 18px", borderBottom: "1px solid var(--border)", display: "flex", alignItems: "center", gap: 10 }}>
                  <AutodevAvatar size={28}/>
                  <div style={{ flex: 1 }}>
                    <div style={{ fontSize: 13, fontWeight: 600, color: "var(--text-strong)" }}>Discussion avec Autodev</div>
                    <div style={{ fontSize: 11, color: "var(--ok-fg)", display: "inline-flex", alignItems: "center", gap: 5 }}>
                      <span style={{ width: 6, height: 6, borderRadius: "50%", background: "var(--ok-500)", animation: "pulse 1.6s ease-out infinite" }}/>
                      en train de coder
                    </div>
                  </div>
                  <IconButton icon={<Icon name="more" size={15}/>} size={28} label="Plus"/>
                </div>
              )}

              <div style={{ flex: 1, overflow: "auto", padding: 18, display: "flex", flexDirection: "column", gap: 14 }}>
                <div style={{ textAlign: "center", fontSize: 11, color: "var(--text-subtle)" }}>Aujourd'hui · 10:42</div>
                {CONVERSATION.map((m, i) => (
                  <Bubble key={i} msg={m}/>
                ))}
              </div>

              <div style={{ padding: 14, borderTop: "1px solid var(--border)", background: "var(--paper-2)" }}>
                <div style={{ display: "flex", alignItems: "flex-end", gap: 8, padding: 10, background: "var(--paper)", border: "1px solid var(--border)", borderRadius: "var(--r-md)", boxShadow: "var(--shadow-xs)" }}>
                  <textarea
                    value={draft}
                    onChange={e => setDraft(e.target.value)}
                    placeholder="Écrire un message à Autodev…"
                    rows={2}
                    style={{ flex: 1, border: "none", outline: "none", resize: "none", fontSize: 13, lineHeight: 1.5, background: "transparent", color: "var(--text)" }}
                  />
                  <Button kind="primary" size="sm" icon={<Icon name="send" size={13}/>} disabled={!draft.trim()}/>
                </div>
                <div style={{ marginTop: 8, fontSize: 11, color: "var(--text-muted)" }}>Autodev voit votre message immédiatement et adapte son travail en cours.</div>
              </div>
            </div>
          )}
        </div>
        {isMobile && <MobileBottomNav active="issues" counts={{ issues: 7, errors: 1, chat: 3 }}/>}
      </main>
    </div>
  );
}

function Bubble({ msg }) {
  const isClaude = msg.who === "claude";
  return (
    <div style={{ display: "flex", gap: 8, alignItems: "flex-start", flexDirection: isClaude ? "row" : "row-reverse" }}>
      {isClaude
        ? <AutodevAvatar size={26}/>
        : <Avatar name="Marine Petit" size={26}/>
      }
      <div style={{ maxWidth: "78%" }}>
        <div style={{
          padding: "9px 13px", borderRadius: 12,
          borderBottomLeftRadius: isClaude ? 3 : 12,
          borderBottomRightRadius: isClaude ? 12 : 3,
          background: isClaude ? "var(--accent-bg)" : "var(--paper-2)",
          color: isClaude ? "var(--text)" : "var(--text)",
          fontSize: 13, lineHeight: 1.5,
        }}>
          {msg.text}
        </div>
        <div style={{ fontSize: 10, color: "var(--text-subtle)", marginTop: 3, textAlign: isClaude ? "left" : "right", paddingInline: 4 }}>{msg.at}</div>
      </div>
    </div>
  );
}

window.ScreenIssueDetail = ScreenIssueDetail;
