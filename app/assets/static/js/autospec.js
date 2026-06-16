// AutoSpec editor — toggle Édition/Aperçu, format buttons, ⌘ shortcuts,
// debounced autosave (PATCH /autospec_drafts/:id) with localStorage
// backup keyed `autodev:draft:<id>`, and inline meta-chip editing.
//
// Loaded via <script src="/assets/js/autospec.js" defer> from
// Web::Views::AutospecDrafts::Show. No-op when the workspace element
// is absent (any other page).
//
// Step 10b of the AutoSpec phase — see autodev/docs/autospec-handoff.md §3.

(function () {
  'use strict';

  const AUTOSAVE_DEBOUNCE_MS = 2000;
  const LS_PREFIX = 'autodev:draft:';

  document.addEventListener('DOMContentLoaded', init);

  function init() {
    const workspace = document.querySelector('[data-autospec-draft-id]');
    if (!workspace) return;

    const draftId = workspace.getAttribute('data-autospec-draft-id');
    const locked = workspace.getAttribute('data-autospec-locked') === 'true';
    const indicator = workspace.querySelector('[data-autospec-save-indicator]');
    const textarea = workspace.querySelector('[data-autospec-field="markdown"]');
    const titleInput = workspace.querySelector('[data-autospec-field="title"]');
    const previewPane = workspace.querySelector('[data-autospec-pane="preview"]');
    const previewBody = workspace.querySelector('[data-autospec-preview]');
    const editPane = workspace.querySelector('[data-autospec-pane="edit"]');
    const ctx = {
      draftId, locked, indicator, textarea, titleInput,
      previewPane, previewBody, editPane,
      pending: {}, saveTimer: null,
    };

    restoreFromLocalStorage(ctx);
    wireTabs(workspace, ctx);
    wireFormatButtons(workspace, ctx);
    wireShortcuts(ctx);
    wireAutosave(ctx);
    wireMetaChips(workspace, ctx);
    wireAttachments(workspace, ctx);
    wireMobileTabs(workspace);
  }

  // ── Mobile tabs (Édition | Discussion, ≤960 px) ───────────────

  function wireMobileTabs(workspace) {
    const tabs = workspace.querySelectorAll('[data-autospec-mobile-tab]');
    tabs.forEach((tab) => {
      tab.addEventListener('click', () => {
        const key = tab.getAttribute('data-autospec-mobile-tab');
        workspace.setAttribute('data-autospec-active-tab', key);
        tabs.forEach((t) => t.setAttribute('aria-selected', t === tab ? 'true' : 'false'));
      });
    });
  }

  // ── Tab toggle ─────────────────────────────────────────────────

  function wireTabs(workspace, ctx) {
    const tabs = workspace.querySelectorAll('[data-autospec-tab]');
    tabs.forEach(tab => {
      tab.addEventListener('click', () => activateTab(tab, tabs, ctx));
    });
  }

  function activateTab(tab, tabs, ctx) {
    const mode = tab.getAttribute('data-autospec-tab');
    tabs.forEach(t => t.setAttribute('aria-selected', t === tab ? 'true' : 'false'));
    if (mode === 'preview') {
      // Flush pending edits before switching so the preview matches
      // exactly what the server has — avoids the "I just typed but
      // preview shows the old text" surprise.
      flushSave(ctx, () => togglePane(ctx, 'preview'));
    } else {
      togglePane(ctx, 'edit');
      ctx.textarea && ctx.textarea.focus();
    }
  }

  function togglePane(ctx, mode) {
    if (!ctx.editPane || !ctx.previewPane) return;
    ctx.editPane.hidden = mode !== 'edit';
    ctx.previewPane.hidden = mode !== 'preview';
  }

  // ── Format buttons ─────────────────────────────────────────────

  function wireFormatButtons(workspace, ctx) {
    workspace.querySelectorAll('[data-autospec-format]').forEach(btn => {
      btn.addEventListener('click', () => applyFormat(ctx, btn.getAttribute('data-autospec-format')));
    });
  }

  function applyFormat(ctx, kind) {
    if (!ctx.textarea || ctx.textarea.disabled) return;
    const ta = ctx.textarea;
    const start = ta.selectionStart;
    const end = ta.selectionEnd;
    const selected = ta.value.slice(start, end);
    const wrap = (open, close) => {
      ta.value = ta.value.slice(0, start) + open + selected + close + ta.value.slice(end);
      ta.selectionStart = start + open.length;
      ta.selectionEnd = end + open.length;
    };
    const prefixLine = (prefix) => {
      const before = ta.value.slice(0, start);
      const lineStart = before.lastIndexOf('\n') + 1;
      ta.value = ta.value.slice(0, lineStart) + prefix + ta.value.slice(lineStart);
      ta.selectionStart = ta.selectionEnd = end + prefix.length;
    };

    switch (kind) {
      case 'bold':    wrap('**', '**'); break;
      case 'italic':  wrap('_', '_');   break;
      case 'code':    wrap('`', '`');   break;
      case 'heading': prefixLine('## '); break;
      case 'list':    prefixLine('- '); break;
      case 'quote':   prefixLine('> '); break;
      case 'link': {
        const text = selected || 'libellé';
        const replacement = '[' + text + '](https://)';
        ta.value = ta.value.slice(0, start) + replacement + ta.value.slice(end);
        ta.selectionStart = start + replacement.length - 9;  // place caret on https://
        ta.selectionEnd = start + replacement.length - 1;
        break;
      }
      default: return;
    }
    ta.focus();
    queueSave(ctx);
  }

  // ── Keyboard shortcuts ─────────────────────────────────────────

  function wireShortcuts(ctx) {
    if (!ctx.textarea) return;
    ctx.textarea.addEventListener('keydown', (e) => {
      const mod = e.metaKey || e.ctrlKey;
      if (!mod) return;
      switch (e.key.toLowerCase()) {
        case 'b': e.preventDefault(); applyFormat(ctx, 'bold'); break;
        case 'i': e.preventDefault(); applyFormat(ctx, 'italic'); break;
        case 'k': e.preventDefault(); applyFormat(ctx, 'link'); break;
        case 'enter': e.preventDefault(); flushSave(ctx); break;
      }
    });
  }

  // ── Autosave ───────────────────────────────────────────────────

  function wireAutosave(ctx) {
    if (ctx.textarea && !ctx.textarea.disabled) {
      ctx.textarea.addEventListener('input', () => {
        ctx.pending.markdown = ctx.textarea.value;
        writeLocalStorage(ctx, 'markdown', ctx.textarea.value);
        queueSave(ctx);
      });
    }
    if (ctx.titleInput && !ctx.titleInput.disabled) {
      ctx.titleInput.addEventListener('input', () => {
        ctx.pending.title = ctx.titleInput.value;
        writeLocalStorage(ctx, 'title', ctx.titleInput.value);
        queueSave(ctx);
      });
    }
  }

  function queueSave(ctx) {
    if (ctx.locked) return;
    setIndicator(ctx, 'saving');
    if (ctx.saveTimer) clearTimeout(ctx.saveTimer);
    ctx.saveTimer = setTimeout(() => flushSave(ctx), AUTOSAVE_DEBOUNCE_MS);
  }

  function flushSave(ctx, cb) {
    if (ctx.saveTimer) { clearTimeout(ctx.saveTimer); ctx.saveTimer = null; }
    if (Object.keys(ctx.pending).length === 0) { if (cb) cb(); return; }
    const body = ctx.pending;
    ctx.pending = {};
    patchDraft(ctx, body).then(json => {
      setIndicator(ctx, 'idle');
      if (json && json.draft && ctx.previewBody) {
        ctx.previewBody.innerHTML = json.draft.preview_html || '';
      }
      clearLocalStorage(ctx);
      if (cb) cb();
    }).catch(err => {
      // Re-queue the failed body so a subsequent edit (or retry)
      // doesn't drop the changes. The next queueSave merges on top.
      Object.assign(ctx.pending, body, ctx.pending);
      setIndicator(ctx, err && err.locked ? 'locked' : 'error');
      if (err && err.locked) {
        ctx.locked = true;
        if (ctx.textarea) ctx.textarea.disabled = true;
        if (ctx.titleInput) ctx.titleInput.disabled = true;
      }
      if (cb) cb();
    });
  }

  function patchDraft(ctx, body) {
    const url = '/autospec_drafts/' + ctx.draftId;
    const tokenMeta = document.querySelector('meta[name="csrf-token"]');
    const token = tokenMeta ? tokenMeta.getAttribute('content') : '';
    return fetch(url, {
      method: 'PATCH',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-Token': token,
      },
      credentials: 'same-origin',
      body: JSON.stringify(body),
    }).then(r => {
      if (r.status === 409) {
        return r.json().then(j => { const e = new Error('locked'); e.locked = true; e.payload = j; throw e; });
      }
      if (!r.ok) throw new Error('http_' + r.status);
      return r.json();
    });
  }

  function setIndicator(ctx, state) {
    if (!ctx.indicator) return;
    ctx.indicator.setAttribute('data-state', state);
    const label = ctx.indicator.querySelector('[data-autospec-save-label]');
    if (label) label.textContent = labelForState(label, state);
  }

  // The element starts populated server-side with the FR/EN string for
  // the initial state ("Enregistré" / "Saved" or "Brouillon verrouillé"
  // / "Draft locked"). To switch languages without round-tripping the
  // server we read sibling labels from a JSON map written by the view —
  // but at the MVP the user's locale doesn't change mid-page, so we
  // build the alternate labels from the initial one by mapping
  // language-pair-by-pair. Cheap, no dependency, good enough.
  function labelForState(el, state) {
    const dict = el._dict || (el._dict = buildLabelDict(el.textContent.trim()));
    return dict[state] || dict.idle;
  }

  function buildLabelDict(initial) {
    // Heuristic: if the initial label is the French "Enregistré" or
    // "Brouillon verrouillé", use FR variants; otherwise EN.
    const fr = /Enregistré|Brouillon/i.test(initial);
    return fr
      ? { idle: 'Enregistré', saving: 'Enregistrement…', error: 'Échec de l’enregistrement', locked: 'Brouillon verrouillé' }
      : { idle: 'Saved',      saving: 'Saving…',         error: 'Save failed',                    locked: 'Draft locked' };
  }

  // ── Meta chips ────────────────────────────────────────────────

  function wireMetaChips(workspace, ctx) {
    if (ctx.locked) return;
    workspace.querySelectorAll('[data-autospec-chip]').forEach(chip => {
      chip.addEventListener('click', (e) => {
        if (e.target.closest('[data-autospec-chip-edit]')) return;  // ignore clicks inside the editor
        openChipEditor(chip, ctx);
      });
    });
  }

  function openChipEditor(chip, ctx) {
    const key = chip.getAttribute('data-autospec-chip');
    const valueEl = chip.querySelector('[data-autospec-chip-value]');
    if (!valueEl || chip.querySelector('[data-autospec-chip-edit]')) return;

    const optionsStr = chip.getAttribute('data-autospec-chip-options') || '';
    const options = optionsStr ? optionsStr.split(',').map(s => s.trim()).filter(Boolean) : null;
    const current = currentChipValue(chip, key);
    const editor = options ? buildSelect(options, current) : buildInput(key, current);
    editor.setAttribute('data-autospec-chip-edit', 'true');

    valueEl.style.display = 'none';
    chip.appendChild(editor);
    editor.focus();
    if (editor.select) editor.select();

    const commit = () => {
      const newValue = editor.value;
      const payload = buildChipPayload(ctx, key, newValue);
      ctx.pending.meta_chips = payload;
      writeLocalStorage(ctx, 'meta_chips', JSON.stringify(payload));
      valueEl.textContent = renderChipValue(key, newValue);
      valueEl.style.display = '';
      editor.remove();
      flushSave(ctx);
    };
    editor.addEventListener('change', commit);
    editor.addEventListener('blur', commit);
    editor.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') { e.preventDefault(); commit(); }
      else if (e.key === 'Escape') { valueEl.style.display = ''; editor.remove(); }
    });
  }

  function currentChipValue(chip, key) {
    const valueEl = chip.querySelector('[data-autospec-chip-value]');
    const text = valueEl ? valueEl.textContent.trim() : '';
    if (text === '—' || text === '') return '';
    if (key === 'tags') return text.replace(/#/g, '').replace(/\s+/g, ', ');
    return text;
  }

  function buildSelect(options, current) {
    const select = document.createElement('select');
    select.className = 'autospec-chip-edit';
    const empty = document.createElement('option');
    empty.value = '';
    empty.textContent = '—';
    select.appendChild(empty);
    options.forEach(opt => {
      const o = document.createElement('option');
      o.value = opt;
      o.textContent = opt;
      if (opt === current) o.selected = true;
      select.appendChild(o);
    });
    return select;
  }

  function buildInput(key, current) {
    const input = document.createElement('input');
    input.type = 'text';
    input.className = 'autospec-chip-edit';
    input.value = current;
    if (key === 'tags') input.placeholder = 'frontend, ux, …';
    return input;
  }

  function buildChipPayload(ctx, key, value) {
    // Merge with the existing pending meta_chips so two consecutive
    // chip edits before a flush both persist.
    const existing = ctx.pending.meta_chips || {};
    const next = Object.assign({}, existing);
    if (key === 'tags') {
      next.tags = value.split(',').map(s => s.trim()).filter(Boolean);
    } else {
      next[key] = value;
    }
    return next;
  }

  function renderChipValue(key, value) {
    if (!value) return '—';
    if (key === 'tags') {
      const tags = value.split(',').map(s => s.trim()).filter(Boolean);
      return tags.length ? tags.map(t => '#' + t).join(' ') : '—';
    }
    return value;
  }

  // ── localStorage backup ───────────────────────────────────────

  function lsKey(ctx, field) { return LS_PREFIX + ctx.draftId + ':' + field; }

  function writeLocalStorage(ctx, field, value) {
    try { localStorage.setItem(lsKey(ctx, field), value); } catch (_) {}
  }

  function clearLocalStorage(ctx) {
    try {
      ['markdown', 'title', 'meta_chips'].forEach(f => localStorage.removeItem(lsKey(ctx, f)));
    } catch (_) {}
  }

  // ── Attachments (step 10c) ────────────────────────────────────

  function wireAttachments(workspace, ctx) {
    if (ctx.locked) return;
    const col = workspace.querySelector('[data-autospec-editor-col]');
    const overlay = workspace.querySelector('[data-autospec-dropzone-overlay]');
    const grid = workspace.querySelector('[data-autospec-attachments-grid]');
    if (!col || !grid) return;

    wireDropzone(col, overlay, (files) => uploadFiles(ctx, grid, files));
    wireAttachmentActions(workspace, ctx, grid);
    wireDropTargetClick(workspace, ctx, grid);
  }

  function wireDropzone(col, overlay, onFiles) {
    let depth = 0;  // dragenter/leave fire per descendant — count to find the real boundary.
    col.addEventListener('dragenter', (e) => {
      if (!hasFiles(e)) return;
      e.preventDefault();
      depth += 1;
      if (overlay) overlay.setAttribute('data-active', 'true');
    });
    col.addEventListener('dragover', (e) => {
      if (!hasFiles(e)) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = 'copy';
    });
    col.addEventListener('dragleave', () => {
      depth -= 1;
      if (depth <= 0) { depth = 0; if (overlay) overlay.setAttribute('data-active', 'false'); }
    });
    col.addEventListener('drop', (e) => {
      if (!hasFiles(e)) return;
      e.preventDefault();
      depth = 0;
      if (overlay) overlay.setAttribute('data-active', 'false');
      const files = Array.from(e.dataTransfer.files || []);
      if (files.length) onFiles(files);
    });
  }

  function hasFiles(e) {
    if (!e.dataTransfer || !e.dataTransfer.types) return false;
    return Array.from(e.dataTransfer.types).includes('Files');
  }

  function wireDropTargetClick(workspace, ctx, grid) {
    const target = workspace.querySelector('[data-autospec-drop-target]');
    if (!target) return;
    target.style.cursor = 'pointer';
    target.addEventListener('click', () => {
      const input = document.createElement('input');
      input.type = 'file';
      input.accept = 'image/png,image/jpeg,image/gif,image/webp';
      input.multiple = true;
      input.addEventListener('change', () => {
        const files = Array.from(input.files || []);
        if (files.length) uploadFiles(ctx, grid, files);
      });
      input.click();
    });
  }

  function wireAttachmentActions(workspace, ctx, grid) {
    // Event delegation so cards added dynamically (after upload) are
    // wired too without re-binding.
    grid.addEventListener('click', (e) => {
      const del = e.target.closest('[data-autospec-attachment-delete]');
      const cpy = e.target.closest('[data-autospec-attachment-copy]');
      if (del) {
        const card = del.closest('[data-autospec-attachment-id]');
        if (card) deleteAttachment(ctx, card);
      } else if (cpy) {
        const card = cpy.closest('[data-autospec-attachment-id]');
        if (card) copyMarkdownSnippet(card, cpy);
      }
    });
  }

  function uploadFiles(ctx, grid, files) {
    files.forEach((file) => uploadOne(ctx, grid, file));
  }

  function uploadOne(ctx, grid, file) {
    const formData = new FormData();
    formData.append('file', file);
    const url = '/autospec_drafts/' + ctx.draftId + '/autospec_attachments';
    const token = csrfToken();

    fetch(url, {
      method: 'POST',
      headers: { 'Accept': 'application/json', 'X-CSRF-Token': token },
      credentials: 'same-origin',
      body: formData,
    }).then(r => {
      if (!r.ok) throw new Error('http_' + r.status);
      return r.json();
    }).then(json => {
      if (json && json.attachment) appendAttachmentCard(grid, json.attachment);
    }).catch(() => {
      // Surface failures via the save indicator's error state — the
      // user already understands what that dot means. Markdown editor
      // stays usable; the file just didn't make it.
      setIndicator(ctx, 'error');
    });
  }

  function appendAttachmentCard(grid, attachment) {
    const card = document.createElement('div');
    card.className = 'autospec-attachment-card';
    card.setAttribute('data-autospec-attachment-id', String(attachment.id));
    card.setAttribute('data-autospec-attachment-markdown', attachment.markdown_snippet || '');

    const preview = document.createElement('div');
    preview.className = 'autospec-attachment-preview';
    const img = document.createElement('img');
    img.src = attachment.url;
    img.alt = attachment.filename;
    img.loading = 'lazy';
    preview.appendChild(img);

    const del = document.createElement('button');
    del.type = 'button';
    del.className = 'autospec-attachment-delete';
    del.setAttribute('data-autospec-attachment-delete', 'true');
    del.textContent = '✕';

    const footer = document.createElement('div');
    footer.className = 'autospec-attachment-footer';
    const name = document.createElement('div');
    name.className = 'autospec-attachment-filename';
    name.title = attachment.filename;
    name.textContent = attachment.filename;
    const meta = document.createElement('div');
    meta.className = 'autospec-attachment-meta';
    meta.textContent = humanSize(attachment.byte_size);
    const copy = document.createElement('button');
    copy.type = 'button';
    copy.className = 'autospec-attachment-copy';
    copy.setAttribute('data-autospec-attachment-copy', 'true');
    copy.textContent = '⧉';
    meta.appendChild(copy);
    footer.appendChild(name);
    footer.appendChild(meta);

    card.appendChild(preview);
    card.appendChild(del);
    card.appendChild(footer);

    // Insert before the perpetual drop-target slot so it stays last.
    const dropTarget = grid.querySelector('[data-autospec-drop-target]');
    grid.insertBefore(card, dropTarget);
  }

  function deleteAttachment(ctx, card) {
    const id = card.getAttribute('data-autospec-attachment-id');
    const url = '/autospec_drafts/' + ctx.draftId + '/autospec_attachments/' + id;
    fetch(url, {
      method: 'DELETE',
      headers: { 'Accept': 'application/json', 'X-CSRF-Token': csrfToken() },
      credentials: 'same-origin',
    }).then(r => {
      if (r.status === 204 || r.ok) card.remove();
      else setIndicator(ctx, 'error');
    }).catch(() => setIndicator(ctx, 'error'));
  }

  function copyMarkdownSnippet(card, button) {
    const md = card.getAttribute('data-autospec-attachment-markdown') || '';
    const writer = navigator.clipboard && navigator.clipboard.writeText
      ? navigator.clipboard.writeText(md)
      : Promise.reject(new Error('clipboard_unavailable'));
    writer.then(() => {
      button.setAttribute('data-state', 'copied');
      setTimeout(() => button.removeAttribute('data-state'), 1200);
    }).catch(() => { /* swallow — the user can re-try */ });
  }

  function csrfToken() {
    const meta = document.querySelector('meta[name="csrf-token"]');
    return meta ? meta.getAttribute('content') : '';
  }

  function humanSize(bytes) {
    if (!bytes && bytes !== 0) return '';
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1048576) return (bytes / 1024).toFixed(1) + ' KB';
    return (bytes / 1048576).toFixed(1) + ' MB';
  }

  // On load: if localStorage holds a different value than what's in
  // the input (which reflects the last server save), the user likely
  // had unsaved keystrokes when they closed the tab. Restore them.
  // Then immediately queue a save so the server catches up.
  function restoreFromLocalStorage(ctx) {
    try {
      if (ctx.textarea) {
        const md = localStorage.getItem(lsKey(ctx, 'markdown'));
        if (md !== null && md !== ctx.textarea.value) {
          ctx.textarea.value = md;
          ctx.pending.markdown = md;
        }
      }
      if (ctx.titleInput) {
        const t = localStorage.getItem(lsKey(ctx, 'title'));
        if (t !== null && t !== ctx.titleInput.value) {
          ctx.titleInput.value = t;
          ctx.pending.title = t;
        }
      }
      if (Object.keys(ctx.pending).length > 0) queueSave(ctx);
    } catch (_) {}
  }
})();
