/* eslint-disable */
const { React, ReactDOM } = window;

/* Sample data for Autodev mockups */

const SAMPLE_PROJECTS = [
  { slug: "powerpanne/api",       label: "Powerpanne · API",        active: 4, total: 47, error: 0, color: "#5E47E8" },
  { slug: "powerpanne/web",       label: "Powerpanne · Web",        active: 2, total: 31, error: 1, color: "#2A6FDB" },
  { slug: "modulotech/billing",   label: "Modulotech · Facturation",active: 1, total: 18, error: 0, color: "#1F8A7E" },
  { slug: "modulotech/crm",       label: "Modulotech · CRM",        active: 0, total: 22, error: 1, color: "#B57A12" },
];

const SAMPLE_ISSUES = [
  { id: 1, iid: 412, project: "powerpanne/web", projectLabel: "Powerpanne · Web",
    title: "Le bouton « Valider » de la page facture renvoie une erreur 500",
    status: "implementing", branch: "412-fix-invoice-validate", mr: null,
    requester: "Marine Petit", waitingSince: "il y a 4 min", priority: "Urgent",
    lastActivity: "Autodev a écrit 3 fichiers (app/controllers/invoices_controller.rb, …)" },
  { id: 2, iid: 411, project: "powerpanne/api", projectLabel: "Powerpanne · API",
    title: "Ajouter un export CSV des interventions filtrées par technicien",
    status: "checking_pipeline", branch: "411-csv-export", mr: 318,
    requester: "Karim Bensalem", waitingSince: "il y a 12 min", priority: "Normal",
    lastActivity: "Vérifications automatiques en cours (3/5 OK)" },
  { id: 3, iid: 410, project: "powerpanne/web", projectLabel: "Powerpanne · Web",
    title: "Remettre l'avatar utilisateur dans le menu en haut à droite",
    status: "needs_clarification", branch: "410-avatar-menu", mr: null,
    requester: "Sophie Lambert", waitingSince: "il y a 2 h", priority: "Normal",
    lastActivity: "Autodev a une question sur l'emplacement souhaité" },
  { id: 4, iid: 409, project: "modulotech/billing", projectLabel: "Modulotech · Facturation",
    title: "Empêcher la double saisie d'un même numéro de TVA",
    status: "fixing_discussions", branch: "409-vat-unique", mr: 317,
    requester: "Lucas Moreau", waitingSince: "il y a 35 min", priority: "Normal",
    lastActivity: "2 commentaires de revue à traiter" },
  { id: 5, iid: 408, project: "powerpanne/api", projectLabel: "Powerpanne · API",
    title: "Mettre à jour le webhook GitLab vers le nouveau secret",
    status: "done", branch: "408-webhook-secret", mr: 316,
    requester: "Marine Petit", waitingSince: "terminé hier 17:42", priority: "Normal",
    lastActivity: "Livré et déployé" },
  { id: 6, iid: 407, project: "modulotech/crm", projectLabel: "Modulotech · CRM",
    title: "La recherche par email plante quand l'adresse contient un +",
    status: "error", branch: "407-search-plus", mr: null,
    requester: "Karim Bensalem", waitingSince: "il y a 1 h", priority: "Urgent",
    lastActivity: "Échec : impossible de cloner le dépôt (timeout)" },
  { id: 7, iid: 406, project: "powerpanne/web", projectLabel: "Powerpanne · Web",
    title: "Préremplir le pays « France » dans le formulaire d'inscription",
    status: "creating_mr", branch: "406-default-country", mr: null,
    requester: "Sophie Lambert", waitingSince: "il y a 6 min", priority: "Normal",
    lastActivity: "Création de la demande de fusion sur GitLab" },
  { id: 8, iid: 405, project: "powerpanne/api", projectLabel: "Powerpanne · API",
    title: "Augmenter le timeout de l'API SMS à 30 secondes",
    status: "pending", branch: "—", mr: null,
    requester: "Lucas Moreau", waitingSince: "il y a 18 min", priority: "Normal",
    lastActivity: "En attente d'un développeur disponible" },
];

const SAMPLE_TIMELINE = [
  { at: "10:42:14", kind: "transition", title: "Demande reçue", detail: "Issue #412 attribuée à Autodev par Marine Petit." },
];

Object.assign(window, { SAMPLE_PROJECTS, SAMPLE_ISSUES, SAMPLE_TIMELINE });
