# SPDX-License-Identifier: AGPL-3.0-or-later

# Exécute le bloc avec une autre liste de modules actifs (`PARTIDUO_MODULES`),
# puis restaure la configuration.
def with_active_modules(codes : String?, &)
  previous = ENV["PARTIDUO_MODULES"]?
  codes.nil? ? ENV.delete("PARTIDUO_MODULES") : (ENV["PARTIDUO_MODULES"] = codes)
  yield
ensure
  previous.nil? ? ENV.delete("PARTIDUO_MODULES") : (ENV["PARTIDUO_MODULES"] = previous)
end

# La limitation de débit de la page publique est tenue en mémoire : chaque
# exemple repart de zéro.
Spec.before_each { Forms::Ui::Throttle.reset! }

class PartiduoUi::Browser
  # Formulaire `multipart/form-data` (pièces jointes) : `files` donne, pour
  # chaque pièce, {nom du champ, nom du fichier, type, contenu}.
  def post_multipart(path : String, fields : Hash(String, String),
                     files = [] of {String, String, String, String},
                     headers = {} of String => String) : Marten::HTTP::Response
    io = IO::Memory.new
    builder = HTTP::FormData::Builder.new(io, "partiduo-spec-boundary")
    fields.each { |name, value| builder.field(name, value) }
    files.each do |(name, filename, type, content)|
      builder.file(name, IO::Memory.new(content), HTTP::FormData::FileMetadata.new(filename: filename),
        HTTP::Headers{"Content-Type" => type})
    end
    builder.finish
    content_type = builder.content_type
    perform { |client| client.post(path, data: io.to_s, content_type: content_type, headers: @headers.merge(headers)) }
  end

  # Requête avec la protection CSRF *active*, comme un vrai navigateur
  # (le client de test de Marten la désactive par défaut).
  def post_protected(path : String, body : String, content_type : String = FORM,
                     headers = {} of String => String) : Marten::HTTP::Response
    client = Marten::Spec::Client.new(disable_request_forgery_protection: false)
    @jar.each { |name, value| client.cookies[name] = value }
    response = client.post(path, data: body, content_type: content_type, headers: @headers.merge(headers))
    client.cookies.each { |(name, value)| value.empty? ? @jar.delete(name) : (@jar[name] = value) }
    response
  end
end

module Forms
  # Outils des specs : dossier provisionné par le contrat du cœur,
  # extension activée, acteurs, formulaire de contact et lien public.
  module SpecSupport
    alias Api = Forms::Api

    PDF  = "%PDF-1.7\n1 0 obj << >> endobj\n%%EOF\n"
    PNG  = "\x89PNG\r\n\x1A\n\x00\x00\x00\rIHDR"
    HTML = "<html><script>alert(1)</script></html>"

    CORE_PERMISSIONS = ["cards.card.read", "cards.card.write", "core.attachment.read", "core.attachment.write"]

    def self.system : Partiduo::Api::Actor
      Partiduo::Api::Actor.system
    end

    def self.anonymous : Partiduo::Api::Actor
      Partiduo::Api::Actor.anonymous
    end

    def self.setup : Nil
      PartiduoUi::Reference.provision
      user("alice@example.com", "Alice")
      user("bruno@example.com", "Bruno")
      activate
    end

    def self.activate : Nil
      Partiduo::Api::Modules.activate(system, Forms::CODE).value!
    end

    def self.user(email : String, first_name : String) : Int64
      input = Partiduo::Api::Auth::UserInput.new(email: email, first_name: first_name, last_name: "Test", role: "member",
        profile_id: PartiduoUi::Accounts.profile_id("ADMIN"), password: PartiduoUi::Accounts::PASSWORD)
      Partiduo::Api::Auth.create_user(system, input).value!.user.id
    end

    def self.user_id(email : String) : Int64
      Partiduo::Api::Auth.user_by_email(system, email).try(&.id) || raise "utilisateur #{email} absent"
    end

    def self.actor(email : String, permissions : Array(String)) : Partiduo::Api::Actor
      Partiduo::Api::Actor.user(user_id(email), permissions, level: 3)
    end

    # Tous les droits de l'extension et ceux du cœur qu'elle emploie.
    def self.manager : Partiduo::Api::Actor
      actor("alice@example.com", [Api::READ, Api::PROCESS, Api::DESIGN, Api::ADMIN] + CORE_PERMISSIONS)
    end

    # Traite les réponses, sans définir ni émettre de lien.
    def self.processor(core : Array(String) = CORE_PERMISSIONS) : Partiduo::Api::Actor
      actor("bruno@example.com", [Api::READ, Api::PROCESS] + core)
    end

    def self.reader : Partiduo::Api::Actor
      actor("bruno@example.com", [Api::READ])
    end

    def self.category(code : String = "CUSTOMER") : Partiduo::Api::Cards::CategoryView
      PartiduoUi::Reference.category(code)
    end

    # Formulaire de contact vers la catégorie des clients : nom, courriel,
    # ville, message, consentement ; pièces admises si `files`.
    def self.contact_form(files : Bool = false, retention : Int32 = 30) : Api::FormView
      input = Api::FormInput.new(title: "Demande de contact", purpose: "Répondre à votre demande et ouvrir votre fiche client.",
        controller: "Atelier Brunet SARL, contact@atelier.example", description: "Écrivez-nous.",
        retention_days: retention, category_id: category.id, accepts_files: files, max_files: 2)
      form = Api.create_form(manager, input).value!
      [
        Api::FieldInput.new(key: "nom", label: "Nom", required: true, target: "name"),
        Api::FieldInput.new(key: "courriel", label: "Courriel", kind: "email", required: true, target: "email"),
        Api::FieldInput.new(key: "ville", label: "Ville", target: "address.city"),
        Api::FieldInput.new(key: "budget", label: "Budget", kind: "number"),
        Api::FieldInput.new(key: "sujet", label: "Sujet", kind: "select", choices: "Devis\nAutre"),
        Api::FieldInput.new(key: "message", label: "Message", kind: "textarea"),
        Api::FieldInput.new(key: "accord", label: "J'accepte d'être recontacté", kind: "checkbox", required: true),
      ].each { |field| Api.add_field(manager, form.id, field).value! }
      Api.form(manager, form.id)
    end

    def self.link(form : Api::FormView, max_uses : Int32 = 5, days : Int32 = 30) : Api::IssuedLinkView
      Api.create_link(manager, form.id, Api::LinkInput.new(expires_on: Partiduo::Config.today + days.days,
        max_uses: max_uses, label: "Site")).value!
    end

    def self.values(extra = {} of String => String) : Hash(String, String)
      {"nom" => "Camille Martin", "courriel" => "camille@example.org", "ville" => "Lyon", "budget" => "1 250,50",
       "sujet" => "Devis", "message" => "Bonjour,\nune question.", "accord" => "1"}.merge(extra)
    end

    def self.submit(token : String, values = self.values, files = [] of Api::FileInput,
                    trap : Bool = false) : Partiduo::Api::Result(Api::SubmittedView)
      Api.submit(anonymous, token, Api::SubmissionInput.new(values: values, files: files, trap: trap))
    end

    def self.file(name : String, content : String) : Api::FileInput
      Api::FileInput.new(filename: name, content_type: "application/octet-stream", content: content.to_slice)
    end

    def self.response_count : Int64
      Forms::Response.all.count.to_i64
    end
  end
end

# Le journal de l'extension (envois, refus, purges) est vérifié par les
# exemples, pas affiché.
::Log.for("partiduo.form").level = ::Log::Severity::Error
