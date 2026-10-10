# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  module Api
    # Natures de champ (D-FRM-005).
    FIELD_KINDS = %w[text textarea email phone number date checkbox select]

    # Statuts d'une réponse (D-FRM-008).
    STATUSES = %w[received accepted closed rejected]

    # Cibles d'un champ dans la fiche proposée au traitement (D-FRM-010) ;
    # s'y ajoutent `extra.<clé>` pour un attribut propre de la catégorie.
    CARD_TARGETS = %w[name email phone contact_name description vat_number siren siret address.line1 address.line2
      address.postcode address.city address.country_code]

    # Types de pièces admis sur la page publique, contrôlés par leur
    # signature (D-FRM-009) : un sous-ensemble de ceux du socle.
    FILE_TYPES = {"application/pdf" => ".pdf", "image/png" => ".png", "image/jpeg" => ".jpg"}

    MAX_FIELDS        =        30
    MAX_FILES         =         3
    MAX_FILE_BYTES    = 1_048_576
    MAX_CHOICES       =        50
    MAX_RETENTION     =     1_095
    DEFAULT_RETENTION =        90
    MAX_LINK_DAYS     =       366
    MAX_LINK_USES     =    10_000

    # Taille maximale d'un envoi public, enveloppe comprise : sous la limite
    # générale de Marten (2,5 Mo), pour qu'un envoi trop gros soit refusé
    # avant toute lecture du corps (D-FRM-007).
    MAX_BODY_BYTES = 2_400_000

    # Garde-fous durables, en base (D-FRM-007) : envois acceptés par lien et
    # par heure ; réponses à traiter par formulaire ; volume des pièces en
    # quarantaine pour toute l'instance.
    HOURLY_LIMIT         =  30
    MAX_PENDING          = 200
    MAX_QUARANTINE_BYTES = 200 * 1_048_576
    MAX_FORM_QUARANTINE  = 50 * 1_048_576

    # Longueurs par défaut et maximales d'une valeur saisie.
    DEFAULT_TEXT_LENGTH     =  200
    MAX_TEXT_LENGTH         = 1000
    DEFAULT_TEXTAREA_LENGTH = 2000
    MAX_TEXTAREA_LENGTH     = 5000

    # --- Entrées ---------------------------------------------------------------------

    # Définition d'un formulaire. `category_id` : catégorie de fiches visée
    # (facultative) ; `retention_days` : durée de conservation des réponses.
    record FormInput,
      title : String,
      purpose : String,
      controller : String,
      description : String = "",
      retention_days : Int32 = DEFAULT_RETENTION,
      success_message : String = "",
      category_id : Int64? = nil,
      accepts_files : Bool = false,
      max_files : Int32 = 1,
      enabled : Bool = true

    # Champ. `choices` : une valeur par ligne (liste) ; `target` : cible
    # dans la fiche (`CARD_TARGETS`, `extra.<clé>`) ou vide.
    record FieldInput,
      key : String,
      label : String,
      kind : String = "text",
      required : Bool = false,
      max_length : Int32? = nil,
      choices : String = "",
      help : String = "",
      target : String = ""

    # Lien public : expiration (date incluse) et nombre d'envois admis (1 :
    # usage unique).
    record LinkInput,
      expires_on : Time,
      max_uses : Int32 = 1,
      label : String = ""

    # Fichier envoyé par la page publique.
    record FileInput, filename : String, content_type : String, content : Bytes

    # Envoi public : valeurs par clé de champ (les autres clés sont
    # ignorées), fichiers, et champ piège rempli (robot : l'envoi est
    # accepté en apparence et rien n'est conservé).
    record SubmissionInput,
      values : Hash(String, String),
      files : Array(FileInput) = [] of FileInput,
      trap : Bool = false

    record ResponseQuery,
      form_id : Int64? = nil,
      status : String? = "received",
      limit : Int32 = 500

    # --- Vues ------------------------------------------------------------------------

    record FieldView,
      id : Int64,
      form_id : Int64,
      position : Int32,
      key : String,
      label : String,
      kind : String,
      required : Bool,
      max_length : Int32?,
      choices : Array(String),
      help : String,
      target : String do
      def kind_key : String
        "form.kinds.#{kind}"
      end

      def to_input : FieldInput
        FieldInput.new(key: key, label: label, kind: kind, required: required, max_length: max_length,
          choices: choices.join("\n"), help: help, target: target)
      end
    end

    record FormView,
      id : Int64,
      title : String,
      description : String,
      purpose : String,
      controller : String,
      retention_days : Int32,
      success_message : String,
      category_id : Int64?,
      accepts_files : Bool,
      max_files : Int32,
      enabled : Bool,
      fields : Array(FieldView),
      pending_count : Int64,
      response_count : Int64,
      active_link_count : Int64,
      created_at : Time do
      def to_input : FormInput
        FormInput.new(title: title, purpose: purpose, controller: controller, description: description,
          retention_days: retention_days, success_message: success_message, category_id: category_id,
          accepts_files: accepts_files, max_files: max_files, enabled: enabled)
      end
    end

    # Lien public, sans le jeton. `state` : `active`, `expired`, `revoked`,
    # `exhausted` (nombre d'envois atteint).
    record LinkView,
      id : Int64,
      form_id : Int64,
      label : String,
      hint : String,
      expires_at : Time,
      max_uses : Int32,
      uses : Int32,
      last_used_at : Time?,
      revoked_at : Time?,
      state : String,
      created_at : Time do
      def active? : Bool
        state == "active"
      end

      def state_key : String
        "form.link_states.#{state}"
      end
    end

    # Lien émis : le jeton n'est rendu qu'ici, une seule fois.
    record IssuedLinkView, link : LinkView, token : String

    # Ce que montre la page publique, et rien d'autre (D-FRM-007) : ni
    # catégorie, ni cible, ni identifiant interne.
    record PublicFieldView,
      key : String,
      label : String,
      kind : String,
      required : Bool,
      max_length : Int32,
      choices : Array(String),
      help : String

    record PublicFormView,
      title : String,
      description : String,
      purpose : String,
      controller : String,
      retention_days : Int32,
      accepts_files : Bool,
      max_files : Int32,
      fields : Array(PublicFieldView)

    record SubmittedView, message : String

    # Valeur reçue, figée à la réception.
    record ValueView, key : String, label : String, kind : String, value : String

    record UploadView,
      id : Int64,
      filename : String,
      content_type : String,
      byte_size : Int32,
      sha256 : String,
      attachment_id : Int64?

    record ResponseView,
      id : Int64,
      form_id : Int64,
      form_title : String,
      link_hint : String?,
      status : String,
      values : Array(ValueView),
      uploads : Array(UploadView),
      received_at : Time,
      purge_after : Time,
      processed_by_id : Int64?,
      processed_at : Time?,
      card_id : Int64?,
      note : String,
      category_id : Int64? do
      def received? : Bool
        status == "received"
      end

      def status_key : String
        "form.statuses.#{status}"
      end

      # Première valeur non vide, pour la liste.
      def summary : String
        values.find { |value| !value.value.empty? && value.kind != "checkbox" }.try(&.value) || ""
      end
    end

    # Pièce reçue, à télécharger par qui traite la réponse.
    record FileView, filename : String, content_type : String, content : Bytes
  end
end
