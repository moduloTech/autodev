/* Autodev — Spec a new ticket
   Layout (desktop): sidebar | center = wide ticket editor | right = Autodev chat.
   The editor supports two modes:
     • Édition manuelle (markdown source + formatting toolbar + drag-and-drop captures)
     • Aperçu (rendered preview of the ticket)
   The chat keeps the conversational mode in parallel; suggestions can be applied to the draft.
   Mobile collapses into tabs: Édition / Discussion. */

const SPEC_CONVO = [
  { who: "claude", at: "11:02", text: "Bonjour Marine ! Décrivez votre besoin — je rédige une première version au centre, on l'ajuste ensemble.", suggestion: null },
  { who: "user",   at: "11:03", text: "On a beaucoup de retours sur l'écran de paiement. Les utilisateurs perdent leur panier quand ils reviennent en arrière dans le navigateur." },
  { who: "claude", at: "11:03", text: "Compris — quelques points à trancher :\n\n• Doit-on conserver le panier indéfiniment, ou avec une expiration (ex. 7 jours) ?\n• Restauration aussi pour les visiteurs anonymes ?\n• Un message lors de la restauration ?" },
  { who: "user",   at: "11:05", text: "7 jours d'expiration. Pour tout le monde, anonyme inclus. Et oui un petit message « Nous avons gardé votre panier 🛒 »." },
  { who: "claude", at: "11:06", text: "Parfait, j'ai inséré les critères d'acceptation à droite dans le ticket. Je propose aussi d'ajouter un cas pour le navigateur privé — d'accord pour l'inclure ?",
    suggestion: { kind: "insert", target: "Critères d'acceptation", text: "Le panier n'est PAS restauré en navigation privée." } },
];

const INITIAL_MD = `## Contexte

Sur l'écran de paiement, les utilisateurs perdent leur panier lorsqu'ils utilisent le bouton « retour » du navigateur. Plusieurs retours clients confirment le problème (voir captures jointes).

## Comportement attendu

- Le panier est conservé pendant **7 jours**.
- Cela s'applique aux **visiteurs anonymes** comme aux utilisateurs connectés.
- À la restauration, afficher un message discret : _« Nous avons gardé votre panier 🛒 »_.

## Critères d'acceptation

1. Un utilisateur peut quitter le site et revenir, son panier est intact.
2. Au bout de 7 jours, le panier est vidé automatiquement.
3. Le bandeau de restauration s'affiche une seule fois par session.

## Hors périmètre

- Synchronisation cross-device du panier (à voir dans un autre ticket).
`;

const INITIAL_ATTACHMENTS = [
  { id: "a1", name: "panier-perdu.png",      size: "284 Ko", w: 1280, h: 720, tint: "#E5EEFB" },
  { id: "a2", name: "retour-navigateur.png", size: "412 Ko", w: 1280, h: 720, tint: "#F1EEFE" },
];

function ScreenChatSpec() {
  const w = useShellWidth();
  const mode = shellMode(w);
  const isMobile = mode === "mobile";
  const isDesktop = mode === "desktop";
  const isTablet = mode === "tablet";
  const [navOpen, setNavOpen] = React.useState(false);
  const [pane, setPane] = React.useState("draft"); // mobile-only: draft | chat
  const [editorMode, setEditorMode] = React.useState("edit"); // edit | preview
  const [md, setMd] = React.useState(INITIAL_MD);
  const [title, setTitle] = React.useState("Conserver le panier après un retour navigateur");
  const [attachments, setAttachments] = React.useState(INITIAL_ATTACHMENTS);
  const [dragOver, setDragOver] = React.useState(false);

  const showDraft = !isMobile || pane === "draft";
  const showChat  = !isMobile || pane === "chat";

  return (
    <div style={{ display: "flex", height: "100%", background: "var(--bg)", flexDirection: isMobile ? "column" : "row" }}>
      {isDesktop && <Sidebar active="chat" counts={{ issues: 7, errors: 1, chat: 3 }}/>}
      {!isDesktop && navOpen && <MobileNavOverlay active="chat" counts={{ issues: 7, errors: 1, chat: 3 }} onClose={() => setNavOpen(false)}/>}

      <main style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", overflow: "hidden" }}>
        <Topbar
          compact={isMobile}
          onMenuClick={!isDesktop ? () => setNavOpen(true) : null}
          breadcrumb={isMobile ? null : "Conversations › Nouveau ticket"}
          title={isMobile ? "Nouveau ticket" : "Nouveau ticket"}
          subtitle={isMobile ? null : "Rédigez à la main ou laissez Autodev poser les bonnes questions — les deux modes sont en parallèle."}
          actions={isMobile ? null : <>
            <Button size="md" icon={<Icon name="copy" size={14}/>}>Brouillon</Button>
            <Button kind="primary" size="md" icon={<Icon name="check" size={14}/>}>Créer le ticket</Button>
          </>}
        />

        {isMobile && (
          <div style={{ display: "flex", padding: "8px 12px 0", gap: 6, background: "var(--paper)", borderBottom: "1px solid var(--border)" }}>
            {[{ id: "draft", label: "Édition" }, { id: "chat", label: "Discussion" }].map(t => {
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
          {/* CENTER · Editor */}
          {showDraft && (
            <DraftEditor
              isMobile={isMobile}
              isTablet={isTablet}
              editorMode={editorMode}
              setEditorMode={setEditorMode}
              md={md}
              setMd={setMd}
              title={title}
              setTitle={setTitle}
              attachments={attachments}
              setAttachments={setAttachments}
              dragOver={dragOver}
              setDragOver={setDragOver}
            />
          )}

          {/* RIGHT · Chat */}
          {showChat && (
            <ChatPane isMobile={isMobile} isTablet={isTablet} setMd={setMd} md={md}/>
          )}
        </div>

        {isMobile && pane === "draft" && (
          <div style={{ padding: 14, borderTop: "1px solid var(--border)", background: "var(--paper)", display: "flex", gap: 8 }}>
            <Button size="md" full>Annuler</Button>
            <Button kind="primary" size="md" full icon={<Icon name="check" size={14}/>}>Créer</Button>
          </div>
        )}
        {isMobile && <MobileBottomNav active="chat" counts={{ issues: 7, errors: 1, chat: 3 }}/>}
      </main>
    </div>
  );
}

/* ── Center: Ticket editor ──────────────────────────────────────────────── */
function DraftEditor({ isMobile, isTablet, editorMode, setEditorMode, md, setMd, title, setTitle, attachments, setAttachments, dragOver, setDragOver }) {
  const pad = isMobile ? 16 : (isTablet ? 22 : 32);
  const onDrop = (e) => {
    e.preventDefault();
    setDragOver(false);
    const files = Array.from(e.dataTransfer?.files || []);
    if (!files.length) return;
    const next = files.map((f, i) => ({
      id: `drop-${Date.now()}-${i}`,
      name: f.name,
      size: `${Math.max(1, Math.round((f.size || 200000) / 1024))} Ko`,
      w: 1280, h: 720, tint: "#E2F4F2",
    }));
    setAttachments(a => [...a, ...next]);
  };

  return (
    <div
      onDragOver={e => { e.preventDefault(); setDragOver(true); }}
      onDragLeave={() => setDragOver(false)}
      onDrop={onDrop}
      style={{
        flex: 1, minWidth: 0, display: "flex", flexDirection: "column",
        background: "var(--bg)", position: "relative",
        borderRight: isMobile ? "none" : "1px solid var(--border)",
      }}>

      {/* Editor toolbar */}
      <div style={{
        flex: "0 0 auto", padding: `12px ${pad}px`, borderBottom: "1px solid var(--border)",
        background: "var(--paper)", display: "flex", alignItems: "center", gap: 12, flexWrap: "wrap",
      }}>
        <SegmentedTabs
          value={editorMode}
          onChange={setEditorMode}
          tabs={[
            { id: "edit", label: "Édition", icon: "code" },
            { id: "preview", label: "Aperçu", icon: "eye" /* falls back to image */ },
          ]}
        />
        <div style={{ width: 1, height: 22, background: "var(--border)" }}/>
        {editorMode === "edit" ? (
          <FormatToolbar setMd={setMd}/>
        ) : (
          <span style={{ fontSize: 12, color: "var(--text-muted)" }}>Rendu tel qu'il sera affiché dans la demande.</span>
        )}
        <div style={{ marginLeft: "auto", display: "flex", alignItems: "center", gap: 10 }}>
          <span style={{ fontSize: 11, color: "var(--ok-fg)", display: "inline-flex", alignItems: "center", gap: 5 }}>
            <span style={{ width: 6, height: 6, borderRadius: "50%", background: "var(--ok-500)" }}/>
            Enregistré
          </span>
        </div>
      </div>

      {/* Scrollable editor body — central column */}
      <div style={{ flex: 1, minHeight: 0, overflow: "auto" }}>
        <div style={{
          maxWidth: 820, margin: "0 auto",
          padding: `${isMobile ? 18 : 28}px ${pad}px ${isMobile ? 24 : 40}px`,
          display: "flex", flexDirection: "column", gap: isMobile ? 14 : 18,
        }}>

          {/* Project + tags strip */}
          <MetaBar isMobile={isMobile}/>

          {/* Title */}
          {editorMode === "edit" ? (
            <input
              value={title}
              onChange={e => setTitle(e.target.value)}
              placeholder="Titre du ticket"
              style={{
                width: "100%", border: "none", outline: "none", background: "transparent",
                fontSize: isMobile ? 22 : 28, fontWeight: 600, lineHeight: 1.2,
                color: "var(--text-strong)", letterSpacing: -0.4, padding: 0,
              }}
            />
          ) : (
            <h1 style={{ margin: 0, fontSize: isMobile ? 22 : 28, fontWeight: 600, lineHeight: 1.2, color: "var(--text-strong)", letterSpacing: -0.4 }}>
              {title}
            </h1>
          )}

          {/* Editor or preview */}
          {editorMode === "edit" ? (
            <MarkdownTextarea value={md} onChange={setMd}/>
          ) : (
            <MarkdownPreview md={md}/>
          )}

          {/* Attachments — drag-and-drop zone */}
          <Attachments
            items={attachments}
            onRemove={(id) => setAttachments(a => a.filter(x => x.id !== id))}
            dragOver={dragOver}
            compact={isMobile}
          />

          {/* Bottom hint */}
          <div style={{
            display: "flex", gap: 10, alignItems: "center",
            padding: "10px 14px", borderRadius: "var(--r-md)",
            background: "var(--paper-2)", border: "1px solid var(--border)",
            fontSize: 12, color: "var(--text-muted)",
          }}>
            <Icon name="info" size={14} color="var(--text-muted)"/>
            <span>
              Markdown supporté · glissez une capture n'importe où dans cette zone pour la joindre · <kbd style={kbdStyle}>⌘</kbd>+<kbd style={kbdStyle}>↵</kbd> pour créer
            </span>
          </div>
        </div>
      </div>

      {/* Drop overlay */}
      {dragOver && (
        <div style={{
          position: "absolute", inset: 0, pointerEvents: "none",
          display: "flex", alignItems: "center", justifyContent: "center",
          background: "color-mix(in oklab, var(--accent-bg) 92%, transparent)",
          border: "2px dashed var(--accent-solid)",
          borderRadius: 8,
          zIndex: 4,
        }}>
          <div style={{
            display: "flex", flexDirection: "column", alignItems: "center", gap: 8,
            padding: "20px 28px", background: "var(--paper)",
            borderRadius: "var(--r-lg)", boxShadow: "var(--shadow-md)",
          }}>
            <Icon name="image" size={26} color="var(--accent-fg)"/>
            <div style={{ fontSize: 14, fontWeight: 600, color: "var(--accent-fg)" }}>Déposez vos captures ici</div>
            <div style={{ fontSize: 12, color: "var(--text-muted)" }}>PNG, JPG, GIF — jusqu'à 10 Mo</div>
          </div>
        </div>
      )}
    </div>
  );
}

const kbdStyle = {
  fontFamily: "var(--font-mono)", fontSize: 10,
  padding: "1px 5px", border: "1px solid var(--border)", borderRadius: 4,
  background: "var(--paper)", color: "var(--text)",
};

function SegmentedTabs({ value, onChange, tabs }) {
  return (
    <div style={{
      display: "inline-flex", padding: 3, background: "var(--paper-2)",
      borderRadius: "var(--r-pill)", border: "1px solid var(--border)", gap: 2,
    }}>
      {tabs.map(t => {
        const active = value === t.id;
        return (
          <button key={t.id} onClick={() => onChange(t.id)} style={{
            display: "inline-flex", alignItems: "center", gap: 6,
            padding: "5px 12px", fontSize: 12, fontWeight: 500,
            borderRadius: "var(--r-pill)",
            background: active ? "var(--paper)" : "transparent",
            color: active ? "var(--text-strong)" : "var(--text-muted)",
            boxShadow: active ? "var(--shadow-xs)" : "none",
          }}>
            <Icon name={t.icon === "eye" ? "image" : t.icon} size={13}/>
            {t.label}
          </button>
        );
      })}
    </div>
  );
}

function FormatToolbar({ setMd }) {
  const btn = (icon, label, onClick) => (
    <button
      key={label}
      onClick={onClick}
      title={label}
      aria-label={label}
      style={{
        width: 28, height: 28, borderRadius: 6,
        display: "inline-flex", alignItems: "center", justifyContent: "center",
        color: "var(--text-muted)",
      }}>
      {icon}
    </button>
  );
  const insert = (snippet) => setMd(m => `${m}\n${snippet}\n`);
  return (
    <div style={{ display: "inline-flex", alignItems: "center", gap: 2 }}>
      {btn(<strong style={{ fontSize: 13, color: "var(--text)" }}>B</strong>, "Gras", () => insert("**texte**"))}
      {btn(<em style={{ fontSize: 13, color: "var(--text)" }}>I</em>, "Italique", () => insert("_texte_"))}
      {btn(<span style={{ fontSize: 12, fontFamily: "var(--font-mono)", color: "var(--text)" }}>{"</>"}</span>, "Code", () => insert("`code`"))}
      <div style={{ width: 1, height: 16, background: "var(--border)", margin: "0 4px" }}/>
      {btn(<span style={{ fontSize: 12, fontWeight: 600, color: "var(--text)" }}>H</span>, "Titre", () => insert("## Titre"))}
      {btn(<Icon name="list" size={14}/>, "Liste", () => insert("- élément"))}
      {btn(<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"><path d="M3 6h14M3 12h14M3 18h14"/><path d="M20 6v12"/></svg>, "Citation", () => insert("> citation"))}
      <div style={{ width: 1, height: 16, background: "var(--border)", margin: "0 4px" }}/>
      {btn(<Icon name="paperclip" size={14}/>, "Joindre un fichier")}
      {btn(<Icon name="image" size={14}/>, "Insérer une image")}
    </div>
  );
}

function MarkdownTextarea({ value, onChange }) {
  return (
    <div style={{
      background: "var(--paper)", border: "1px solid var(--border)",
      borderRadius: "var(--r-lg)", padding: "18px 22px",
      boxShadow: "var(--shadow-xs)",
    }}>
      <textarea
        value={value}
        onChange={e => onChange(e.target.value)}
        spellCheck={false}
        style={{
          width: "100%", minHeight: 320,
          border: "none", outline: "none", resize: "vertical",
          background: "transparent",
          fontFamily: "var(--font-mono)", fontSize: 13.5, lineHeight: 1.65,
          color: "var(--text)",
        }}
      />
    </div>
  );
}

function MarkdownPreview({ md }) {
  // Lightweight markdown → JSX (headings, lists, bold, italic, code).
  const blocks = parseMarkdownBlocks(md);
  return (
    <div style={{
      background: "var(--paper)", border: "1px solid var(--border)",
      borderRadius: "var(--r-lg)", padding: "8px 28px 22px",
      boxShadow: "var(--shadow-xs)",
      fontSize: 14, lineHeight: 1.65, color: "var(--text)",
    }}>
      {blocks.map((b, i) => renderBlock(b, i))}
    </div>
  );
}

function parseMarkdownBlocks(md) {
  const lines = md.split("\n");
  const blocks = [];
  let i = 0;
  while (i < lines.length) {
    const l = lines[i];
    if (/^##\s/.test(l)) { blocks.push({ type: "h2", text: l.replace(/^##\s/, "") }); i++; continue; }
    if (/^#\s/.test(l))  { blocks.push({ type: "h1", text: l.replace(/^#\s/, "") }); i++; continue; }
    if (/^-\s/.test(l))  {
      const items = [];
      while (i < lines.length && /^-\s/.test(lines[i])) { items.push(lines[i].replace(/^-\s/, "")); i++; }
      blocks.push({ type: "ul", items }); continue;
    }
    if (/^\d+\.\s/.test(l)) {
      const items = [];
      while (i < lines.length && /^\d+\.\s/.test(lines[i])) { items.push(lines[i].replace(/^\d+\.\s/, "")); i++; }
      blocks.push({ type: "ol", items }); continue;
    }
    if (/^>\s/.test(l)) { blocks.push({ type: "quote", text: l.replace(/^>\s/, "") }); i++; continue; }
    if (l.trim() === "") { i++; continue; }
    // paragraph: collect until blank
    const para = [l]; i++;
    while (i < lines.length && lines[i].trim() !== "" && !/^(#|-|\d+\.|>)/.test(lines[i])) { para.push(lines[i]); i++; }
    blocks.push({ type: "p", text: para.join(" ") });
  }
  return blocks;
}

function renderInline(text, keyBase = "") {
  // **bold**, _italic_, `code`
  const parts = [];
  let rest = text;
  let k = 0;
  const re = /(\*\*([^*]+)\*\*|_([^_]+)_|`([^`]+)`)/;
  while (rest) {
    const m = rest.match(re);
    if (!m) { parts.push(<React.Fragment key={`${keyBase}-t${k++}`}>{rest}</React.Fragment>); break; }
    if (m.index > 0) parts.push(<React.Fragment key={`${keyBase}-t${k++}`}>{rest.slice(0, m.index)}</React.Fragment>);
    if (m[2] != null) parts.push(<strong key={`${keyBase}-b${k++}`} style={{ color: "var(--text-strong)" }}>{m[2]}</strong>);
    else if (m[3] != null) parts.push(<em key={`${keyBase}-i${k++}`}>{m[3]}</em>);
    else if (m[4] != null) parts.push(<code key={`${keyBase}-c${k++}`} style={{ fontFamily: "var(--font-mono)", fontSize: 12.5, padding: "1px 5px", borderRadius: 4, background: "var(--paper-2)", border: "1px solid var(--border)" }}>{m[4]}</code>);
    rest = rest.slice(m.index + m[0].length);
  }
  return parts;
}

function renderBlock(b, i) {
  switch (b.type) {
    case "h1": return <h2 key={i} style={{ margin: "20px 0 8px", fontSize: 20, fontWeight: 600, color: "var(--text-strong)" }}>{renderInline(b.text, `h1-${i}`)}</h2>;
    case "h2": return <h3 key={i} style={{ margin: "18px 0 6px", fontSize: 15, fontWeight: 600, color: "var(--text-strong)", textTransform: "none" }}>{renderInline(b.text, `h2-${i}`)}</h3>;
    case "ul": return <ul key={i} style={{ margin: "4px 0", paddingLeft: 22 }}>{b.items.map((it, j) => <li key={j} style={{ margin: "3px 0" }}>{renderInline(it, `ul-${i}-${j}`)}</li>)}</ul>;
    case "ol": return <ol key={i} style={{ margin: "4px 0", paddingLeft: 22 }}>{b.items.map((it, j) => <li key={j} style={{ margin: "3px 0" }}>{renderInline(it, `ol-${i}-${j}`)}</li>)}</ol>;
    case "quote": return <blockquote key={i} style={{ margin: "8px 0", padding: "6px 12px", borderLeft: "3px solid var(--border-strong)", color: "var(--text-muted)" }}>{renderInline(b.text, `q-${i}`)}</blockquote>;
    default: return <p key={i} style={{ margin: "6px 0" }}>{renderInline(b.text, `p-${i}`)}</p>;
  }
}

function MetaBar({ isMobile }) {
  return (
    <div style={{
      display: "flex", flexWrap: "wrap", alignItems: "center", gap: 8,
    }}>
      <MetaChip icon={<span style={{ width: 8, height: 8, borderRadius: 2, background: "#2A6FDB" }}/>}>
        Powerpanne · Web
      </MetaChip>
      <MetaChip icon={<Icon name="alert-tri" size={12} color="var(--warn-500)"/>}>
        Type · Bug
      </MetaChip>
      <MetaChip icon={<Icon name="user" size={12}/>}>
        Assigné · Autodev
      </MetaChip>
      <MetaChip icon={<Icon name="clock" size={12}/>}>
        Priorité · Standard
      </MetaChip>
      {!isMobile && (
        <>
          <span style={{ width: 1, height: 18, background: "var(--border)", margin: "0 2px" }}/>
          {["frontend", "panier", "ux"].map(t => (
            <span key={t} style={{
              fontSize: 11, padding: "3px 8px", borderRadius: "var(--r-pill)",
              background: "var(--paper-2)", color: "var(--text-muted)",
              border: "1px solid var(--border)",
            }}>#{t}</span>
          ))}
          <button style={{
            fontSize: 11, padding: "3px 8px", borderRadius: "var(--r-pill)",
            color: "var(--text-muted)", border: "1px dashed var(--border-strong)",
            display: "inline-flex", alignItems: "center", gap: 4,
          }}>
            <Icon name="plus" size={11}/> étiquette
          </button>
        </>
      )}
    </div>
  );
}

function MetaChip({ icon, children }) {
  return (
    <button style={{
      display: "inline-flex", alignItems: "center", gap: 6,
      padding: "5px 10px", borderRadius: "var(--r-pill)",
      background: "var(--paper)", border: "1px solid var(--border)",
      fontSize: 12, color: "var(--text)", boxShadow: "var(--shadow-xs)",
    }}>
      {icon}
      <span>{children}</span>
      <Icon name="chevron-d" size={11} color="var(--text-muted)"/>
    </button>
  );
}

function Attachments({ items, onRemove, dragOver, compact }) {
  return (
    <div>
      <div style={{
        display: "flex", alignItems: "center", justifyContent: "space-between",
        marginBottom: 8,
      }}>
        <div style={{
          fontSize: 11, fontWeight: 600, color: "var(--text-muted)",
          textTransform: "uppercase", letterSpacing: 0.6,
        }}>
          Captures jointes · {items.length}
        </div>
        <button style={{
          fontSize: 12, color: "var(--accent-fg)", display: "inline-flex", alignItems: "center", gap: 5,
        }}>
          <Icon name="paperclip" size={12}/> Ajouter
        </button>
      </div>
      <div style={{
        display: "grid",
        gridTemplateColumns: compact ? "1fr" : "repeat(auto-fill, minmax(220px, 1fr))",
        gap: 10,
      }}>
        {items.map(a => <AttachmentCard key={a.id} item={a} onRemove={() => onRemove(a.id)}/>)}
        <DropTarget compact={compact}/>
      </div>
    </div>
  );
}

function AttachmentCard({ item, onRemove }) {
  return (
    <div style={{
      background: "var(--paper)", border: "1px solid var(--border)",
      borderRadius: "var(--r-md)", overflow: "hidden", boxShadow: "var(--shadow-xs)",
      display: "flex", flexDirection: "column",
    }}>
      <div style={{
        height: 112, background: item.tint || "var(--paper-2)",
        position: "relative", display: "flex", alignItems: "center", justifyContent: "center",
        borderBottom: "1px solid var(--border)",
        backgroundImage: `repeating-linear-gradient(45deg, transparent 0 6px, rgba(14,16,20,0.04) 6px 7px)`,
      }}>
        <Icon name="image" size={22} color="var(--text-muted)"/>
        <button onClick={onRemove} aria-label="Retirer" style={{
          position: "absolute", top: 6, right: 6,
          width: 22, height: 22, borderRadius: "50%",
          background: "var(--paper)", border: "1px solid var(--border)",
          display: "inline-flex", alignItems: "center", justifyContent: "center",
          color: "var(--text-muted)", boxShadow: "var(--shadow-xs)",
        }}>
          <Icon name="x" size={11}/>
        </button>
      </div>
      <div style={{ padding: "8px 10px", display: "flex", alignItems: "center", gap: 8 }}>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{
            fontSize: 12, color: "var(--text)", fontWeight: 500,
            overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
          }}>{item.name}</div>
          <div style={{ fontSize: 10.5, color: "var(--text-muted)" }}>{item.w}×{item.h} · {item.size}</div>
        </div>
        <button aria-label="Copier le markdown" style={{ color: "var(--text-muted)" }}>
          <Icon name="copy" size={13}/>
        </button>
      </div>
    </div>
  );
}

function DropTarget({ compact }) {
  return (
    <div style={{
      minHeight: compact ? 88 : 156,
      border: "1.5px dashed var(--border-strong)",
      borderRadius: "var(--r-md)",
      display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 6,
      background: "var(--paper-2)",
      color: "var(--text-muted)",
      padding: 12, textAlign: "center",
    }}>
      <Icon name="image" size={20}/>
      <div style={{ fontSize: 12, fontWeight: 500, color: "var(--text)" }}>Glisser une capture</div>
      <div style={{ fontSize: 11 }}>ou <span style={{ color: "var(--accent-fg)", textDecoration: "underline" }}>parcourir</span></div>
    </div>
  );
}

/* ── Right: Chat pane ────────────────────────────────────────────────── */
function ChatPane({ isMobile, isTablet, setMd, md }) {
  const width = isMobile ? "100%" : (isTablet ? 320 : 380);
  return (
    <div style={{
      width, flex: isMobile ? 1 : `0 0 ${width}px`,
      background: "var(--paper)",
      display: "flex", flexDirection: "column", minHeight: 0,
    }}>
      <div style={{
        padding: "14px 18px", borderBottom: "1px solid var(--border)",
        display: "flex", alignItems: "center", gap: 10, flex: "0 0 auto",
      }}>
        <AutodevAvatar size={28}/>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 13, fontWeight: 600, color: "var(--text-strong)", display: "flex", alignItems: "center", gap: 6 }}>
            Autodev
            <span style={{ width: 6, height: 6, borderRadius: "50%", background: "var(--ok-500)" }}/>
          </div>
          <div style={{ fontSize: 11, color: "var(--text-muted)" }}>Vous aide à cadrer le ticket</div>
        </div>
        <IconButton icon={<Icon name="more" size={16}/>} size={28} label="Options"/>
      </div>

      <div style={{
        flex: 1, overflow: "auto", padding: "16px 18px",
        display: "flex", flexDirection: "column", gap: 14,
      }}>
        <div style={{ textAlign: "center", fontSize: 10.5, color: "var(--text-subtle)" }}>
          Aujourd'hui · 11:02
        </div>
        {SPEC_CONVO.map((m, i) => (
          <ChatMessage key={i} msg={m} onApplySuggestion={(s) => {
            if (s.kind === "insert") {
              setMd(md + `\n${s.target ? "" : ""}- ${s.text}\n`);
            }
          }}/>
        ))}
        <TypingHint/>
      </div>

      {/* Composer */}
      <div style={{
        flex: "0 0 auto", padding: "12px 14px 14px",
        borderTop: "1px solid var(--border)", background: "var(--paper)",
      }}>
        <div style={{
          display: "flex", flexDirection: "column",
          padding: 10, background: "var(--paper)",
          border: "1px solid var(--border)", borderRadius: "var(--r-md)",
          boxShadow: "var(--shadow-xs)",
        }}>
          <textarea
            placeholder="Posez une question, demandez une reformulation, etc."
            rows={2}
            style={{
              width: "100%", border: "none", outline: "none", resize: "none",
              fontSize: 13, lineHeight: 1.55, background: "transparent", color: "var(--text)",
            }}
          />
          <div style={{ display: "flex", alignItems: "center", gap: 4, marginTop: 4 }}>
            <button aria-label="Joindre" style={{ width: 26, height: 26, color: "var(--text-muted)", display: "inline-flex", alignItems: "center", justifyContent: "center" }}>
              <Icon name="paperclip" size={14}/>
            </button>
            <button aria-label="Insérer dans le ticket" title="Insère la prochaine réponse directement dans le brouillon" style={{ width: 26, height: 26, color: "var(--text-muted)", display: "inline-flex", alignItems: "center", justifyContent: "center" }}>
              <Icon name="arrow-l" size={14}/>
            </button>
            <div style={{ flex: 1 }}/>
            <Button kind="primary" size="sm" icon={<Icon name="send" size={12}/>}>Envoyer</Button>
          </div>
        </div>
        <div style={{ marginTop: 8, display: "flex", flexWrap: "wrap", gap: 6 }}>
          {[
            "Reformule plus court",
            "Ajoute des cas limites",
            "Propose un titre alternatif",
          ].map(s => (
            <button key={s} style={{
              fontSize: 11, padding: "4px 9px", borderRadius: "var(--r-pill)",
              background: "var(--paper-2)", color: "var(--text-muted)",
              border: "1px solid var(--border)",
            }}>{s}</button>
          ))}
        </div>
      </div>
    </div>
  );
}

function ChatMessage({ msg, onApplySuggestion }) {
  const isClaude = msg.who === "claude";
  return (
    <div style={{ display: "flex", gap: 8, alignItems: "flex-start", flexDirection: isClaude ? "row" : "row-reverse" }}>
      {isClaude ? <AutodevAvatar size={24}/> : <Avatar name="Marine Petit" size={24}/>}
      <div style={{ maxWidth: "86%", display: "flex", flexDirection: "column", alignItems: isClaude ? "flex-start" : "flex-end", gap: 6 }}>
        <div style={{
          padding: "9px 12px", borderRadius: 12,
          borderBottomLeftRadius: isClaude ? 3 : 12,
          borderBottomRightRadius: isClaude ? 12 : 3,
          background: isClaude ? "var(--accent-bg)" : "var(--paper-2)",
          color: "var(--text)",
          fontSize: 13, lineHeight: 1.55, whiteSpace: "pre-wrap",
          border: isClaude ? "1px solid var(--accent-bg-strong)" : "1px solid var(--border)",
        }}>
          {msg.text}
        </div>
        {msg.suggestion && (
          <button
            onClick={() => onApplySuggestion(msg.suggestion)}
            style={{
              display: "inline-flex", alignItems: "center", gap: 8,
              padding: "6px 10px", borderRadius: "var(--r-md)",
              background: "var(--paper)", border: "1px dashed var(--accent-bg-strong)",
              color: "var(--accent-fg)", fontSize: 11.5, fontWeight: 500, textAlign: "left",
              maxWidth: "100%",
            }}>
            <Icon name="sparkles" size={12}/>
            <span style={{ flex: 1, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
              Insérer dans « {msg.suggestion.target} »
            </span>
            <Icon name="arrow-l" size={12}/>
          </button>
        )}
        <div style={{ fontSize: 10, color: "var(--text-subtle)", paddingInline: 4 }}>
          {isClaude ? "Autodev" : "Vous"} · {msg.at}
        </div>
      </div>
    </div>
  );
}

function TypingHint() {
  return (
    <div style={{ display: "flex", gap: 8, alignItems: "center", color: "var(--text-muted)", fontSize: 11 }}>
      <AutodevAvatar size={20}/>
      <div style={{ display: "inline-flex", gap: 3, alignItems: "center", padding: "6px 10px", background: "var(--accent-bg)", borderRadius: 10 }}>
        <span style={{ width: 4, height: 4, borderRadius: "50%", background: "var(--accent-solid)", animation: "pulse 1.4s infinite" }}/>
        <span style={{ width: 4, height: 4, borderRadius: "50%", background: "var(--accent-solid)", animation: "pulse 1.4s infinite 0.2s" }}/>
        <span style={{ width: 4, height: 4, borderRadius: "50%", background: "var(--accent-solid)", animation: "pulse 1.4s infinite 0.4s" }}/>
      </div>
      <span>Autodev rédige…</span>
    </div>
  );
}

window.ScreenChatSpec = ScreenChatSpec;
