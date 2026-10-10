# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  # Pièces jointes reçues par la page publique (D-FRM-009) : PDF, PNG ou
  # JPEG, reconnus par leur signature et non par le type annoncé ou
  # l'extension du nom ; taille, nombre et volume en quarantaine bornés ;
  # nom de fichier assaini. Interne.
  module Files
    alias Api = Forms::Api
    alias FieldError = Partiduo::Api::FieldError

    PDF  = "%PDF-".to_slice
    PNG  = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    JPEG = Bytes[0xFF, 0xD8, 0xFF]

    MAX_FILENAME = 120

    # Type reconnu par la signature du contenu ; `nil` si aucun n'est admis.
    def self.detect(bytes : Bytes) : String?
      if starts_with?(bytes, PDF)
        "application/pdf"
      elsif starts_with?(bytes, PNG)
        "image/png"
      elsif starts_with?(bytes, JPEG)
        "image/jpeg"
      end
    end

    def self.errors(definition : Definition, files : Array(Api::FileInput)) : Array(FieldError)
      errors = [] of FieldError
      return errors if files.empty?
      unless definition.accepts_files!
        errors << Records.error("files", "files.not_accepted")
        return errors
      end
      if files.size > definition.max_files!
        errors << Records.error("files", "files.too_many", {"max" => definition.max_files!.to_s})
        return errors
      end
      files.each do |file|
        type = detect(file.content)
        if file.content.empty?
          errors << Records.error("files", "files.empty")
        elsif file.content.size > Api::MAX_FILE_BYTES
          errors << Records.error("files", "files.too_large", {"max" => (Api::MAX_FILE_BYTES // 1_048_576).to_s})
        elsif type.nil?
          errors << Records.error("files", "files.type")
        elsif type == "application/pdf" && active_pdf?(file.content)
          errors << Records.error("files", "files.active")
        end
      end
      if errors.empty?
        size = files.sum(&.content.size).to_i64
        if quarantined_bytes + size > Api::MAX_QUARANTINE_BYTES ||
           quarantined_bytes(definition.id!.to_i64) + size > Api::MAX_FORM_QUARANTINE
          errors << Records.error("files", "files.storage_full")
        end
      end
      errors
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

    def self.sha256(bytes : Bytes) : String
      OpenSSL::Digest.new("SHA256").update(bytes).final.hexstring
    end

    private def self.starts_with?(bytes : Bytes, prefix : Bytes) : Bool
      bytes.size >= prefix.size && bytes[0, prefix.size] == prefix
    end
  end
end
