# SPDX-License-Identifier: AGPL-3.0-or-later

# Manifeste de l'extension des formulaires (ADR-003 D2).
#
# * Aucune dépendance (D-FRM-002) : une réponse aboutit au mieux à une
#   *fiche*, créée par `Partiduo::Api::Cards.create_card` avec l'acteur qui
#   traite la réponse ; les fiches et les pièces jointes sont du socle,
#   toujours actif. Aucune écriture comptable n'est jamais produite, et le
#   suivi n'est pas requis.
# * Aucune incompatibilité (D-FRM-003) : un dossier foyer peut recueillir
#   des coordonnées (association de quartier, copropriété informelle) ;
#   rien n'y entre sans être traité.
# * Permissions (D4, D-FRM-012) : `form.read` (boîte de réception,
#   définitions et liens en lecture), `form.process` (traiter une réponse :
#   accepter en fiche, classer, rejeter, télécharger une pièce reçue),
#   `form.design` (définir formulaires et champs), `form.admin` (émettre et
#   révoquer les liens publics, effacer une réponse ou un formulaire,
#   purger). Le contrat du cœur exige en plus ses propres droits :
#   `cards.card.write` pour créer la fiche, `cards.card.read` pour
#   rattacher des champs à une catégorie, `core.attachment.write` pour
#   verser une pièce reçue au dossier.
# * Menu : rubrique « Formulaires » (boîte de réception, définitions).
# * Aucun abonnement, aucun événement nouveau (D-FRM-013).
Partiduo::Modules.register do
  code "FORM"
  name "form.module.name"
  version Forms::VERSION
  requires_core "~> 0.1"

  permission "form.read"
  permission "form.process"
  permission "form.design"
  permission "form.admin"

  menu "FORM", order: 85, permission: "form.read"
  menu "FORM_INBOX", parent: "FORM", order: 10, route: "form:inbox", permission: "form.read"
  menu "FORM_DEFINITIONS", parent: "FORM", order: 20, route: "form:forms", permission: "form.read"

  ui "bulma", path: "ui/bulma"
end
