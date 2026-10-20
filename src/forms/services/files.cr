# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  # Pièces jointes reçues par la page publique (D-FRM-009) : PDF, PNG ou
  # JPEG, reconnus par leur signature et non par le type annoncé ou
  # l'extension du nom, puis contrôlés par la règle du socle sans être
  # stockés (`Partiduo::Api::Core.detect_attachment_type` et
  # `check_attachment`, D-FRM-018) ; taille, nombre et volume en
  # quarantaine bornés par l'extension ; nom de fichier assaini. Interne.
  module Files
    alias Api = Forms::Api
    alias FieldError = Partiduo::Api::FieldError
    alias Core = Partiduo::Api::Core

    MAX_FILENAME = 120

    # Pièce admise en quarantaine : nom assaini, type reconnu, contenu et
    # empreinte donnés par le contrôle du socle.
    record Checked, filename : String, content_type : String, content : Bytes, sha256 : String

    # Type reconnu par la signature du contenu, parmi ceux qu'admet le
    # formulaire (`Api::FILE_TYPES`) ; `nil` si aucun ne convient.
    def self.detect(bytes : Bytes) : String?
      Core.detect_attachment_type(bytes, Api::FILE_TYPES.keys)
    end

    # Erreurs (champ `files`) et pièces contrôlées, prêtes pour la
    # quarantaine.
    def self.check(definition : Definition, files : Array(Api::FileInput)) : {Array(FieldError), Array(Checked)}
      errors = [] of FieldError
      checked = [] of Checked
      return {errors, checked} if files.empty?
      unless definition.accepts_files!
        errors << Records.error("files", "files.not_accepted")
        return {errors, checked}
      end
      if files.size > definition.max_files!
        errors << Records.error("files", "files.too_many", {"max" => definition.max_files!.to_s})
        return {errors, checked}
      end
      files.each do |file|
        error, item = check_file(file)
        error ? errors.concat(error) : (checked << item.as(Checked))
      end
      if errors.empty?
        size = files.sum(&.content.size).to_i64
        if quarantined_bytes + size > Api::MAX_QUARANTINE_BYTES ||
           quarantined_bytes(definition.id!.to_i64) + size > Api::MAX_FORM_QUARANTINE
          errors << Records.error("files", "files.storage_full")
        end
      end
      {errors, checked}
    end

    # Contrôle d'une pièce : règles de l'extension (taille, type admis par
    # le formulaire, PDF sans contenu actif), puis règle du socle sans
    # stockage.
    private def self.check_file(file : Api::FileInput) : {Array(FieldError)?, Checked?}
      type = detect(file.content)
      error = if file.content.empty?
                Records.error("files", "files.empty")
              elsif file.content.size > Api::MAX_FILE_BYTES
                Records.error("files", "files.too_large", {"max" => (Api::MAX_FILE_BYTES // 1_048_576).to_s})
              elsif type == "application/pdf" && active_pdf?(file.content)
                Records.error("files", "files.active")
              end
      return {[error], nil} if error
      return {[Records.error("files", "files.type")], nil} unless type
      input = Core::AttachmentInput.new(clean_filename(file.filename, type), type, IO::Memory.new(file.content))
      result = Core.check_attachment(Partiduo::Api::Actor.anonymous, input)
      if view = result.value?
        {nil, Checked.new(view.filename, view.content_type, file.content, view.sha256)}
      else
        {result.errors.map { |item| FieldError.new("files", item.key, item.params) }, nil}
      end
    end

    # PDF à contenu actif (JavaScript, lancement d'application, fichier
    # embarqué, formulaire XFA) ou tronqué : refusé à la porte, même s'il
    # n'est jamais affiché par Partiduo (D-FRM-009).
    ACTIVE_PDF = /\/(?:JavaScript|JS|Launch|EmbeddedFile|XFA|RichMedia|OpenAction|AA)\b/

    def self.active_pdf?(bytes : Bytes) : Bool
      text = String.new(bytes).scrub
      text.matches?(ACTIVE_PDF) || !text.includes?("%%EOF")
    end

    # Volume des pièces en quarantaine (non versées au dossier), pour toute
    # l'instance.
    def self.quarantined_bytes : Int64
      Marten::DB::Connection.default.open do |db|
        db.scalar("SELECT COALESCE(SUM(byte_size), 0)::bigint FROM form_upload WHERE attachment_id IS NULL").as(Int64)
      end
    end

    # Volume en quarantaine d'un formulaire : un lien abusé ne remplit pas
    # la quarantaine de tous les autres.
    def self.quarantined_bytes(definition_id : Int64) : Int64
      Marten::DB::Connection.default.open do |db|
        db.scalar("SELECT COALESCE(SUM(u.byte_size), 0)::bigint FROM form_upload u " \
                  "JOIN form_response r ON r.id = u.response_id " \
                  "WHERE u.attachment_id IS NULL AND r.definition_id = $1", definition_id).as(Int64)
      end
    end

    # Nom affiché et téléchargé : sans chemin ni caractère de contrôle ou
    # réservé, borné, avec l'extension du type reconnu.
    def self.clean_filename(name : String, content_type : String) : String
      base = (name.valid_encoding? ? name : name.scrub("_")).split(/[\/\\]/).last? || ""
      base = base.gsub(Values::CONTROL, "").gsub(/[\x00-\x1F\x7F"<>:|?*;]/, "_").strip.lchop('.')
      stem = File.basename(base, File.extname(base)).strip
      stem = "piece" if stem.empty?
      extension = Api::FILE_TYPES[content_type]
      "#{stem[0, MAX_FILENAME - extension.size]}#{extension}"
    end
  end
end
