# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  # Traitement d'une réponse par un utilisateur authentifié (D-FRM-010) :
  # fiche proposée d'après les cibles des champs, créée *par le contrat du
  # cœur avec l'acteur qui traite* (ses droits sur les fiches s'appliquent,
  # `card.saved` est publié comme pour toute fiche), pièces versées au
  # dossier par `store_attachment` avec ce même acteur. Interne.
  module Processing
    alias Api = Forms::Api
    alias Cards = Partiduo::Api::Cards

    # Fiche proposée : catégorie du formulaire, valeurs des champs ciblés.
    # `nil` : le formulaire ne vise aucune catégorie.
    def self.card_draft(definition : Definition, response : Response) : Cards::CardInput?
      category_id = definition.category_id || return
      targets = Records.fields_of(definition.id!.to_i64).to_h { |field| {field.key!, field.target.to_s} }
      plain = {} of String => String
      extra = {} of String => JSON::Any
      Records.values_of(response).each do |value|
        target = targets[value.key]?.presence || next
        next if value.value.empty?
        if target.starts_with?("extra.")
          extra[target.lchop("extra.")] = value.kind == "checkbox" ? JSON::Any.new(value.value == "1") : JSON::Any.new(value.value)
        else
          plain[target] = value.value
        end
      end
      address = if plain.keys.any?(&.starts_with?("address."))
                  Cards::AddressInput.new(line1: plain["address.line1"]?, line2: plain["address.line2"]?,
                    postcode: plain["address.postcode"]?, city: plain["address.city"]?,
                    country_code: plain["address.country_code"]?.try(&.upcase))
                end
      Cards::CardInput.new(
        category_id: category_id.to_i64, name: plain["name"]? || "", description: plain["description"]?,
        vat_number: plain["vat_number"]?, siren: plain["siren"]?, siret: plain["siret"]?, email: plain["email"]?,
        phone: plain["phone"]?, contact_name: plain["contact_name"]?, address: address, extra: extra,
      )
    end

    # Pièces versées au dossier : contenu relu de la quarantaine, contrôlé
    # de nouveau par le socle.
    def self.store_files(actor : Partiduo::Api::Actor, response : Response) : Array(Partiduo::Api::FieldError)
      errors = [] of Partiduo::Api::FieldError
      Upload.filter(response_id: response.id, attachment_id__isnull: true).order(:id).each do |upload|
        bytes = Base64.decode(upload.content!)
        input = Partiduo::Api::Core::AttachmentInput.new(upload.filename!, upload.content_type!, IO::Memory.new(bytes))
        result = Partiduo::Api::Core.store_attachment(actor, input)
        if view = result.value?
          upload.attachment_id = view.id
          upload.content = ""
          upload.save!
        else
          errors.concat(result.errors.map { |error| Partiduo::Api::FieldError.new("files", error.key, error.params) })
        end
      end
      errors
    end
  end
end
