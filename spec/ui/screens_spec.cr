# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Forms::SpecSupport
private alias Api = Forms::Api

# Administrateur connecté (profil ADMIN : toutes les permissions), dossier
# provisionné, extension active.
private def signed_in : PartiduoUi::Browser
  browser = PartiduoUi::Books.admin
  S.user("bruno@example.com", "Bruno")
  S.activate
  browser
end

describe "Écrans des formulaires sous /ext/FORM/ (ADR-005)" do
  it "est montée sous le code de l'extension, avec ses permissions par route, et la page publique hors montage" do
    Marten.routes.reverse("form:inbox").should eq("/ext/FORM/inbox")
    Marten.routes.reverse("form_public", token: "abc").should eq("/f/abc")
    mount = PartiduoUi::Extensions["FORM"]? || raise("interface non montée")
    mount.permission.should eq("form.read")
    mount.permission_for("form:inbox").should eq("form.read")
    mount.permission_for("form:response_accept").should eq("form.process")
    mount.permission_for("form:file").should eq("form.process")
    mount.permission_for("form:form_new").should eq("form.design")
    mount.permission_for("form:link_new").should eq("form.admin")
    mount.permission_for("form:purge").should eq("form.admin")
  end

  it "n'existe pas tant que l'extension est inactive (404) et renvoie un anonyme vers la connexion" do
    browser = PartiduoUi::Books.admin
    browser.get("/ext/FORM/inbox").status.should eq(404)
    S.activate
    response = PartiduoUi::Browser.new.get("/ext/FORM/inbox")
    response.status.should eq(302)
    response.headers["Location"].should eq("/login?next=%2Fext%2FFORM%2Finbox")
  end

  it "définit un formulaire, ajoute ses champs, émet un lien montré une fois, reçoit puis accepte une réponse" do
    browser = signed_in
    browser.get("/ext/FORM/").headers["Location"].should eq("/ext/FORM/inbox")
    browser.get("/ext/FORM/forms").html.should contain("Aucun formulaire")

    refused = browser.post("/ext/FORM/forms/new", {"title" => "Contact", "purpose" => "", "controller" => "",
                                                   "retention_days" => "90", "max_files" => "1", "enabled" => "1"})
    refused.status.should eq(422)
    created = browser.post("/ext/FORM/forms/new", {"title" => "Contact", "purpose" => "Vous recontacter.",
                                                   "controller" => "Atelier Brunet", "retention_days" => "60",
                                                   "category_id" => S.category.id.to_s, "max_files" => "1",
                                                   "enabled" => "1"})
    created.status.should eq(302)
    form_url = created.headers["Location"]
    form_id = PartiduoUi::Reference.id_from(form_url)
    page = browser.follow(created).html
    page.should contain("<h1>Contact")
    page.should contain("Aucun champ.")

    browser.post("/ext/FORM/forms/#{form_id}/fields/new", {"label" => "Nom", "key" => "nom", "kind" => "text",
                                                           "required" => "1", "target" => "name"}).status.should eq(302)
    browser.post("/ext/FORM/forms/#{form_id}/fields/new", {"label" => "Courriel", "key" => "courriel",
                                                           "kind" => "email", "target" => "email"}).status.should eq(302)
    bad = browser.post("/ext/FORM/forms/#{form_id}/fields/new", {"label" => "X", "key" => "Nom!", "kind" => "text"})
    bad.status.should eq(422)
    bad.html.should contain("La clé commence par une lettre minuscule")

    issued = browser.post("/ext/FORM/forms/#{form_id}/links/new", {"label" => "Site", "expires_on" => "2026-11-30",
                                                                   "max_uses" => "3"})
    issued.status.should eq(200)
    issued.headers["Cache-Control"].should eq("no-store")
    issued.html.should contain("ne sera plus jamais affichée")
    token = issued.html.match(%r{/f/([A-Za-z0-9_-]{43})}).try(&.[1]) || raise "lien absent"
    detail = browser.get(form_url).html
    detail.should contain("#{token[0, 4]}…")
    detail.should_not contain(token)

    PartiduoUi::Browser.new.post("/f/#{token}", {"nom" => "Camille Martin", "courriel" => "camille@example.org"})
      .status.should eq(200)

    inbox = browser.get("/ext/FORM/inbox").html
    inbox.should contain("Camille Martin")
    response_id = Api.responses(S.manager).first.id
    shown = browser.get("/ext/FORM/responses/#{response_id}").html
    shown.should contain("Réponse n° #{response_id}")
    shown.should contain("Créer la fiche")

    draft = browser.get("/ext/FORM/responses/#{response_id}/accept").html
    draft.should contain(%(value="Camille Martin"))
    draft.should contain(%(value="camille@example.org"))
    accepted = browser.post("/ext/FORM/responses/#{response_id}/accept", {"name"  => "Camille MARTIN",
                                                                          "email" => "camille@example.org"})
    accepted.status.should eq(302)
    browser.follow(accepted).html.should contain("Fiche créée ; la réponse est traitée.")
    card_id = Api.response(S.manager, response_id).card_id || raise "fiche attendue"
    Partiduo::Api::Cards.card(S.system, card_id).name.should eq("Camille MARTIN")
  end

  it "télécharge une pièce reçue en pièce jointe, sans interprétation par le navigateur" do
    browser = signed_in
    form = S.contact_form(files: true)
    S.submit(S.link(form).token, files: [S.file("devis.pdf", S::PDF)]).value!
    upload = Api.responses(S.manager).first.uploads.first
    response = browser.get("/ext/FORM/files/#{upload.id}")
    response.status.should eq(200)
    response.headers["Content-Disposition"].should eq(%(attachment; filename="devis.pdf"))
    response.headers["Content-Security-Policy"].should contain("sandbox")
    response.headers["X-Content-Type-Options"].should eq("nosniff")
    response.content.should eq(S::PDF)
  end

  it "classe, rejette, efface et purge depuis la boîte de réception" do
    browser = signed_in
    form = S.contact_form
    token = S.link(form).token
    2.times { S.submit(token).value! }
    first, second = Api.responses(S.manager).map(&.id)
    browser.post("/ext/FORM/responses/#{first}/close", {"note" => ""}).status.should eq(302)
    browser.post("/ext/FORM/responses/#{second}/reject", {"note" => ""}).status.should eq(302)
    browser.get("/ext/FORM/inbox").html.should contain("Aucune réponse.")
    browser.get("/ext/FORM/inbox?status=all").html.should contain("Rejetée")
    browser.post("/ext/FORM/responses/#{first}/delete", {} of String => String).status.should eq(302)
    Partiduo::Config.travel_to(SPEC_NOW + 31.days) do
      browser.post("/ext/FORM/inbox/purge", {} of String => String).status.should eq(302)
    end
    S.response_count.should eq(0)
  end
end
