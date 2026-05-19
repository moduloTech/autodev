/* Autodev — Spec a new ticket: chat-driven ticket draft (responsive) */

const SPEC_CONVO = [
  { who: "claude", at: "11:02", text: "Bonjour Marine ! Décrivez-moi ce que vous voulez faire — je rédige le ticket et je vous le montre à droite, on l'ajuste ensemble." },
  { who: "user",   at: "11:03", text: "On a beaucoup de retours sur l'écran de paiement. Les utilisateurs perdent leur panier quand ils reviennent en arrière dans le navigateur." },
  { who: "claude", at: "11:03", text: "Compris. Quelques questions pour bien cadrer :\n\n• Doit-on conserver le panier indéfiniment, ou avec une expiration (ex. 7 jours) ?\n• Le panier doit-il être restauré seulement si l'utilisateur est connecté, ou aussi pour les visiteurs anonymes ?\n• Y a-t-il un message à afficher quand le panier est restauré ?" },
  { who: "user",   at: "11:05", text: "7 jours d'expiration. Pour tout le monde, anonyme inclus. Et oui un petit message « Nous avons gardé votre panier 🛒 »." },
  { who: "claude", at: "11:05", text: "Parfait. Je rédige le ticket à droite. Une dernière chose : sur quel projet ? Powerpanne · Web ?" },
  { who: "user",   at: "11:06", text: "Oui, Powerpanne · Web." },
];

function ScreenChatSpec() {
  const w = useShellWidth();
  const mode = shellMode(w);
  const isMobile = mode === "mobile";
  const isDesktop = mode === "desktop";
  const [navOpen, setNavOpen] = React.useState(false);
  const [pane, setPane] = React.useState("chat"); // mobile-only

  const showChat = !isMobile || pane === "chat";
  const showDraft = !isMobile || pane === "draft";

  return (
    <div style={{ display: "flex", height: "100%", background: "var(--bg)", flexDirection: isMobile ? "column" : "row" }}>
      {isDesktop && <Sidebar active="chat" counts={{ issues: 7, errors: 1, chat: 3 }}/>}
      {!isDesktop && navOpen && <MobileNavOverlay active="chat" counts={{ issues: 7, errors: 1, chat: 3 }} onClose={() => setNavOpen(false)}/>}

      <main style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", overflow: "hidden" }}>
        <Topbar
          compact={isMobile}
          onMenuClick={!isDesktop ? () => setNavOpen(true) : null}
          breadcrumb={isMobile ? null : "Conversations › Nouveau ticket"}
          title={isMobile ? "Nouveau ticket" : "Décrivez votre besoin à Autodev"}
          subtitle={isMobile ? null : "Le brouillon de ticket se rédige en direct à droite. Vous pouvez l'éditer avant de le valider."}
          actions={isMobile ? null : <>
            <Button size="md">Annuler</Button>
            <Button kind="primary" size="md" icon={<Icon name="check" size={14}/>}>Créer le ticket</Button>
          </>}
        />

        {isMobile && (
          <div style={{ display: "flex", padding: "8px 12px 0", gap: 6, background: "var(--paper)", borderBottom: "1px solid var(--border)" }}>
            {[{ id: "chat", label: "Discussion" }, { id: "draft", label: "Brouillon" }].map(t => {
              const active = pane === t.id;
              return (
                <button key={t.id} onClick={() => setPane(t.id)} style={{
                  flex: 1, padding: "9px 10px", fontSize: 13, fontWeight: 500,
                  color: active ? "var(--accent-fg)" : "var(--text-muted)",
                  borderBottom: active ? "2px solid var(--accent-solid)" : "2px solid transparent",
                }}>{t.label}</button>
              );
            })}
          </div>
        )}

        <div style={{ flex: 1, minHeight: 0, display: "flex", flexDirection: isMobile ? "column" : "row" }}>
          {/* Chat */}
          {showChat && (
            <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", borderRight: isMobile ? "none" : "1px solid var(--border)", background: "var(--paper)" }}>
              <div style={{ flex: 1, overflow: "auto", padding: isMobile ? 16 : 32, display: "flex", flexDirection: "column", gap: 16, maxWidth: 720, margin: "0 auto", width: "100%" }}>
                <div style={{ textAlign: "center", fontSize: 11, color: "var(--text-subtle)" }}>Conversation démarrée à 11:02</div>
                {SPEC_CONVO.map((m, i) => <Bubble2 key={i} msg={m}/>)}
              </div>
              <div style={{ padding: isMobile ? "12px 14px 14px" : "14px 32px 22px", borderTop: "1px solid var(--border)", background: "var(--paper)" }}>
                <div style={{ maxWidth: 720, margin: "0 auto" }}>
                  <div style={{ display: "flex", alignItems: "flex-end", gap: 8, padding: 12, background: "var(--paper)", border: "1px solid var(--border)", borderRadius: "var(--r-md)", boxShadow: "var(--shadow-sm)" }}>
                    <button style={{ padding: 6, color: "var(--text-muted)" }} aria-label="Joindre"><Icon name="paperclip" size={16}/></button>
                    <textarea placeholder="Votre réponse…" rows={isMobile ? 1 : 2} style={{ flex: 1, border: "none", outline: "none", resize: "none", fontSize: 14, lineHeight: 1.55, background: "transparent", color: "var(--text)" }}/>
                    <Button kind="primary" size="md" icon={<Icon name="send" size={14}/>}>{isMobile ? null : "Envoyer"}</Button>
                  </div>
                  {!isMobile && (
                    <div style={{ marginTop: 8, fontSize: 11, color: "var(--text-muted)", textAlign: "center" }}>Astuce : décrivez le besoin métier, pas la solution technique. Autodev se charge du « comment ».</div>
                  )}
                </div>
              </div>
            </div>
          )}

          {/* Draft */}
          {showDraft && (
            <div style={{
              width: isMobile ? "100%" : 460,
              flex: isMobile ? 1 : "0 0 460px",
              background: "var(--bg)",
              display: "flex", flexDirection: "column", minHeight: 0,
            }}>
              <div style={{ padding: isMobile ? "12px 14px" : "16px 22px", borderBottom: "1px solid var(--border)", background: "var(--paper)", display: "flex", alignItems: "center", justifyContent: "space-between" }}>
                <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                  <Icon name="sparkles" size={14} color="var(--accent-fg)"/>
                  <span style={{ fontSize: 12, fontWeight: 600, color: "var(--text-strong)", textTransform: "uppercase", letterSpacing: 0.6 }}>Brouillon de ticket</span>
                </div>
                <span style={{ fontSize: 11, color: "var(--ok-fg)", display: "inline-flex", alignItems: "center", gap: 5 }}>
                  <span style={{ width: 6, height: 6, borderRadius: "50%", background: "var(--ok-500)" }}/>
                  Mis à jour
                </span>
              </div>
              <div style={{ flex: 1, overflow: "auto", padding: isMobile ? 16 : 22 }}>
                <div style={{ background: "var(--paper)", borderRadius: "var(--r-lg)", border: "1px solid var(--border)", padding: isMobile ? 18 : 22, boxShadow: "var(--shadow-xs)" }}>
                  <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 14 }}>
                    <span style={{ width: 8, height: 8, borderRadius: 2, background: "#2A6FDB" }}/>
                    <span style={{ fontSize: 11, color: "var(--text-muted)" }}>Powerpanne · Web</span>
                  </div>
                  <h2 style={{ margin: "0 0 16px", fontSize: 18, fontWeight: 600, lineHeight: 1.3, color: "var(--text-strong)" }}>
                    Conserver le panier de l'utilisateur après un retour navigateur
                  </h2>
                  <SpecField label="Contexte">
                    Sur l'écran de paiement, les utilisateurs perdent leur panier lorsqu'ils utilisent le bouton « retour » du navigateur. Plusieurs retours clients confirment le problème.
                  </SpecField>
                  <SpecField label="Comportement attendu">
                    <ul style={{ margin: 0, paddingLeft: 18, lineHeight: 1.6 }}>
                      <li>Le panier est conservé pendant <strong>7 jours</strong>.</li>
                      <li>Cela s'applique aux <strong>visiteurs anonymes</strong> comme aux utilisateurs connectés.</li>
                      <li>Quand un panier est restauré, afficher : <em>« Nous avons gardé votre panier 🛒 »</em>.</li>
                    </ul>
                  </SpecField>
                  <SpecField label="Critères d'acceptation">
                    <ol style={{ margin: 0, paddingLeft: 18, lineHeight: 1.6 }}>
                      <li>Un utilisateur peut quitter et revenir, son panier est intact.</li>
                      <li>Au bout de 7 jours, le panier est vidé automatiquement.</li>
                      <li>Le bandeau de restauration s'affiche une seule fois par session.</li>
                    </ol>
                  </SpecField>
                  <div style={{ display: "flex", gap: 6, flexWrap: "wrap", marginTop: 10 }}>
                    {["frontend", "panier", "ux", "powerpanne-web"].map(t => (
                      <span key={t} style={{ fontSize: 11, padding: "3px 8px", borderRadius: "var(--r-pill)", background: "var(--paper-2)", color: "var(--text-muted)" }}>{t}</span>
                    ))}
                  </div>
                </div>
                <div style={{ marginTop: 14, padding: 12, background: "var(--accent-bg)", border: "1px solid var(--accent-bg-strong)", borderRadius: "var(--r-md)", display: "flex", gap: 10, alignItems: "flex-start" }}>
                  <Icon name="info" size={14} color="var(--accent-fg)"/>
                  <div style={{ fontSize: 12, color: "var(--text)", lineHeight: 1.5 }}>
                    <strong style={{ color: "var(--accent-fg)" }}>Autodev :</strong> Une fois le ticket validé, je commencerai par cartographier le flux du panier dans le code, puis je vous montrerai mon plan avant de toucher quoi que ce soit.
                  </div>
                </div>
              </div>
              {isMobile && (
                <div style={{ padding: 14, borderTop: "1px solid var(--border)", background: "var(--paper)", display: "flex", gap: 8 }}>
                  <Button size="md" full>Annuler</Button>
                  <Button kind="primary" size="md" full icon={<Icon name="check" size={14}/>}>Créer</Button>
                </div>
              )}
            </div>
          )}
        </div>
        {isMobile && <MobileBottomNav active="chat" counts={{ issues: 7, errors: 1, chat: 3 }}/>}
      </main>
    </div>
  );
}

function SpecField({ label, children }) {
  return (
    <div style={{ marginBottom: 16 }}>
      <div style={{ fontSize: 10, fontWeight: 600, color: "var(--text-muted)", textTransform: "uppercase", letterSpacing: 0.7, marginBottom: 6 }}>{label}</div>
      <div style={{ fontSize: 13, color: "var(--text)", lineHeight: 1.55 }}>{children}</div>
    </div>
  );
}

function Bubble2({ msg }) {
  const isClaude = msg.who === "claude";
  return (
    <div style={{ display: "flex", gap: 10, alignItems: "flex-start", flexDirection: isClaude ? "row" : "row-reverse" }}>
      {isClaude
        ? <AutodevAvatar size={32}/>
        : <Avatar name="Marine Petit" size={32}/>
      }
      <div style={{ maxWidth: "82%" }}>
        <div style={{
          padding: "11px 14px", borderRadius: 14,
          borderBottomLeftRadius: isClaude ? 4 : 14,
          borderBottomRightRadius: isClaude ? 14 : 4,
          background: isClaude ? "var(--accent-bg)" : "var(--paper-2)",
          color: "var(--text)",
          fontSize: 13.5, lineHeight: 1.6, whiteSpace: "pre-wrap",
        }}>
          {msg.text}
        </div>
        <div style={{ fontSize: 10, color: "var(--text-subtle)", marginTop: 4, textAlign: isClaude ? "left" : "right", paddingInline: 6 }}>
          {isClaude ? "Autodev" : "Vous"} · {msg.at}
        </div>
      </div>
    </div>
  );
}

window.ScreenChatSpec = ScreenChatSpec;
