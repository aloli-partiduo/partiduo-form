# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  # Pièce jointe reçue avec une réponse, en quarantaine (D-FRM-009) :
  # contenu en base64 dans la table de l'extension, jamais servi tel quel
  # au public, effacé avec la réponse. Versée au dossier par
  # `Partiduo::Api::Core.store_attachment` quand un utilisateur
  # authentifié accepte la réponse (`attachment_id`). Interne.
  class Upload < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :response_id, :big_int, index: true
    field :filename, :string, max_size: 255
    field :content_type, :string, max_size: 64
    field :byte_size, :int
    field :sha256, :string, max_size: 64
    field :content, :text, blank: true, default: ""
    field :attachment_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end
end
