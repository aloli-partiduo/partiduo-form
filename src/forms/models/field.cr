# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  # Champ d'un formulaire (D-FRM-005) : clé (nom du paramètre envoyé),
  # libellé, nature (`Api::FIELD_KINDS`), obligatoire ou non, longueur
  # maximale, choix d'une liste (une valeur par ligne), aide, et cible
  # facultative dans la fiche (`Api::CARD_TARGETS` ou `extra.<attribut>`),
  # qui ne sert qu'à préremplir la fiche proposée au traitement. Interne.
  class Field < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :definition_id, :big_int, index: true
    field :position, :int, default: 0
    field :key, :string, max_size: 40
    field :label, :string, max_size: 200
    field :kind, :string, max_size: 12, default: "text"
    field :required, :bool, default: false
    field :max_length, :int, blank: true, null: true
    field :choices, :text, blank: true, default: ""
    field :help, :string, max_size: 300, blank: true, default: ""
    field :target, :string, max_size: 80, blank: true, default: ""

    with_timestamp_fields
  end
end
