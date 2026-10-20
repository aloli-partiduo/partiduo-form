# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  # Envoi public d'une réponse (D-FRM-007, D-FRM-008) : rien ne passe en
  # comptabilité ni dans les fiches ; la réponse attend dans la boîte de
  # réception qu'un utilisateur authentifié la traite. Interne.
  module Submissions
    alias Api = Forms::Api
    alias FieldError = Partiduo::Api::FieldError
    alias Result = Partiduo::Api::Result

    Log = ::Log.for("partiduo.form")

    def self.submit(token : String, input : Api::SubmissionInput) : Result(Api::SubmittedView)
      return invalid if Links.resolve(token).nil?
      Partiduo::Api::Transaction.run do
        resolved = Links.resolve(token, lock: true)
        next invalid if resolved.nil?
        link, definition = resolved.link, resolved.definition
        # Un envoi à la fois pour l'instance : les plafonds de la boîte et de
        # la quarantaine se lisent et se respectent sans course entre liens.
        Marten::DB::Connection.default.open(&.exec("SELECT pg_advisory_xact_lock(hashtext('partiduo.form.submit'))"))
        message = definition.success_message.to_s
        if input.trap
          # Robot : réponse de succès en apparence, rien n'est conservé.
          Log.info { "envoi écarté (champ piège) : lien #{link.id}" }
          next Result(Api::SubmittedView).success(Api::SubmittedView.new(message))
        end
        now = Records.now
        if Response.filter(link_id: link.id, received_at__gt: now - 1.hour).count >= Api::HOURLY_LIMIT
          Log.warn { "envoi refusé (débit horaire du lien atteint) : lien #{link.id}" }
          next Result(Api::SubmittedView).failure(Records.error(FieldError::BASE, "limits.hourly"))
        end
        if Response.filter(definition_id: definition.id, status: "received").count >= Api::MAX_PENDING
          Log.warn { "envoi refusé (boîte de réception pleine) : formulaire #{definition.id}" }
          next Result(Api::SubmittedView).failure(Records.error(FieldError::BASE, "limits.inbox_full"))
        end

        errors = [] of FieldError
        data = Records.fields_of(definition.id!.to_i64).map do |field|
          value, error = Values.normalize(field, input.values[field.key!]?)
          errors << Records.error(field.key!, error) if error
          {"key" => field.key!, "label" => field.label!, "kind" => field.kind!, "value" => value}
        end
        file_errors, files = Files.check(definition, input.files)
        errors.concat(file_errors)
        next Result(Api::SubmittedView).failure(errors) unless errors.empty?

        response = Response.create!(
          definition_id: definition.id, link_id: link.id, status: "received",
          data: JSON.parse(data.to_json), received_at: now,
          purge_after: now + definition.retention_days!.days,
        )
        files.each do |file|
          Upload.create!(
            response_id: response.id, filename: file.filename, content_type: file.content_type,
            byte_size: file.content.size, sha256: file.sha256, content: Base64.strict_encode(file.content),
          )
        end
        link.uses = link.uses! + 1
        link.last_used_at = now
        link.save!
        Log.info do
          "réponse reçue : formulaire #{definition.id}, lien #{link.id}, réponse #{response.id}, #{input.files.size} pièce(s)"
        end
        Result(Api::SubmittedView).success(Api::SubmittedView.new(message))
      end
    end

    def self.invalid : Result(Api::SubmittedView)
      Result(Api::SubmittedView).failure(Records.error(FieldError::BASE, "link.invalid"))
    end
  end
end
