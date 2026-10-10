# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  # Lien public d'un formulaire (D-FRM-006). Le jeton n'est jamais
  # conservé : seule son empreinte SHA-256 l'est (`token_digest`), avec ses
  # quatre premiers caractères pour le reconnaître (`token_hint`). Un lien
  # expire (`expires_at`), se révoque (`revoked_at`) et n'accepte qu'un
  # nombre borné d'envois (`max_uses`, 1 pour un usage unique ; `uses`
  # compte les envois acceptés). Interne.
  class Link < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :definition_id, :big_int, index: true
    field :label, :string, max_size: 120, blank: true, default: ""
    field :token_digest, :string, max_size: 64, unique: true
    field :token_hint, :string, max_size: 8
    field :expires_at, :date_time
    field :max_uses, :int, default: 1
    field :uses, :int, default: 0
    field :last_used_at, :date_time, blank: true, null: true
    field :revoked_at, :date_time, blank: true, null: true
    field :revoked_by_id, :big_int, blank: true, null: true
    field :created_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end
end
