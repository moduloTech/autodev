// New-draft ticket-template picker (task #14).
//
// The new-draft form (/autospec_drafts/new) lets the CSM pick a project and,
// optionally, one of that project's ticket templates. Templates are
// per-project, so this script repopulates the template <select> whenever the
// project changes, and fills the markdown textarea with the chosen template's
// body. The server applies the same body as a fallback when JS is off
// (AutospecDraftsController#initial_markdown), so this is purely a nicer UX.
(function () {
  'use strict';

  var dataEl = document.getElementById('autospec-templates-data');
  if (!dataEl) return;

  var byProject = {};
  try {
    byProject = JSON.parse(dataEl.textContent || '{}');
  } catch (e) {
    return;
  }

  var projectSel = document.querySelector('[data-autospec-project-select]');
  var fieldWrap = document.querySelector('[data-autospec-template-field]');
  var templateSel = document.querySelector('[data-autospec-template-select]');
  var markdown = document.querySelector('[data-autospec-markdown]');
  if (!projectSel || !fieldWrap || !templateSel) return;

  function templatesFor(projectId) {
    return byProject[projectId] || [];
  }

  // Rebuild the template options for the selected project. The first
  // <option> ("none") is kept; the rest are replaced. Hide the whole field
  // when the project defines no templates.
  function repopulate() {
    var list = templatesFor(projectSel.value);
    templateSel.length = 1;
    list.forEach(function (t) {
      var opt = document.createElement('option');
      opt.value = t.slug;
      opt.textContent = t.name;
      templateSel.appendChild(opt);
    });
    fieldWrap.style.display = list.length ? '' : 'none';
    templateSel.value = '';
  }

  // Fill the markdown textarea with the chosen template's body. Confirm
  // before clobbering content the CSM already typed.
  function applyTemplate() {
    var list = templatesFor(projectSel.value);
    var chosen = list.filter(function (t) {
      return t.slug === templateSel.value;
    })[0];
    if (!chosen || !markdown) return;

    var hasContent = markdown.value.trim().length > 0;
    var prompt = markdown.dataset.confirmOverwrite || 'Replace the current content?';
    if (hasContent && !window.confirm(prompt)) return;

    markdown.value = chosen.body;
  }

  projectSel.addEventListener('change', repopulate);
  templateSel.addEventListener('change', applyTemplate);
  repopulate();
})();
