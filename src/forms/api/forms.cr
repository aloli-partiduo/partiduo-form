# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  # Contrat public de l'extension des formulaires, sur le modèle de
  # `Partiduo::Api` : acteur en premier argument, contrôle d'accès en
  # première ligne (extension active et permission), objets de vue
  # immuables, toute écriture par une commande qui rend un `Result` avec
  # ses erreurs par champ, dans une transaction. L'interface de l'extension
  # (`ui/bulma/`) ne voit que ce module et `Partiduo::Api`.
  #
  # Deux fonctions seulement admettent l'acteur anonyme : `public_form` et
  # `submit`, appelées par la page publique avec le jeton du lien
  # (D-FRM-007). Elles ne rendent que ce que le formulaire montre et
  # n'écrivent que dans la boîte de réception.
  #
  # Référence : `doc/api/form.adoc`.
  module Api
    alias Actor = Partiduo::Api::Actor
    alias Guard = Partiduo::Api::Guard
    alias Result = Partiduo::Api::Result
    alias FieldError = Partiduo::Api::FieldError
    alias Transaction = Partiduo::Api::Transaction

    MODULE_CODE = Forms::CODE
    READ        = "form.read"
    PROCESS     = "form.process"
    DESIGN      = "form.design"
    ADMIN       = "form.admin"

    # Permissions du socle exigées en plus pour accepter une réponse : la
    # fiche est créée par le contrat des fiches, les pièces sont versées au
    # dossier (D-FRM-010) puis rattachées à la fiche, ce qui exige de
    # pouvoir les lire (`Partiduo::Api::Cards.attach`, D-FRM-019).
    CARD_PERMISSION            = "cards.card.write"
    ATTACHMENT_PERMISSION      = "core.attachment.write"
    ATTACHMENT_READ_PERMISSION = "core.attachment.read"

    # --- Formulaires ---------------------------------------------------------------

    def self.forms(actor : Actor) : Array(FormView)
      authorize!(actor, READ)
      Definition.all.order(:title, :id).to_a.map { |row| Records.form_view(row) }
    end

    def self.form(actor : Actor, id : Int64) : FormView
      authorize!(actor, READ)
      Records.form_view(Records.definition!(id))
    end

    # Erreurs : `form.errors.text.*`, `.retention.range`, `.max_files.range`,
    # `.category.unknown`, `.category.forbidden`, `.category.targets`.
    def self.create_form(actor : Actor, input : FormInput) : Result(FormView)
      authorize!(actor, DESIGN)
      errors = Definitions.form_errors(actor, input, nil)
      return Result(FormView).failure(errors) unless errors.empty?
      Transaction.run do
        row = Definitions.apply(Definition.new(created_by_id: actor.user_id), input)
        row.save!
        Result(FormView).success(Records.form_view(row))
      end
    end

    def self.update_form(actor : Actor, id : Int64, input : FormInput) : Result(FormView)
      authorize!(actor, DESIGN)
      Transaction.run do
        row = Records.definition!(id, lock: true)
        errors = Definitions.form_errors(actor, input, row)
        next Result(FormView).failure(errors) unless errors.empty?
        Definitions.apply(row, input).save!
        Result(FormView).success(Records.form_view(row))
      end
    end

    # Efface un formulaire, ses champs, ses liens et ses réponses traitées.
    # Refusé tant qu'une réponse attend d'être traitée (`form.pending`).
    def self.delete_form(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, ADMIN)
      Transaction.run do
        row = Records.definition!(id, lock: true)
        if Response.filter(definition_id: id, status: "received").exists?
          next Result(Nil).failure(Records.error(FieldError::BASE, "form.pending"))
        end
        row.delete
        Result(Nil).success(nil)
      end
    end

    # --- Champs --------------------------------------------------------------------

    def self.field(actor : Actor, id : Int64) : FieldView
      authorize!(actor, READ)
      Records.field_view(Records.field!(id))
    end

    # Erreurs : `form.errors.field.*`, `.text.*`, `.category.*`.
    def self.add_field(actor : Actor, form_id : Int64, input : FieldInput) : Result(FieldView)
      authorize!(actor, DESIGN)
      Transaction.run do
        definition = Records.definition!(form_id, lock: true)
        errors = Definitions.field_errors(actor, definition, input, nil)
        next Result(FieldView).failure(errors) unless errors.empty?
        position = (Records.fields_of(form_id).max_of?(&.position!.to_i32) || 0) + 1
        row = Definitions.apply(Field.new(definition_id: form_id, position: position), input)
        row.save!
        Result(FieldView).success(Records.field_view(row))
      end
    end

    def self.update_field(actor : Actor, id : Int64, input : FieldInput) : Result(FieldView)
      authorize!(actor, DESIGN)
      Transaction.run do
        row = Records.field!(id)
        definition = Records.definition!(row.definition_id!.to_i64, lock: true)
        errors = Definitions.field_errors(actor, definition, input, row)
        next Result(FieldView).failure(errors) unless errors.empty?
        Definitions.apply(row, input).save!
        Result(FieldView).success(Records.field_view(row))
      end
    end

    # Les réponses déjà reçues gardent leur copie du champ.
    def self.delete_field(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, DESIGN)
      Transaction.run do
        Records.field!(id).delete
        Result(Nil).success(nil)
      end
    end

    # Monte (`up`) ou descend un champ d'un rang.
    def self.move_field(actor : Actor, id : Int64, up : Bool) : Result(Nil)
      authorize!(actor, DESIGN)
      Transaction.run do
        row = Records.field!(id)
        Records.definition!(row.definition_id!.to_i64, lock: true)
        fields = Records.fields_of(row.definition_id!.to_i64)
        index = fields.index { |field| field.id == row.id } || raise Partiduo::Api::NotFound.new("form_field", id)
        other = up ? (index > 0 ? fields[index - 1] : nil) : fields[index + 1]?
        if other
          fields.swap(index, fields.index!(other))
          fields.each_with_index(1) do |field, position|
            next if field.position == position
            field.position = position
            field.save!
          end
        end
        Result(Nil).success(nil)
      end
    end

    # --- Liens publics -------------------------------------------------------------

    def self.links(actor : Actor, form_id : Int64) : Array(LinkView)
      authorize!(actor, READ)
      Records.definition!(form_id)
      Link.filter(definition_id: form_id).order("-created_at", "-id").to_a.map { |row| Records.link_view(row) }
    end

    # Émet un lien (D-FRM-006) : le jeton est rendu *une seule fois*, dans
    # `IssuedLinkView#token` ; seule son empreinte est conservée. Erreurs :
    # `form.errors.link.expires_past`, `.expires_far`, `.max_uses`,
    # `.no_fields`, `.disabled`, `.text.too_long`.
    def self.create_link(actor : Actor, form_id : Int64, input : LinkInput) : Result(IssuedLinkView)
      authorize!(actor, ADMIN)
      Transaction.run do
        definition = Records.definition!(form_id, lock: true)
        errors = [] of FieldError
        today = Partiduo::Config.today
        expires_on = Time.utc(input.expires_on.year, input.expires_on.month, input.expires_on.day)
        if expires_on < today
          errors << Records.error("expires_on", "link.expires_past")
        elsif expires_on > today + MAX_LINK_DAYS.days
          errors << Records.error("expires_on", "link.expires_far", {"max" => MAX_LINK_DAYS.to_s})
        end
        unless (1..MAX_LINK_USES).includes?(input.max_uses)
          errors << Records.error("max_uses", "link.max_uses", {"max" => MAX_LINK_USES.to_s})
        end
        errors << Records.error("label", "text.too_long", {"max" => "120"}) if input.label.strip.size > 120
        errors << Records.error(FieldError::BASE, "link.no_fields") if Records.fields_of(form_id).empty?
        errors << Records.error(FieldError::BASE, "link.disabled") unless definition.enabled!
        next Result(IssuedLinkView).failure(errors) unless errors.empty?

        token = Tokens.generate
        row = Link.create!(
          definition_id: form_id, label: input.label.strip, token_digest: Tokens.digest(token),
          token_hint: Tokens.hint(token), expires_at: expires_on + 1.day, max_uses: input.max_uses, uses: 0,
          created_by_id: actor.user_id,
        )
        Result(IssuedLinkView).success(IssuedLinkView.new(Records.link_view(row), token))
      end
    end

    # Révoque un lien : il ne répond plus, définitivement. Erreur :
    # `form.errors.link.revoked` (déjà révoqué).
    def self.revoke_link(actor : Actor, id : Int64) : Result(LinkView)
      authorize!(actor, ADMIN)
      Transaction.run do
        row = Records.link!(id, lock: true)
        next Result(LinkView).failure(Records.error(FieldError::BASE, "link.revoked")) if row.revoked_at
        row.revoked_at = Records.now
        row.revoked_by_id = actor.user_id
        row.save!
        Result(LinkView).success(Records.link_view(row))
      end
    end

    # --- Page publique (acteur anonyme admis) --------------------------------------

    # Ce que montre la page publique pour ce jeton ; `nil` si le lien est
    # inconnu, expiré, révoqué, épuisé, ou son formulaire désactivé.
    def self.public_form(actor : Actor, token : String) : PublicFormView?
      Guard.require_module!(MODULE_CODE)
      resolved = Links.resolve(token) || return
      definition = resolved.definition
      fields = Records.fields_of(definition.id!.to_i64).map do |field|
        PublicFieldView.new(key: field.key!, label: field.label!, kind: field.kind!, required: field.required!,
          max_length: Definitions.effective_length(field), choices: Records.choices(field.choices.to_s),
          help: field.help.to_s)
      end
      PublicFormView.new(
        title: definition.title!, description: definition.description.to_s, purpose: definition.purpose!,
        controller: definition.controller!, retention_days: definition.retention_days!.to_i32,
        accepts_files: definition.accepts_files!, max_files: definition.max_files!.to_i32, fields: fields,
      )
    end

    # Clé de limitation de débit d'un jeton, pour l'interface : un préfixe
    # de son empreinte, jamais le jeton lui-même (D-FRM-007).
    def self.link_key(token : String) : String
      Tokens.digest(token)[0, 16]
    end

    # Envoi d'une réponse par la page publique (D-FRM-007). Erreurs :
    # `form.errors.link.invalid` (même erreur quel que soit le motif),
    # `.limits.hourly`, `.limits.inbox_full`, `.value.*` (sur la clé du
    # champ), `.files.*`.
    def self.submit(actor : Actor, token : String, input : SubmissionInput) : Result(SubmittedView)
      Guard.require_module!(MODULE_CODE)
      Submissions.submit(token, input)
    end

    # --- Boîte de réception --------------------------------------------------------

    # Réponses, les plus récentes d'abord ; les réponses échues sont
    # purgées avant la lecture (D-FRM-011).
    def self.responses(actor : Actor, query : ResponseQuery = ResponseQuery.new) : Array(ResponseView)
      authorize!(actor, READ)
      Purge.run
      rows = Response.all
      query.form_id.try { |id| rows = rows.filter(definition_id: id) }
      query.status.try { |status| rows = rows.filter(status: status) }
      definitions = {} of Int64 => Definition
      rows.order("-received_at", "-id")[0...query.limit.clamp(1, 1000)].to_a.map do |row|
        definition = definitions[row.definition_id!.to_i64] ||= Records.definition!(row.definition_id!.to_i64)
        Records.response_view(row, definition)
      end
    end

    def self.response(actor : Actor, id : Int64) : ResponseView
      authorize!(actor, READ)
      Records.response_view(Records.response!(id))
    end

    # Réponses à traiter, pour le compteur du menu ; `nil` si l'extension
    # est inactive ou l'acteur sans droit.
    def self.pending_count(actor : Actor) : Int64?
      authorize!(actor, READ)
      Response.filter(status: "received").count.to_i64
    rescue Partiduo::Api::AccessDenied
      nil
    end

    # Pièce reçue, pour qui traite la réponse (D-FRM-009).
    def self.file(actor : Actor, upload_id : Int64) : FileView
      authorize!(actor, PROCESS)
      row = Records.upload!(upload_id)
      if attachment_id = row.attachment_id
        bytes = Partiduo::Api::Core.attachment_content(actor, attachment_id.to_i64)
        return FileView.new(row.filename!, row.content_type!, bytes)
      end
      FileView.new(row.filename!, row.content_type!, Base64.decode(row.content!))
    end

    # Fiche proposée pour une réponse ; `nil` si le formulaire ne vise
    # aucune catégorie.
    def self.card_draft(actor : Actor, id : Int64) : Partiduo::Api::Cards::CardInput?
      authorize!(actor, PROCESS)
      row = Records.response!(id)
      Processing.card_draft(Records.definition!(row.definition_id!.to_i64), row)
    end

    # Accepte une réponse : crée la fiche `card` par le contrat du cœur avec
    # l'acteur (D-FRM-010) et, si `store_files`, verse les pièces reçues au
    # dossier puis les rattache à la fiche (`Partiduo::Api::Cards.attach`,
    # D-FRM-019). Tout ou rien. Erreurs : celles de
    # `Partiduo::Api::Cards.create_card`, `form.errors.response.processed`,
    # `.files.forbidden` (versement ou lecture des pièces refusés à
    # l'acteur), celles de `store_attachment` et de `Cards.attach` (sur
    # `files`).
    def self.accept(actor : Actor, id : Int64, card : Partiduo::Api::Cards::CardInput,
                    store_files : Bool = true) : Result(ResponseView)
      authorize!(actor, PROCESS)
      Transaction.run do
        row = Records.response!(id, lock: true)
        next Result(ResponseView).failure(Records.error(FieldError::BASE, "response.processed")) unless row.status == "received"
        with_files = store_files && Upload.filter(response_id: row.id, attachment_id__isnull: true).exists?
        if with_files && !(actor.can?(ATTACHMENT_PERMISSION) && actor.can?(ATTACHMENT_READ_PERMISSION))
          next Result(ResponseView).failure(Records.error("files", "files.forbidden"))
        end
        created = Partiduo::Api::Cards.create_card(actor, card)
        next Result(ResponseView).failure(created.errors) if created.failure?
        card_id = created.value!.id
        if with_files
          errors = Processing.store_files(actor, row)
          errors = Processing.attach_files(actor, row, card_id) if errors.empty?
          # Échec : la transaction annule la fiche et les pièces versées.
          next Result(ResponseView).failure(errors) unless errors.empty?
        end
        processed(row, actor, "accepted", "", card_id)
        Result(ResponseView).success(Records.response_view(row))
      end
    end

    # Reprise des réponses acceptées avant le rattachement des pièces aux
    # fiches (D-FRM-019) : rattache à la fiche de chaque réponse acceptée
    # encore conservée les pièces qu'elle a versées au dossier. Idempotente
    # (une pièce déjà rattachée l'est une fois). Une réponse dont la fiche
    # a été supprimée est passée. Rend le nombre de réponses reprises.
    # Droits : `form.admin`, puis ceux de `Partiduo::Api::Cards.attach`.
    # Jouée d'elle-même au démarrage de chaque instance par la migration
    # `form_0002_attach_accepted_files` (D-FRM-021) ; ici pour un passage
    # manuel (`manage form_attach_files`).
    def self.attach_accepted_files(actor : Actor) : Int64
      authorize!(actor, ADMIN)
      Processing.attach_accepted_files(actor)
    end

    # Classe une réponse traitée sans fiche (D-FRM-008).
    def self.close(actor : Actor, id : Int64, note : String = "") : Result(ResponseView)
      settle(actor, id, "closed", note)
    end

    # Rejette une réponse (indésirable, hors sujet).
    def self.reject(actor : Actor, id : Int64, note : String = "") : Result(ResponseView)
      settle(actor, id, "rejected", note)
    end

    # Efface une réponse sans attendre l'échéance (droit à l'effacement).
    def self.delete_response(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, ADMIN)
      Transaction.run do
        Records.response!(id, lock: true).delete
        Partiduo::Events.after_commit { Links::Log.info { "réponse #{id} effacée à la demande" } }
        Result(Nil).success(nil)
      end
    end

    # Efface les réponses échues ; rend leur nombre.
    def self.purge(actor : Actor, now : Time = Partiduo::Config.now) : Int64
      authorize!(actor, ADMIN)
      Purge.run(now)
    end

    private def self.settle(actor : Actor, id : Int64, status : String, note : String) : Result(ResponseView)
      authorize!(actor, PROCESS)
      if note.strip.size > 1000
        return Result(ResponseView).failure(Records.error("note", "text.too_long", {"max" => "1000"}))
      end
      Transaction.run do
        row = Records.response!(id, lock: true)
        next Result(ResponseView).failure(Records.error(FieldError::BASE, "response.processed")) unless row.status == "received"
        processed(row, actor, status, note.strip, nil)
        # Une réponse rejetée ne garde pas ses pièces en quarantaine.
        Upload.filter(response_id: row.id, attachment_id__isnull: true).delete(raw: true) if status == "rejected"
        Result(ResponseView).success(Records.response_view(row))
      end
    end

    private def self.processed(row : Response, actor : Actor, status : String, note : String, card_id : Int64?) : Nil
      row.status = status
      row.note = note
      row.card_id = card_id
      row.processed_by_id = actor.user_id
      row.processed_at = Records.now
      row.save!
    end

    private def self.authorize!(actor : Actor, permission : String) : Nil
      Guard.authorize!(actor, permission, module_code: MODULE_CODE)
    end
  end
end
