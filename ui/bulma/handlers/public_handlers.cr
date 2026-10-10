# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  module Ui
    # `/f/<jeton>` : page publique d'un formulaire, seule surface de
    # Partiduo ouverte sans authentification (D-FRM-007). Dans l'ordre :
    #
    # . limitation de débit : adresse bloquée après trop de jetons refusés,
    #   affichages par adresse, envois par adresse et par lien (429) ;
    # . taille : un envoi plus gros que `Api::MAX_BODY_BYTES` est refusé
    #   (413) avant toute lecture du corps ;
    # . protection CSRF de Marten (jeton du formulaire, origine) : un envoi
    #   depuis un autre site est refusé (403) ;
    # . jeton : inconnu, expiré, révoqué, épuisé ou formulaire désactivé,
    #   même page « lien non valide » (404) ;
    # . contrôle des valeurs et des pièces par le contrat, qui ne range la
    #   réponse que dans la boîte de réception.
    #
    # Toute réponse porte des en-têtes de sécurité stricts (aucun script,
    # aucune ressource tierce, pas de cadre, pas de cache, pas d'indexation,
    # pas de référent : le jeton est dans l'adresse). La page ne montre que
    # ce que le formulaire décrit ; aucune donnée du dossier.
    class PublicHandler < PartiduoUi::Handler
      alias Api = Forms::Api

      SECURITY_HEADERS = {
        "Content-Security-Policy" => "default-src 'none'; style-src 'self'; font-src 'self'; img-src 'self' data:; " \
                                     "form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
        # `same-origin` et non `no-referrer` : sous `no-referrer`, le
        # navigateur envoie `Origin: null` avec le formulaire, que la
        # protection CSRF refuserait ; le jeton ne part toujours vers
        # aucun autre site.
        "Referrer-Policy"              => "same-origin",
        "Cache-Control"                => "no-store",
        "Pragma"                       => "no-cache",
        "X-Robots-Tag"                 => "noindex, nofollow, noarchive",
        "X-Frame-Options"              => "DENY",
        "X-Content-Type-Options"       => "nosniff",
        "Permissions-Policy"           => "camera=(), microphone=(), geolocation=(), payment=(), usb=()",
        "Cross-Origin-Resource-Policy" => "same-origin",
        "Cross-Origin-Opener-Policy"   => "same-origin",
      }

      # Nom du champ piège, invisible pour une personne (D-FRM-007).
      TRAP = "website"

      def process_dispatch : Marten::HTTP::Response
        secured(preflight || super)
      rescue Marten::HTTP::Errors::RequestBodyTooBig
        secured(too_large)
      ensure
        # Le journal des requêtes du serveur écrit le chemin *après* la
        # réponse : il n'y verra que `/f/…` et jamais le jeton (D-FRM-015).
        request.partiduo_form_mask_path(Ui::MASKED_PATH)
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

      # Contrôles faits avant la protection CSRF et la lecture du corps.
      private def preflight : Marten::HTTP::Response?
        return too_many if Throttle.exceeded?("invalid", ip)
        if request.post?
          length = request.headers["Content-Length"]?.try(&.to_i64?)
          return too_large if length && length > Api::MAX_BODY_BYTES
          return too_many unless Throttle.allow?("submit_ip", ip)
          return too_many unless Throttle.allow?("submit_link", Forms::Api.link_key(token))
        else
          return too_many unless Throttle.allow?("view", ip)
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

      private def secured(response : Marten::HTTP::Response) : Marten::HTTP::Response
        SECURITY_HEADERS.each { |name, value| response.headers[name] = value }
        response
      end
    end
  end
end
