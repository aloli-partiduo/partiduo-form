# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  # Réponse reçue par un lien public (D-FRM-008). `data` : copie figée des
  # champs à la réception (clé, libellé, nature, valeur), pour qu'une
  # modification ultérieure du formulaire ne change pas ce qui a été reçu.
  # `status` : `received` (à traiter), `accepted` (fiche créée,
  # `card_id`), `closed` (traitée sans fiche), `rejected` (refusée).
  # `purge_after` : échéance de la conservation (D-FRM-011). Aucune
  # adresse IP ni empreinte de navigateur n'est conservée. Interne.
  class Response < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :definition_id, :big_int, index: true
    field :link_id, :big_int, blank: true, null: true, index: true
    field :status, :string, max_size: 10, default: "received"
    field :data, :json
    field :received_at, :date_time
    field :purge_after, :date_time, index: true
    field :processed_by_id, :big_int, blank: true, null: true
    field :processed_at, :date_time, blank: true, null: true
    field :card_id, :big_int, blank: true, null: true
    field :note, :text, blank: true, default: ""

    with_timestamp_fields
  end
end
