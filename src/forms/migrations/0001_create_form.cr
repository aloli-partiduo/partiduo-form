# SPDX-License-Identifier: AGPL-3.0-or-later

# Tables de l'extension des formulaires : définitions, champs, liens
# publics, réponses et pièces reçues en quarantaine.
#
# Intégrité en base : natures, statuts et types de fichiers contrôlés ;
# durée de conservation de 1 à 1 095 jours ; clé de champ unique dans un
# formulaire ; empreinte de jeton en hexadécimal (jamais le jeton) et
# unique ; nombre d'envois d'un lien borné et jamais dépassé ; réponse
# traitée datée, réponse acceptée liée à sa fiche ; taille d'une pièce
# bornée. Champs, liens, réponses et pièces suivent leur formulaire à
# l'effacement ; une réponse garde son contenu si son lien disparaît. Les
# liens vers le cœur (catégorie, fiche, pièce jointe) sont des
# identifiants relus par le contrat, sans clé étrangère, comme dans les
# autres extensions ; les auteurs (`*_by_id`) en ont une vers `auth_user`.
class Migration::Forms::V0001 < Marten::Migration
  depends_on :auth, "0001_create_auth_user_table"

  CONSTRAINTS = [
    {<<-SQL, "SELECT 1"},
      ALTER TABLE form_definition
        ADD CONSTRAINT form_definition_title_check CHECK (btrim(title) <> ''),
        ADD CONSTRAINT form_definition_purpose_check CHECK (btrim(purpose) <> ''),
        ADD CONSTRAINT form_definition_controller_check CHECK (btrim(controller) <> ''),
        ADD CONSTRAINT form_definition_retention_check CHECK (retention_days BETWEEN 1 AND 1095),
        ADD CONSTRAINT form_definition_max_files_check CHECK (max_files BETWEEN 1 AND 3),
        ADD CONSTRAINT form_definition_created_by_fk FOREIGN KEY (created_by_id) REFERENCES auth_user (id)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE form_field
        ADD CONSTRAINT form_field_key_check CHECK (key ~ '^[a-z][a-z0-9_]{0,39}$'),
        ADD CONSTRAINT form_field_kind_check CHECK (kind IN ('text', 'textarea', 'email', 'phone', 'number', 'date',
          'checkbox', 'select')),
        ADD CONSTRAINT form_field_label_check CHECK (btrim(label) <> ''),
        ADD CONSTRAINT form_field_max_length_check CHECK (max_length IS NULL OR max_length BETWEEN 1 AND 5000),
        ADD CONSTRAINT form_field_select_check CHECK (kind <> 'select' OR btrim(choices) <> ''),
        ADD CONSTRAINT form_field_definition_fk FOREIGN KEY (definition_id) REFERENCES form_definition (id)
          ON DELETE CASCADE
      SQL
    {"CREATE UNIQUE INDEX form_field_key_unique ON form_field (definition_id, key)",
     "DROP INDEX IF EXISTS form_field_key_unique"},
    {<<-SQL, "SELECT 1"},
      ALTER TABLE form_link
        ADD CONSTRAINT form_link_digest_check CHECK (token_digest ~ '^[0-9a-f]{64}$'),
        ADD CONSTRAINT form_link_uses_check CHECK (max_uses BETWEEN 1 AND 10000 AND uses BETWEEN 0 AND max_uses),
        ADD CONSTRAINT form_link_revoked_check CHECK ((revoked_at IS NULL) = (revoked_by_id IS NULL)),
        ADD CONSTRAINT form_link_definition_fk FOREIGN KEY (definition_id) REFERENCES form_definition (id)
          ON DELETE CASCADE,
        ADD CONSTRAINT form_link_created_by_fk FOREIGN KEY (created_by_id) REFERENCES auth_user (id),
        ADD CONSTRAINT form_link_revoked_by_fk FOREIGN KEY (revoked_by_id) REFERENCES auth_user (id)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE form_response
        ADD CONSTRAINT form_response_status_check CHECK (status IN ('received', 'accepted', 'closed', 'rejected')),
        ADD CONSTRAINT form_response_processed_check CHECK ((status = 'received') = (processed_at IS NULL)),
        ADD CONSTRAINT form_response_card_check CHECK ((status = 'accepted') = (card_id IS NOT NULL)),
        ADD CONSTRAINT form_response_purge_check CHECK (purge_after > received_at),
        ADD CONSTRAINT form_response_definition_fk FOREIGN KEY (definition_id) REFERENCES form_definition (id)
          ON DELETE CASCADE,
        ADD CONSTRAINT form_response_link_fk FOREIGN KEY (link_id) REFERENCES form_link (id) ON DELETE SET NULL,
        ADD CONSTRAINT form_response_processed_by_fk FOREIGN KEY (processed_by_id) REFERENCES auth_user (id)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE form_upload
        ADD CONSTRAINT form_upload_type_check CHECK (content_type IN ('application/pdf', 'image/png', 'image/jpeg')),
        ADD CONSTRAINT form_upload_size_check CHECK (byte_size BETWEEN 1 AND 1048576),
        ADD CONSTRAINT form_upload_sha256_check CHECK (sha256 ~ '^[0-9a-f]{64}$'),
        ADD CONSTRAINT form_upload_response_fk FOREIGN KEY (response_id) REFERENCES form_response (id)
          ON DELETE CASCADE
      SQL
  ]

  def plan
    create_table :form_definition do
      column :id, :big_int, primary_key: true, auto: true
      column :title, :string, max_size: 120
      column :description, :text, default: ""
      column :purpose, :text
      column :controller, :string, max_size: 300
      column :retention_days, :int, default: 90
      column :success_message, :text, default: ""
      column :category_id, :big_int, null: true
      column :accepts_files, :bool, default: false
      column :max_files, :int, default: 1
      column :enabled, :bool, default: true
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :form_field do
      column :id, :big_int, primary_key: true, auto: true
      column :definition_id, :big_int, index: true
      column :position, :int, default: 0
      column :key, :string, max_size: 40
      column :label, :string, max_size: 200
      column :kind, :string, max_size: 12, default: "text"
      column :required, :bool, default: false
      column :max_length, :int, null: true
      column :choices, :text, default: ""
      column :help, :string, max_size: 300, default: ""
      column :target, :string, max_size: 80, default: ""
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :form_link do
      column :id, :big_int, primary_key: true, auto: true
      column :definition_id, :big_int, index: true
      column :label, :string, max_size: 120, default: ""
      column :token_digest, :string, max_size: 64, unique: true
      column :token_hint, :string, max_size: 8
      column :expires_at, :date_time
      column :max_uses, :int, default: 1
      column :uses, :int, default: 0
      column :last_used_at, :date_time, null: true
      column :revoked_at, :date_time, null: true
      column :revoked_by_id, :big_int, null: true
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :form_response do
      column :id, :big_int, primary_key: true, auto: true
      column :definition_id, :big_int, index: true
      column :link_id, :big_int, null: true, index: true
      column :status, :string, max_size: 10, default: "received"
      column :data, :json
      column :received_at, :date_time
      column :purge_after, :date_time, index: true
      column :processed_by_id, :big_int, null: true
      column :processed_at, :date_time, null: true
      column :card_id, :big_int, null: true
      column :note, :text, default: ""
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :form_upload do
      column :id, :big_int, primary_key: true, auto: true
      column :response_id, :big_int, index: true
      column :filename, :string, max_size: 255
      column :content_type, :string, max_size: 64
      column :byte_size, :int
      column :sha256, :string, max_size: 64
      column :content, :text
      column :attachment_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    CONSTRAINTS.each { |(forward, backward)| execute(forward, backward) }
  end
end
