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

describe "Page publique /p/form/<jeton> : surface sans authentification (D-FRM-007, D-FRM-017)" do
  it "affiche le formulaire, sa finalité, son responsable et sa conservation, sous des en-têtes stricts" do
    _form, token = published
    response = PartiduoUi::Browser.new.get("/p/form/#{token}")
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

  it "parle la langue du navigateur du visiteur : de-DE obtient le formulaire en allemand (D-UI-080)" do
    _form, token = published
    response = PartiduoUi::Browser.new("de-DE").get("/p/form/#{token}")
    response.status.should eq(200)
    expect_secured(response)
    page = response.html
    page.should contain(%(<html lang="de">))
    page.should contain("Ihre Antwort wird höchstens 30 Tage aufbewahrt und dann gelöscht.")
    page.should contain("Verantwortlicher")
    page.should_not contain("Votre réponse est conservée")
    # Le contenu saisi par le dossier (titre, finalité) reste dans sa langue.
    page.should contain("<h1 class=\"pd-auth-title\">Demande de contact</h1>")
    PartiduoUi::Browser.new("de-DE").get("/p/form/#{"x" * 43}").html
      .should contain("Dieser Link ist ungültig oder nicht mehr aktiv.")
  end

  it "refuse un jeton faux, mal formé, expiré ou révoqué par la même page 404, sans dire pourquoi" do
    form, token = published
    revoked = S.link(form)
    Api.revoke_link(S.manager, revoked.link.id).value!
    expiring = S.link(form, days: 0)
    pages = ["x" * 43, "court", "%27%20OR%201%3D1", revoked.token].map do |bad|
      response = PartiduoUi::Browser.new.get("/p/form/#{bad}")
      response.status.should eq(404)
      expect_secured(response)
      response.html
    end
    Partiduo::Config.travel_to(SPEC_NOW + 1.day) do
      pages << PartiduoUi::Browser.new.get("/p/form/#{expiring.token}").tap(&.status.should(eq(404))).html
    end
    pages.each { |page| page.should contain("Ce lien n'est pas valide ou n'est plus actif.") }
    pages.uniq.size.should eq(1)
    PartiduoUi::Browser.new.get("/p/form/#{token}").status.should eq(200)
  end

  it "bloque une adresse qui essaie trop de jetons, même avec un lien valide ensuite" do
    _form, token = published
    browser = PartiduoUi::Browser.new
    10.times { browser.get("/p/form/#{"y" * 43}").status.should eq(404) }
    blocked = browser.get("/p/form/#{token}")
    blocked.status.should eq(429)
    blocked.headers["Retry-After"].should eq("900")
    expect_secured(blocked)
    blocked.html.should contain("Trop de demandes")
  end

  it "accepte un envoi, le range dans la boîte de réception et remercie sans rappeler les valeurs" do
    _form, token = published
    response = PartiduoUi::Browser.new.post("/p/form/#{token}", S.values)
    response.status.should eq(200)
    expect_secured(response)
    response.html.should contain("Merci : votre réponse a bien été reçue.")
    response.html.should_not contain("camille@example.org")
    Api.responses(S.manager).size.should eq(1)
  end

  it "réaffiche le formulaire avec les erreurs et les valeurs saisies (422), échappées" do
    _form, token = published
    response = PartiduoUi::Browser.new.post("/p/form/#{token}", S.values({"courriel" => "<b>x", "nom" => "<script>alert(1)</script>"}))
    response.status.should eq(422)
    response.content.should_not contain("<script>alert(1)")
    response.content.should contain("&lt;script&gt;alert(1)&lt;/script&gt;")
    response.html.should contain("Adresse électronique invalide.")
    S.response_count.should eq(0)
  end

  it "exige le jeton CSRF : sans lui, ou depuis un autre site, l'envoi est refusé (403)" do
    _form, token = published
    browser = PartiduoUi::Browser.new
    page = browser.get("/p/form/#{token}")
    refused = browser.post_protected("/p/form/#{token}", body(S.values))
    refused.status.should eq(403)
    expect_secured(refused)
    forged = browser.post_protected("/p/form/#{token}", body(S.values.merge({"csrftoken" => csrf_of(page.content)})),
      headers: {"Origin" => "https://malveillant.example"})
    forged.status.should eq(403)
    S.response_count.should eq(0)

    # Un vrai navigateur envoie l'origine de la page (jamais `null`, la
    # politique de référent est `same-origin`) : l'envoi passe.
    accepted = browser.post_protected("/p/form/#{token}", body(S.values.merge({"csrftoken" => csrf_of(page.content)})),
      headers: {"Origin" => "http://127.0.0.1"})
    accepted.status.should eq(200)
    S.response_count.should eq(1)
    page.content.should_not contain(%(name="referrer"))
  end

  it "refuse un envoi trop gros (413) avant de le lire, et n'en garde rien" do
    _form, token = published(files: true)
    browser = PartiduoUi::Browser.new
    huge = browser.post("/p/form/#{token}", S.values({"message" => "x" * (Api::MAX_BODY_BYTES + 10)}))
    huge.status.should eq(413)
    expect_secured(huge)
    huge.html.should contain("Envoi trop volumineux")
    huge.html.should_not contain("<script")
    # Au-delà de la limite générale de Marten (2,5 Mo), le serveur refuse
    # la requête avant toute route.
    expect_raises(Marten::HTTP::Errors::RequestBodyTooBig) do
      browser.post("/p/form/#{token}", S.values({"message" => "x" * 3_000_000}))
    end
    S.response_count.should eq(0)
  end

  it "limite les envois par adresse (429) et par lien" do
    _form, token = published
    browser = PartiduoUi::Browser.new
    10.times { browser.post("/p/form/#{token}", S.values).status.should eq(200) }
    limited = browser.post("/p/form/#{token}", S.values)
    limited.status.should eq(429)
    expect_secured(limited)
    S.response_count.should eq(10)

    Forms::Ui::Throttle.reset!
    key = Api.link_key(token)
    key.should_not contain(token)
    20.times { Forms::Ui::Throttle.allow?("submit_link", key).should be_true }
    Forms::Ui::Throttle.allow?("submit_link", key).should be_false
  end

  it "masque le jeton dans le chemin que lit le journal du serveur, même quand l'interface répond seule" do
    _form, token = published
    raw = HTTP::Request.new("GET", "/p/form/#{token}")
    request = Marten::HTTP::Request.new(raw)
    PartiduoUi::PublicExtensionHandler.new(request, code: "form", path: token).process_dispatch
      .status.should eq(200)
    raw.path.should eq("/p/form/…")

    # Refus de l'interface avant le handler de l'extension (inactive : 404).
    Partiduo::Api::Modules.deactivate(S.system, Forms::CODE).value!
    raw = HTTP::Request.new("GET", "/p/form/#{token}")
    request = Marten::HTTP::Request.new(raw)
    PartiduoUi::PublicExtensionHandler.new(request, code: "form", path: token).process_dispatch
      .status.should eq(404)
    raw.path.should eq("/p/form/…")

    raw = HTTP::Request.new("GET", "/f/#{token}")
    Forms::Ui::LegacyPublicHandler.new(Marten::HTTP::Request.new(raw), token: token).process_dispatch
    raw.path.should eq("/f/…")
  end

  it "applique le débit par adresse de l'interface à toute la route (429)" do
    _form, token = published
    browser = PartiduoUi::Browser.new
    Forms::Ui::PUBLIC_RATE.limit.times { browser.get("/p/form/#{token}").status.should eq(200) }
    limited = browser.get("/p/form/#{token}")
    limited.status.should eq(429)
    limited.headers["Retry-After"].should eq("600")
    expect_secured(limited)
  end

  it "admet des pièces PDF et images, refuse un contenu déguisé" do
    _form, token = published(files: true)
    browser = PartiduoUi::Browser.new
    disguised = browser.post_multipart("/p/form/#{token}", S.values, [{"files", "facture.pdf", "application/pdf", S::HTML}])
    disguised.status.should eq(422)
    disguised.html.should contain("Seuls les fichiers PDF, PNG et JPEG sont acceptés.")
    accepted = browser.post_multipart("/p/form/#{token}", S.values, [{"files", "devis.pdf", "application/pdf", S::PDF}])
    accepted.status.should eq(200)
    Api.responses(S.manager).first.uploads.map(&.filename).should eq(["devis.pdf"])
  end

  it "remercie un robot qui remplit le champ piège sans rien garder" do
    _form, token = published
    response = PartiduoUi::Browser.new.post("/p/form/#{token}", S.values({"website" => "http://spam.example"}))
    response.status.should eq(200)
    response.html.should contain("Merci")
    S.response_count.should eq(0)
  end

  it "n'existe pas quand l'extension est inactive" do
    _form, token = published
    Partiduo::Api::Modules.deactivate(S.system, Forms::CODE).value!
    PartiduoUi::Browser.new.get("/p/form/#{token}").status.should eq(404)
  end
end

describe "Ancienne adresse /f/<jeton> des liens déjà remis (D-FRM-017)" do
  it "redirige un affichage vers /p/form/<jeton> (308), sous des en-têtes stricts, sans lire la base" do
    _form, token = published
    browser = PartiduoUi::Browser.new
    moved = browser.get("/f/#{token}")
    moved.status.should eq(308)
    moved.headers["Location"].should eq("/p/form/#{token}")
    expect_secured(moved)
    page = browser.follow(moved)
    page.status.should eq(200)
    page.html.should contain("Demande de contact")
    # Le jeton n'est contrôlé qu'à la nouvelle adresse : un faux jeton est
    # redirigé, puis refusé là (404).
    bad = browser.get("/f/#{"y" * 43}")
    bad.status.should eq(308)
    browser.follow(bad).status.should eq(404)
  end

  it "garde méthode et corps d'un envoi (308) : la nouvelle adresse le reçoit et le contrôle" do
    _form, token = published
    browser = PartiduoUi::Browser.new
    moved = browser.post("/f/#{token}", S.values)
    moved.status.should eq(308)
    moved.headers["Location"].should eq("/p/form/#{token}")
    S.response_count.should eq(0)
    browser.post(moved.headers["Location"], S.values).status.should eq(200)
    S.response_count.should eq(1)
  end

  it "laisse la protection CSRF à la nouvelle adresse : un envoi d'une page affichée sous /f/ passe après la redirection" do
    _form, token = published
    browser = PartiduoUi::Browser.new
    # Page affichée à l'ancienne adresse avant le changement : même jeton
    # CSRF, même cookie, même origine.
    page = browser.follow(browser.get("/f/#{token}"))
    csrf = csrf_of(page.content)
    moved = browser.post_protected("/f/#{token}", body(S.values.merge({"csrftoken" => csrf})),
      headers: {"Origin" => "http://127.0.0.1"})
    moved.status.should eq(308)
    forged = browser.post_protected(moved.headers["Location"], body(S.values.merge({"csrftoken" => csrf})),
      headers: {"Origin" => "https://malveillant.example"})
    forged.status.should eq(403)
    accepted = browser.post_protected(moved.headers["Location"], body(S.values.merge({"csrftoken" => csrf})),
      headers: {"Origin" => "http://127.0.0.1"})
    accepted.status.should eq(200)
    S.response_count.should eq(1)
  end

  it "ne redirige jamais hors de /p/form/ : le jeton est encodé dans le chemin" do
    moved = PartiduoUi::Browser.new.get("/f/%2F%2Fmalveillant.example")
    location = moved.headers["Location"]? || ""
    location.should start_with("/p/form/") if moved.status == 308
    location.should_not contain("//malveillant")
  end

  it "garde la limite durable en base : au-delà des envois par lien et par heure, refus (429)" do
    _form, token = published(max_uses: 1000)
    Api::HOURLY_LIMIT.times do |index|
      S.submit(token, S.values({"nom" => "Personne #{index}"})).value!
    end
    browser = PartiduoUi::Browser.new
    moved = browser.post("/f/#{token}", S.values)
    moved.status.should eq(308)
    limited = browser.post(moved.headers["Location"], S.values)
    limited.status.should eq(429)
    S.response_count.should eq(Api::HOURLY_LIMIT)
  end
end
