# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  # Contrôles des définitions : formulaire et champs (D-FRM-004, D-FRM-005).
  # Interne.
  module Definitions
    alias Api = Forms::Api
    alias FieldError = Partiduo::Api::FieldError

    KEY_FORMAT = /\A[a-z][a-z0-9_]{0,39}\z/

    # Noms réservés par la page publique : jeton CSRF, fichiers, champ piège.
    RESERVED_KEYS = %w[csrftoken files website]

    MAX_TITLE       =  120
    MAX_PURPOSE     = 2000
    MAX_CONTROLLER  =  300
    MAX_DESCRIPTION = 4000
    MAX_MESSAGE     = 1000
    MAX_LABEL       =  200
    MAX_HELP        =  300
    MAX_CHOICE      =  100

    def self.form_errors(actor : Partiduo::Api::Actor, input : Api::FormInput, current : Definition?) : Array(FieldError)
      errors = [] of FieldError
      text(errors, "title", input.title, MAX_TITLE, required: true)
      text(errors, "purpose", input.purpose, MAX_PURPOSE, required: true)
      text(errors, "controller", input.controller, MAX_CONTROLLER, required: true)
      text(errors, "description", input.description, MAX_DESCRIPTION)
      text(errors, "success_message", input.success_message, MAX_MESSAGE)
      unless (1..Api::MAX_RETENTION).includes?(input.retention_days)
        errors << Records.error("retention_days", "retention.range", {"max" => Api::MAX_RETENTION.to_s})
      end
      unless (1..Api::MAX_FILES).includes?(input.max_files)
        errors << Records.error("max_files", "max_files.range", {"max" => Api::MAX_FILES.to_s})
      end
      attributes = input.category_id.try { |id| category_attributes(actor, id, errors) }
      if current && errors.none? { |error| error.field == "category_id" }
        Records.fields_of(current.id!.to_i64).each do |field|
          target = field.target.to_s
          next unless target.starts_with?("extra.")
          next if attributes && attributes.includes?(target.lchop("extra."))
          errors << Records.error("category_id", "category.targets", {"field" => field.label!})
          break
        end
      end
      errors
    end

    def self.apply(row : Definition, input : Api::FormInput) : Definition
      row.title = input.title.strip
      row.purpose = input.purpose.strip
      row.controller = input.controller.strip
      row.description = input.description.strip
      row.success_message = input.success_message.strip
      row.retention_days = input.retention_days
      row.category_id = input.category_id
      row.accepts_files = input.accepts_files
      row.max_files = input.max_files
      row.enabled = input.enabled
      row
    end

    def self.field_errors(actor : Partiduo::Api::Actor, definition : Definition, input : Api::FieldInput,
                          current : Field?) : Array(FieldError)
      errors = [] of FieldError
      siblings = Records.fields_of(definition.id!.to_i64).reject { |field| current && field.id == current.id }
      key_errors(input.key.strip, siblings, errors)
      if current.nil? && siblings.size >= Api::MAX_FIELDS
        errors << Records.error(FieldError::BASE, "field.too_many", {"max" => Api::MAX_FIELDS.to_s})
      end
      text(errors, "label", input.label, MAX_LABEL, required: true)
      text(errors, "help", input.help, MAX_HELP)
      unless Api::FIELD_KINDS.includes?(input.kind)
        errors << Records.error("kind", "field.kind_invalid", {"value" => input.kind})
        return errors
      end
      if limit = max_length_limit(input.kind)
        input.max_length.try do |length|
          errors << Records.error("max_length", "field.max_length", {"max" => limit.to_s}) unless (1..limit).includes?(length)
        end
      end
      choice_errors(input.choices, errors) if input.kind == "select"
      target_errors(actor, definition, input.target.strip, siblings, errors)
      errors
    end

    def self.apply(row : Field, input : Api::FieldInput) : Field
      row.key = input.key.strip
      row.label = input.label.strip
      row.kind = input.kind
      row.required = input.required
      row.max_length = max_length_limit(input.kind) ? input.max_length : nil
      row.choices = input.kind == "select" ? Records.choices(input.choices).join("\n") : ""
      row.help = input.help.strip
      row.target = input.target.strip
      row
    end

    # Longueur maximale admise pour la nature ; `nil` : la nature n'en a pas.
    def self.max_length_limit(kind : String) : Int32?
      case kind
      when "text"     then Api::MAX_TEXT_LENGTH
      when "textarea" then Api::MAX_TEXTAREA_LENGTH
      end
    end

    # Longueur appliquée à une valeur reçue.
    def self.effective_length(field : Field) : Int32
      case field.kind
      when "text"     then (field.max_length || Api::DEFAULT_TEXT_LENGTH).to_i32
      when "textarea" then (field.max_length || Api::DEFAULT_TEXTAREA_LENGTH).to_i32
      when "email"    then 254
      when "phone"    then 32
      when "number"   then 32
      when "date"     then 10
      when "select"   then MAX_CHOICE
      else                 1
      end
    end

    private def self.key_errors(key : String, siblings : Array(Field), errors : Array(FieldError)) : Nil
      if !key.matches?(KEY_FORMAT)
        errors << Records.error("key", "field.key_format")
      elsif RESERVED_KEYS.includes?(key)
        errors << Records.error("key", "field.key_reserved", {"value" => key})
      elsif siblings.any? { |field| field.key == key }
        errors << Records.error("key", "field.key_taken", {"value" => key})
      end
    end

    private def self.choice_errors(text : String, errors : Array(FieldError)) : Nil
      choices = Records.choices(text)
      if choices.empty?
        errors << Records.error("choices", "field.choices_blank")
      elsif choices.size > Api::MAX_CHOICES
        errors << Records.error("choices", "field.choices_many", {"max" => Api::MAX_CHOICES.to_s})
      elsif choices.any? { |choice| choice.size > MAX_CHOICE }
        errors << Records.error("choices", "field.choice_long", {"max" => MAX_CHOICE.to_s})
      end
    end

    private def self.target_errors(actor : Partiduo::Api::Actor, definition : Definition, target : String,
                                   siblings : Array(Field), errors : Array(FieldError)) : Nil
      return if target.empty?
      if siblings.any? { |field| field.target == target }
        errors << Records.error("target", "field.target_taken", {"value" => target})
      elsif target.starts_with?("extra.")
        category_id = definition.category_id
        if category_id.nil?
          errors << Records.error("target", "field.target_no_category")
        else
          attributes = category_attributes(actor, category_id.to_i64, errors, "target")
          if attributes && !attributes.includes?(target.lchop("extra."))
            errors << Records.error("target", "field.target_invalid", {"value" => target})
          end
        end
      elsif !Api::CARD_TARGETS.includes?(target)
        errors << Records.error("target", "field.target_invalid", {"value" => target})
      end
    end

    # Clés des attributs propres de la catégorie, lue avec les droits de
    # l'acteur ; `nil` et une erreur si elle est introuvable ou illisible.
    private def self.category_attributes(actor : Partiduo::Api::Actor, id : Int64, errors : Array(FieldError),
                                         field : String = "category_id") : Array(String)?
      Partiduo::Api::Cards.category(actor, id).attributes.map(&.key)
    rescue Partiduo::Api::NotFound
      errors << Records.error(field, "category.unknown")
      nil
    rescue Partiduo::Api::AccessDenied
      errors << Records.error(field, "category.forbidden")
      nil
    end

    private def self.text(errors : Array(FieldError), field : String, value : String, max : Int32,
                          required : Bool = false) : Nil
      stripped = value.strip
      if required && stripped.empty?
        errors << Records.error(field, "text.blank")
      elsif stripped.size > max
        errors << Records.error(field, "text.too_long", {"max" => max.to_s})
      elsif !stripped.valid_encoding?
        errors << Records.error(field, "text.encoding")
      end
    end
  end
end
