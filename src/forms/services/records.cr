# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  # Recherche des lignes et construction des vues du contrat (interne).
  module Records
    alias Api = Forms::Api
    alias FieldError = Partiduo::Api::FieldError

    def self.error(field : String, key : String, params : Hash(String, String) = {} of String => String) : FieldError
      FieldError.new(field, "form.errors.#{key}", params)
    end

    def self.now : Time
      Partiduo::Config.now
    end

    # --- Recherche ---------------------------------------------------------------

    def self.definition!(id : Int64, lock : Bool = false) : Definition
      query = Definition.filter(id: id)
      query = query.lock if lock
      query.first || raise Partiduo::Api::NotFound.new("form", id)
    end

    def self.field!(id : Int64) : Field
      Field.filter(id: id).first || raise Partiduo::Api::NotFound.new("form_field", id)
    end

    def self.link!(id : Int64, lock : Bool = false) : Link
      query = Link.filter(id: id)
      query = query.lock if lock
      query.first || raise Partiduo::Api::NotFound.new("form_link", id)
    end

    def self.response!(id : Int64, lock : Bool = false) : Response
      query = Response.filter(id: id)
      query = query.lock if lock
      query.first || raise Partiduo::Api::NotFound.new("form_response", id)
    end

    def self.upload!(id : Int64) : Upload
      Upload.filter(id: id).first || raise Partiduo::Api::NotFound.new("form_upload", id)
    end

    def self.fields_of(definition_id : Int64) : Array(Field)
      Field.filter(definition_id: definition_id).order(:position, :id).to_a
    end

    # --- Vues --------------------------------------------------------------------

    def self.choices(text : String) : Array(String)
      text.lines.map(&.strip).reject(&.empty?).uniq!
    end

    def self.field_view(row : Field) : Api::FieldView
      Api::FieldView.new(
        id: row.id!.to_i64, form_id: row.definition_id!.to_i64, position: row.position!.to_i32, key: row.key!,
        label: row.label!, kind: row.kind!, required: row.required!, max_length: row.max_length.try(&.to_i32),
        choices: choices(row.choices.to_s), help: row.help.to_s, target: row.target.to_s,
      )
    end

    def self.form_view(row : Definition) : Api::FormView
      id = row.id!.to_i64
      now = self.now
      Api::FormView.new(
        id: id, title: row.title!, description: row.description.to_s, purpose: row.purpose!,
        controller: row.controller!, retention_days: row.retention_days!.to_i32, success_message: row.success_message.to_s,
        category_id: row.category_id.try(&.to_i64), accepts_files: row.accepts_files!, max_files: row.max_files!.to_i32,
        enabled: row.enabled!, fields: fields_of(id).map { |field| field_view(field) },
        pending_count: Response.filter(definition_id: id, status: "received").count.to_i64,
        response_count: Response.filter(definition_id: id).count.to_i64,
        active_link_count: Link.filter(definition_id: id, revoked_at__isnull: true, expires_at__gt: now).to_a
          .count { |link| link.uses! < link.max_uses! }.to_i64,
        created_at: row.created_at!,
      )
    end

    def self.link_state(row : Link, now : Time = self.now) : String
      if row.revoked_at
        "revoked"
      elsif row.expires_at! <= now
        "expired"
      elsif row.uses! >= row.max_uses!
        "exhausted"
      else
        "active"
      end
    end

    def self.link_view(row : Link) : Api::LinkView
      Api::LinkView.new(
        id: row.id!.to_i64, form_id: row.definition_id!.to_i64, label: row.label.to_s, hint: row.token_hint!,
        expires_at: row.expires_at!, max_uses: row.max_uses!.to_i32, uses: row.uses!.to_i32, last_used_at: row.last_used_at,
        revoked_at: row.revoked_at, state: link_state(row), created_at: row.created_at!,
      )
    end

    def self.values_of(row : Response) : Array(Api::ValueView)
      row.data!.as_a.map do |item|
        Api::ValueView.new(key: item["key"].as_s, label: item["label"].as_s, kind: item["kind"].as_s,
          value: item["value"].as_s)
      end
    end

    # Pièces d'une réponse, sans leur contenu (lu seulement au
    # téléchargement et au versement).
    def self.upload_views(response_id : Int64) : Array(Api::UploadView)
      Upload.filter(response_id: response_id).order(:id)
        .pluck(:id, :filename, :content_type, :byte_size, :sha256, :attachment_id).map do |(id, name, type, size, sha, attachment)|
        Api::UploadView.new(id: id.as(Int64), filename: name.as(String), content_type: type.as(String),
          byte_size: size.as(Int32 | Int64).to_i32, sha256: sha.as(String), attachment_id: attachment.as(Int64?))
      end
    end

    def self.response_view(row : Response, definition : Definition? = nil) : Api::ResponseView
      definition ||= definition!(row.definition_id!.to_i64)
      hint = row.link_id.try { |id| Link.filter(id: id).first.try(&.token_hint) }
      uploads = upload_views(row.id!.to_i64)
      Api::ResponseView.new(
        id: row.id!.to_i64, form_id: definition.id!.to_i64, form_title: definition.title!, link_hint: hint,
        status: row.status!, values: values_of(row), uploads: uploads, received_at: row.received_at!,
        purge_after: row.purge_after!, processed_by_id: row.processed_by_id.try(&.to_i64),
        processed_at: row.processed_at, card_id: row.card_id.try(&.to_i64), note: row.note.to_s,
        category_id: definition.category_id.try(&.to_i64),
      )
    end
  end
end
