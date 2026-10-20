# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  module Ui
    # `/p/form/<jeton>` : page publique d'un formulaire, seule surface de
    # Partiduo ouverte sans authentification (D-FRM-007), montée par
    # `PartiduoUi::Extensions.public_mount` (D-FRM-017). L'interface a
    # déjà, avant ce handler : rendu 404 si l'extension est inactive,
    # appliqué le débit par adresse de la route (429) et la limite de
    # taille annoncée (413). Puis, dans l'ordre :
    #
    # . limitation propre : adresse bloquée après trop de jetons refusés,
    #   envois par adresse et par lien (429) ;
    # . taille : un envoi plus gros que `Api::MAX_BODY_BYTES`, une fois lu
    #   (envoi sans taille annoncée), est refusé (413) ;
    # . protection CSRF de Marten (jeton du formulaire, origine) : un envoi
    #   depuis un autre site est refusé (403) ;
    # . jeton : inconnu, expiré, révoqué, épuisé ou formulaire désactivé,
    #   même page « lien non valide » (404) ;
    # . contrôle des valeurs et des pièces par le contrat, qui ne range la
    #   réponse que dans la boîte de réception, sous sa limite durable en
    #   base (envois par lien et par heure, réponses à traiter).
    #
    # Toute réponse reçoit de l'interface les en-têtes stricts communs
    # (`PartiduoUi::Extensions::PUBLIC_HEADERS` : aucun script, aucune
    # ressource tierce, pas de cadre, pas de cache, pas d'indexation,
    # référent `same-origin`). La page ne montre que ce que le formulaire
    # décrit ; aucune donnée du dossier.
    class PublicHandler < PartiduoUi::Handler
      alias Api = Forms::Api

      # Nom du champ piège, invisible pour une personne (D-FRM-007).
      TRAP = "website"

      def process_dispatch : Marten::HTTP::Response
        preflight || super
      rescue Marten::HTTP::Errors::RequestBodyTooBig
        too_large
      end

      def get
        view = Api.public_form(Partiduo::Api::Actor.anonymous, token) || return invalid_link
        show(view, {} of String => String, {} of String => Array(String))
      end

      def post
        return too_large if request.body.bytesize > Api::MAX_BODY_BYTES
        view = Api.public_form(Partiduo::Api::Actor.anonymous, token) || return invalid_link
        values = view.fields.to_h { |item| {item.key, field(item.key, strip: false)} }
        input = Api::SubmissionInput.new(values: values, files: uploaded_files, trap: !field(TRAP).empty?)
        result = Api.submit(Partiduo::Api::Actor.anonymous, token, input)
        if submitted = result.value?
          return render("forms/public_done.html", {"title" => view.title, "message" => submitted.message.presence},
            status: 200)
        end
        return invalid_link if result.error_keys.includes?("form.errors.link.invalid")
        status = result.errors.any?(&.key.starts_with?("form.errors.limits.")) ? 429 : 422
        show(view, values, errors_of(result), status)
      end

      private def token : String
        params["token"].to_s
      end

      # Adresse du client ; une valeur qui n'est pas une adresse IP (en-tête
      # forgé derrière un mandataire mal réglé) compte pour une seule clé,
      # sans grossir la table de limitation.
      private def ip : String
        address = PartiduoUi::RateLimit.client_ip(request)
        Socket::IPAddress.valid?(address) ? address : "invalide"
      end

      # Contrôles faits avant la protection CSRF et la lecture du corps ; le
      # débit par adresse de toutes les requêtes et la taille annoncée ont
      # été contrôlés par l'interface.
      private def preflight : Marten::HTTP::Response?
        return too_many if Throttle.exceeded?("invalid", ip)
        if request.post?
          return too_many unless Throttle.allow?("submit_ip", ip)
          return too_many unless Throttle.allow?("submit_link", Forms::Api.link_key(token))
        end
        nil
      end

      # Pièces envoyées (champ `files`, répété) ; une pièce trop grosse n'est
      # lue que jusqu'à la limite, pour être refusée par le contrat.
      private def uploaded_files : Array(Api::FileInput)
        values = request.data.fetch_all("files", [] of String) || [] of String
        values.first(Api::MAX_FILES + 1).compact_map do |value|
          next unless value.is_a?(Marten::HTTP::UploadedFile) && value.size > 0
          content = File.open(value.io.path) do |io|
            buffer = Bytes.new(Math.min(value.size, Api::MAX_FILE_BYTES + 1).to_i32)
            io.read_fully(buffer)
            buffer
          end
          Api::FileInput.new(filename: value.filename.to_s, content_type: "", content: content)
        end
      end

      private def show(view : Api::PublicFormView, values : Hash(String, String), errors : Hash(String, Array(String)),
                       status : Int32 = 200) : Marten::HTTP::Response
        fields = view.fields.map do |item|
          type = case item.kind
                 when "phone" then "text"
                 else              item.kind
                 end
          options = item.kind == "select" ? select_options(item) : nil
          value = values[item.key]? || ""
          value = "1" if item.kind == "checkbox" && (value == "1" || value == "on")
          ui_field = PartiduoUi::Form::Field.new(item.key, item.label, type, value, help: item.help.presence,
            required: item.required, options: options, maxlength: item.max_length > 1 ? item.max_length : nil)
          ui_field.errors = errors[item.key]?
          ui_field
        end
        render("forms/public.html", {
          "title"         => view.title,
          "description"   => view.description.presence,
          "purpose"       => view.purpose,
          "controller"    => view.controller,
          "accepts_files" => view.accepts_files,
          "fields"        => fields,
          "base_errors"   => errors["base"]?,
          "file_errors"   => errors["files"]?,
          "retention"     => I18n.t("form_ui.public.retention", count: view.retention_days),
          "files_help"    => I18n.t("form_ui.public.files_help", count: view.max_files,
            max: Api::MAX_FILE_BYTES // 1_048_576),
          "max_files_many" => view.max_files > 1,
        }, status: status)
      end

      private def select_options(item : Api::PublicFieldView) : Array(PartiduoUi::Form::Option)
        list = item.choices.map { |choice| PartiduoUi::Form::Option.new(choice, choice) }
        [PartiduoUi::Form::Option.new("", I18n.t("form_ui.public.choose"))] + list
      end

      private def invalid_link : Marten::HTTP::Response
        Throttle.record("invalid", ip)
        render("forms/public_invalid.html", status: 404)
      end

      private def too_many : Marten::HTTP::Response
        response = render("forms/public_invalid.html", {"limited" => true}, status: 429)
        response.headers["Retry-After"] = "900"
        response
      end

      private def too_large : Marten::HTTP::Response
        render("forms/public_invalid.html", {"too_large" => true}, status: 413)
      end
    end
  end
end

module Forms
  module Ui
    # `/f/<jeton>` : *ancienne* adresse de la page publique, gardée pour les
    # liens déjà remis au public (D-FRM-017). Redirection permanente `308`
    # vers `/p/form/<jeton>`, quelle que soit la méthode : un envoi depuis
    # une page affichée avant le changement d'adresse est renvoyé tel quel
    # (méthode et corps gardés, contrairement à `301` qui le changerait en
    # `GET` et perdrait la réponse) et la nouvelle adresse le contrôle
    # entièrement (débit, taille, CSRF, jeton, limite durable en base). Ce
    # handler ne lit ni le corps ni la base et ne vérifie pas le jeton
    # CSRF : il ne change rien ; la nouvelle adresse le vérifie.
    class LegacyPublicHandler < Marten::Handlers::Base
      protect_from_forgery false

      def dispatch : Marten::HTTP::Response
        location = "#{PartiduoUi::Extensions::PUBLIC_PREFIX}#{Forms::CODE.downcase}/" \
                   "#{URI.encode_path_segment(params["token"].to_s)}"
        response = Marten::HTTP::Response.new(content: "", content_type: "text/plain; charset=utf-8", status: 308)
        response.headers["Location"] = location
        PartiduoUi::Extensions::PUBLIC_HEADERS.each { |name, value| response.headers[name] = value }
        response
      ensure
        request.partiduo_form_mask_path(Ui::MASKED_LEGACY_PATH)
      end
    end
  end
end
