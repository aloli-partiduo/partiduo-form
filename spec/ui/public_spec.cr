# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Forms::SpecSupport
private alias Api = Forms::Api

# Dossier, utilisateurs, extension active, formulaire de contact et lien.
private def published(files : Bool = false, max_uses : Int32 = 50) : {Api::FormView, String}
  S.setup
  form = S.contact_form(files: files)
  {form, S.link(form, max_uses: max_uses).token}
end

private def body(values : Hash(String, String)) : String
  URI::Params.encode(values)
end

private def csrf_of(html : String) : String
  html.match(/name="csrftoken" value="([^"]+)"/).try(&.[1]) || raise "jeton CSRF absent de la page"
end

private def expect_secured(response : Marten::HTTP::Response) : Nil
  response.headers["Content-Security-Policy"].should contain("default-src 'none'")
  response.headers["Content-Security-Policy"].should contain("frame-ancestors 'none'")
  response.headers["Content-Security-Policy"].should_not contain("script-src")
  response.headers["Referrer-Policy"].should eq("same-origin")
  response.headers["Cache-Control"].should eq("no-store")
  response.headers["X-Robots-Tag"].should contain("noindex")
  response.headers["X-Frame-Options"].should eq("DENY")
  response.headers["X-Content-Type-Options"].should eq("nosniff")
end

describe "Page publique /f/<jeton> : surface sans authentification (D-FRM-007)" do
  it "affiche le formulaire, sa finalité, son responsable et sa conservation, sous des en-têtes stricts" do
    _form, token = published
    response = PartiduoUi::Browser.new.get("/f/#{token}")
    response.status.should eq(200)
    expect_secured(response)
    page = response.html
    page.should contain("<h1 class=\"pd-auth-title\">Demande de contact</h1>")
    page.should contain("Répondre à votre demande et ouvrir votre fiche client.")
    page.should contain("Atelier Brunet SARL, contact@atelier.example")
    page.should contain("Votre réponse est conservée 30 jours au plus, puis effacée.")
    page.should contain(%(name="courriel"))
    page.should contain(%(name="csrftoken"))
    page.should contain(%(name="website"))
    # Rien du dossier : ni SIREN, ni numéro de TVA, ni menu, ni utilisateur, ni script.
    page.should_not contain("732 829 320")
    page.should_not contain("FR 44")
    page.should_not contain("alice@example.com")
    page.should_not contain("pd-shell")
    page.should_not contain("<script")
    page.should_not contain(token)
  end

  it "refuse un jeton faux, mal formé, expiré ou révoqué par la même page 404, sans dire pourquoi" do
    form, token = published
    revoked = S.link(form)
    Api.revoke_link(S.manager, revoked.link.id).value!
    expiring = S.link(form, days: 0)
    pages = ["x" * 43, "court", "%27%20OR%201%3D1", revoked.token].map do |bad|
      response = PartiduoUi::Browser.new.get("/f/#{bad}")
      response.status.should eq(404)
      expect_secured(response)
      response.html
    end
    Partiduo::Config.travel_to(SPEC_NOW + 1.day) do
      pages << PartiduoUi::Browser.new.get("/f/#{expiring.token}").tap(&.status.should(eq(404))).html
    end
    pages.each { |page| page.should contain("Ce lien n'est pas valide ou n'est plus actif.") }
    pages.uniq.size.should eq(1)
    PartiduoUi::Browser.new.get("/f/#{token}").status.should eq(200)
  end

  it "bloque une adresse qui essaie trop de jetons, même avec un lien valide ensuite" do
    _form, token = published
    browser = PartiduoUi::Browser.new
    10.times { browser.get("/f/#{"y" * 43}").status.should eq(404) }
    blocked = browser.get("/f/#{token}")
    blocked.status.should eq(429)
    blocked.headers["Retry-After"].should eq("900")
    expect_secured(blocked)
    blocked.html.should contain("Trop de demandes")
  end

  it "accepte un envoi, le range dans la boîte de réception et remercie sans rappeler les valeurs" do
    _form, token = published
    response = PartiduoUi::Browser.new.post("/f/#{token}", S.values)
    response.status.should eq(200)
    expect_secured(response)
    response.html.should contain("Merci : votre réponse a bien été reçue.")
    response.html.should_not contain("camille@example.org")
    Api.responses(S.manager).size.should eq(1)
  end

  it "réaffiche le formulaire avec les erreurs et les valeurs saisies (422), échappées" do
    _form, token = published
    response = PartiduoUi::Browser.new.post("/f/#{token}", S.values({"courriel" => "<b>x", "nom" => "<script>alert(1)</script>"}))
    response.status.should eq(422)
    response.content.should_not contain("<script>alert(1)")
    response.content.should contain("&lt;script&gt;alert(1)&lt;/script&gt;")
    response.html.should contain("Adresse électronique invalide.")
    S.response_count.should eq(0)
  end

  it "exige le jeton CSRF : sans lui, ou depuis un autre site, l'envoi est refusé (403)" do
    _form, token = published
    browser = PartiduoUi::Browser.new
    page = browser.get("/f/#{token}")
    refused = browser.post_protected("/f/#{token}", body(S.values))
    refused.status.should eq(403)
    expect_secured(refused)
    forged = browser.post_protected("/f/#{token}", body(S.values.merge({"csrftoken" => csrf_of(page.content)})),
      headers: {"Origin" => "https://malveillant.example"})
    forged.status.should eq(403)
    S.response_count.should eq(0)

    # Un vrai navigateur envoie l'origine de la page (jamais `null`, la
    # politique de référent est `same-origin`) : l'envoi passe.
    accepted = browser.post_protected("/f/#{token}", body(S.values.merge({"csrftoken" => csrf_of(page.content)})),
      headers: {"Origin" => "http://127.0.0.1"})
    accepted.status.should eq(200)
    S.response_count.should eq(1)
    page.content.should_not contain(%(name="referrer"))
  end

  it "refuse un envoi trop gros (413) avant de le lire, et n'en garde rien" do
    _form, token = published(files: true)
    browser = PartiduoUi::Browser.new
    huge = browser.post("/f/#{token}", S.values({"message" => "x" * (Api::MAX_BODY_BYTES + 10)}))
    huge.status.should eq(413)
    expect_secured(huge)
    huge.html.should contain("Envoi trop volumineux")
    # Au-delà de la limite générale de Marten (2,5 Mo), le serveur refuse
    # la requête avant toute route.
    expect_raises(Marten::HTTP::Errors::RequestBodyTooBig) do
      browser.post("/f/#{token}", S.values({"message" => "x" * 3_000_000}))
    end
    S.response_count.should eq(0)
  end

  it "limite les envois par adresse (429) et par lien" do
    _form, token = published
    browser = PartiduoUi::Browser.new
    10.times { browser.post("/f/#{token}", S.values).status.should eq(200) }
    limited = browser.post("/f/#{token}", S.values)
    limited.status.should eq(429)
    expect_secured(limited)
    S.response_count.should eq(10)

    Forms::Ui::Throttle.reset!
    key = Api.link_key(token)
    key.should_not contain(token)
    20.times { Forms::Ui::Throttle.allow?("submit_link", key).should be_true }
    Forms::Ui::Throttle.allow?("submit_link", key).should be_false
  end

  it "masque le jeton dans le chemin que lit le journal du serveur" do
    raw = HTTP::Request.new("GET", "/f/#{"z" * 43}")
    Marten::HTTP::Request.new(raw).partiduo_form_mask_path(Forms::Ui::MASKED_PATH)
    raw.path.should eq("/f/…")
  end

  it "admet des pièces PDF et images, refuse un contenu déguisé" do
    _form, token = published(files: true)
    browser = PartiduoUi::Browser.new
    disguised = browser.post_multipart("/f/#{token}", S.values, [{"files", "facture.pdf", "application/pdf", S::HTML}])
    disguised.status.should eq(422)
    disguised.html.should contain("Seuls les fichiers PDF, PNG et JPEG sont acceptés.")
    accepted = browser.post_multipart("/f/#{token}", S.values, [{"files", "devis.pdf", "application/pdf", S::PDF}])
    accepted.status.should eq(200)
    Api.responses(S.manager).first.uploads.map(&.filename).should eq(["devis.pdf"])
  end

  it "remercie un robot qui remplit le champ piège sans rien garder" do
    _form, token = published
    response = PartiduoUi::Browser.new.post("/f/#{token}", S.values({"website" => "http://spam.example"}))
    response.status.should eq(200)
    response.html.should contain("Merci")
    S.response_count.should eq(0)
  end

  it "n'existe pas quand l'extension est inactive" do
    _form, token = published
    Partiduo::Api::Modules.deactivate(S.system, Forms::CODE).value!
    PartiduoUi::Browser.new.get("/f/#{token}").status.should eq(404)
  end
end
