# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  # Contrôle et mise en forme d'une valeur reçue par la page publique,
  # selon la nature du champ (D-FRM-005). Rien n'est interprété : la valeur
  # est conservée comme texte, nettoyée des caractères de contrôle, bornée
  # en longueur ; un nombre est lu en décimal, jamais en flottant. Interne.
  module Values
    EMAIL   = /\A[^@\s<>"(),;:\\\[\]]+@[^@\s<>"(),;:\\\[\]]+\.[^@\s<>"(),;:\\\[\]]+\z/
    PHONE   = /\A\+?[0-9 ().\/-]{4,32}\z/
    NUMBER  = /\A-?\d{1,15}(\.\d{1,6})?\z/
    CONTROL = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F​-‏‪-‮⁦-⁩]/

    # Valeur retenue et clé d'erreur (`nil` si elle est admise).
    def self.normalize(field : Field, raw : String?) : {String, String?}
      text = raw || ""
      return {"", "value.encoding"} unless text.valid_encoding?
      kind = field.kind!
      if kind == "checkbox"
        checked = text == "1" || text == "on"
        return {checked ? "1" : "0", field.required! && !checked ? "value.required" : nil}
      end
      text = clean(text, multiline: kind == "textarea")
      return {"", field.required! ? "value.required" : nil} if text.empty?
      return {"", "value.too_long"} if text.size > Definitions.effective_length(field)
      typed(field, kind, text)
    end

    private def self.typed(field : Field, kind : String, text : String) : {String, String?}
      case kind
      when "email"
        text.matches?(EMAIL) ? {text, nil} : {"", "value.email"}
      when "phone"
        text.matches?(PHONE) && text.count(&.ascii_number?) >= 4 ? {text, nil} : {"", "value.phone"}
      when "number"
        number(text)
      when "date"
        date(text)
      when "select"
        Records.choices(field.choices.to_s).includes?(text) ? {text, nil} : {"", "value.choice"}
      else
        {text, nil}
      end
    end

    # Caractères de contrôle et d'orientation retirés (sauf les fins de
    # ligne d'un texte long), espaces en trop retirés.
    def self.clean(text : String, multiline : Bool = false) : String
      text = text.gsub("\r\n", "\n").gsub('\r', '\n')
      text = multiline ? text.gsub('\t', ' ') : text.gsub(/[\t\n]/, " ")
      text.gsub(CONTROL, "").strip
    end

    # Nombre décimal : espaces (et espaces insécables) de milliers retirés,
    # virgule ou point décimal.
    private def self.number(text : String) : {String, String?}
      compact = text.gsub(/[\s  ]/, "").tr(",", ".")
      return {"", "value.number"} unless compact.matches?(NUMBER)
      {BigDecimal.new(compact).to_s, nil}
    rescue ArgumentError | InvalidBigDecimalException
      {"", "value.number"}
    end

    # Date `AAAA-MM-JJ` (champ de date du navigateur), entre 1900 et 2200.
    private def self.date(text : String) : {String, String?}
      return {"", "value.date"} unless text.matches?(/\A\d{4}-\d{2}-\d{2}\z/)
      parsed = Time.parse_utc(text, "%Y-%m-%d")
      return {"", "value.date"} unless (1900..2200).includes?(parsed.year)
      {parsed.to_s("%Y-%m-%d"), nil}
    rescue Time::Format::Error | ArgumentError
      {"", "value.date"}
    end
  end
end
