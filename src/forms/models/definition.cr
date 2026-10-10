# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  # Formulaire (D-FRM-004) : titre et présentation publics, finalité du
  # traitement et responsable (affichés sur la page publique, RGPD),
  # durée de conservation des réponses en jours, catégorie de fiches visée
  # (facultative, identifiant relu par le contrat du cœur), pièces jointes
  # admises ou non, message de remerciement, état (un formulaire désactivé
  # ne répond plus sur aucun de ses liens). Interne.
  class Definition < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :title, :string, max_size: 120
    field :description, :text, blank: true, default: ""
    field :purpose, :text
    field :controller, :string, max_size: 300
    field :retention_days, :int, default: 90
    field :success_message, :text, blank: true, default: ""
    field :category_id, :big_int, blank: true, null: true
    field :accepts_files, :bool, default: false
    field :max_files, :int, default: 1
    field :enabled, :bool, default: true
    field :created_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end
end
