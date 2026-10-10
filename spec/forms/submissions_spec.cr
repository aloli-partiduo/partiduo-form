# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Forms::SpecSupport
private alias Api = Forms::Api

describe "Formulaires : envoi public par jeton (D-FRM-007, D-FRM-008)" do
  it "ne montre au public que ce que le formulaire décrit" do
    S.setup
    form = S.contact_form
    view = Api.public_form(S.anonymous, S.link(form).token) || raise "formulaire attendu"
    view.title.should eq("Demande de contact")
    view.purpose.should contain("Répondre à votre demande")
    view.controller.should contain("Atelier Brunet")
    view.retention_days.should eq(30)
    view.fields.map(&.key).should eq(%w[nom courriel ville budget sujet message accord])
    view.fields.find!(&.key.==("sujet")).choices.should eq(["Devis", "Autre"])
    # Ni catégorie, ni cible, ni identifiant interne dans la vue publique.
    Api::PublicFormView.new(title: "", description: "", purpose: "", controller: "", retention_days: 1,
      accepts_files: false, max_files: 1, fields: [] of Api::PublicFieldView).to_s.should_not contain("category")
    Api::PublicFieldView.new(key: "", label: "", kind: "", required: false, max_length: 1, choices: [] of String, help: "")
      .to_s.should_not contain("target")
  end

  it "range la réponse dans la boîte de réception, sans fiche ni écriture, et compte l'envoi" do
    S.setup
    form = S.contact_form
    issued = S.link(form)
    cards_before = Partiduo::Api::Cards.count_cards(S.system)
    result = S.submit(issued.token)
    result.success?.should be_true
    response = Api.responses(S.manager).first
    response.status.should eq("received")
    response.values.map { |value| {value.key, value.value} }.to_h.should eq({
      "nom" => "Camille Martin", "courriel" => "camille@example.org", "ville" => "Lyon", "budget" => "1250.5",
      "sujet" => "Devis", "message" => "Bonjour,\nune question.", "accord" => "1",
    })
    response.purge_after.should eq(SPEC_NOW + 30.days)
    Partiduo::Api::Cards.count_cards(S.system).should eq(cards_before)
    Api.links(S.manager, form.id).first.uses.should eq(1)
    Api.pending_count(S.reader).should eq(1)
  end

  it "refuse un jeton faux, mal formé, expiré, révoqué ou épuisé, avec la même erreur" do
    S.setup
    form = S.contact_form
    count = S.response_count
    S.submit("x" * 43).error_keys.should eq(["form.errors.link.invalid"])
    S.submit("court").error_keys.should eq(["form.errors.link.invalid"])
    S.submit("../../etc/passwd").error_keys.should eq(["form.errors.link.invalid"])
    Api.public_form(S.anonymous, "' OR 1=1 --").should be_nil

    expiring = S.link(form, days: 0)
    Partiduo::Config.travel_to(SPEC_NOW + 1.day) do
      Api.public_form(S.anonymous, expiring.token).should be_nil
      S.submit(expiring.token).error_keys.should eq(["form.errors.link.invalid"])
    end

    revoked = S.link(form)
    Api.revoke_link(S.manager, revoked.link.id).value!
    S.submit(revoked.token).error_keys.should eq(["form.errors.link.invalid"])

    single = S.link(form, max_uses: 1)
    S.submit(single.token).success?.should be_true
    S.submit(single.token).error_keys.should eq(["form.errors.link.invalid"])
    Api.links(S.manager, form.id).find!(&.id.==(single.link.id)).state.should eq("exhausted")

    disabled = S.link(form)
    Api.update_form(S.manager, form.id, form.to_input.copy_with(enabled: false)).value!
    S.submit(disabled.token).error_keys.should eq(["form.errors.link.invalid"])
    S.response_count.should eq(count + 1)
  end

  it "contrôle chaque valeur selon sa nature, sans rien conserver d'un envoi refusé" do
    S.setup
    form = S.contact_form
    token = S.link(form).token
    result = S.submit(token, S.values({"nom" => "", "courriel" => "pas-une-adresse", "budget" => "1e9",
                                       "sujet" => "<script>", "accord" => ""}))
    result.errors.map { |error| {error.field, error.key} }.should eq([
      {"nom", "form.errors.value.required"},
      {"courriel", "form.errors.value.email"},
      {"budget", "form.errors.value.number"},
      {"sujet", "form.errors.value.choice"},
      {"accord", "form.errors.value.required"},
    ])
    S.submit(token, S.values({"nom" => "x" * 201})).error_keys.should eq(["form.errors.value.too_long"])
    S.submit(token, S.values({"nom" => String.new(Bytes[0x41, 0xFF, 0x42])})).error_keys.should eq(["form.errors.value.encoding"])
    S.response_count.should eq(0)
    Api.links(S.manager, form.id).first.uses.should eq(0)
  end

  it "nettoie les caractères de contrôle et ignore les clés inconnues" do
    S.setup
    form = S.contact_form
    S.submit(S.link(form).token, S.values({"nom" => "  Camille\u0000\u202E Martin\t", "admin" => "1",
                                           "status" => "accepted"})).success?.should be_true
    response = Api.responses(S.manager).first
    response.values.find!(&.key.==("nom")).value.should eq("Camille Martin")
    response.values.map(&.key).should_not contain("admin")
    response.status.should eq("received")
  end

  it "fait semblant d'accepter un envoi de robot (champ piège) sans rien conserver ni compter" do
    S.setup
    form = S.contact_form
    issued = S.link(form, max_uses: 1)
    S.submit(issued.token, trap: true).success?.should be_true
    S.response_count.should eq(0)
    Api.links(S.manager, form.id).first.uses.should eq(0)
  end

  it "limite les envois d'un lien par heure, en base" do
    S.setup
    form = S.contact_form
    token = S.link(form, max_uses: 100).token
    Api::HOURLY_LIMIT.times { S.submit(token).success?.should be_true }
    S.submit(token).error_keys.should eq(["form.errors.limits.hourly"])
    Partiduo::Config.travel_to(SPEC_NOW + 61.minutes) { S.submit(token).success?.should be_true }
  end

  it "contrôle les pièces jointes : admises ou non, nombre, taille, type reconnu au contenu" do
    S.setup
    closed = S.contact_form
    S.submit(S.link(closed).token, files: [S.file("devis.pdf", S::PDF)]).error_keys
      .should eq(["form.errors.files.not_accepted"])
    form = S.contact_form(files: true)
    token = S.link(form, max_uses: 20).token
    S.submit(token, files: [S.file("a.pdf", S::PDF), S.file("b.pdf", S::PDF), S.file("c.pdf", S::PDF)])
      .error_keys.should eq(["form.errors.files.too_many"])
    S.submit(token, files: [S.file("page.pdf", S::HTML)]).error_keys.should eq(["form.errors.files.type"])
    S.submit(token, files: [S.file("vide.pdf", "")]).error_keys.should eq(["form.errors.files.empty"])
    big = Api::FileInput.new(filename: "gros.pdf", content_type: "application/pdf",
      content: ("%PDF-" + "x" * Api::MAX_FILE_BYTES).to_slice)
    S.submit(token, files: [big]).error_keys.should eq(["form.errors.files.too_large"])

    S.submit(token, files: [S.file("../../Devis \"final\".exe", S::PDF), S.file("photo", S::PNG)]).success?.should be_true
    uploads = Api.responses(S.manager).first.uploads
    uploads.map(&.filename).should eq(["Devis _final_.pdf", "photo.png"])
    uploads.map(&.content_type).should eq(["application/pdf", "image/png"])
    uploads.all? { |upload| upload.attachment_id.nil? }.should be_true
  end

  it "refuse les envois quand la boîte de réception d'un formulaire est pleine" do
    S.setup
    form = S.contact_form
    token = S.link(form, max_uses: 1000).token
    Api::MAX_PENDING.times do |index|
      Partiduo::Config.travel_to(SPEC_NOW + (index // 25).hours) { S.submit(token).success?.should be_true }
    end
    Partiduo::Config.travel_to(SPEC_NOW + 20.hours) do
      S.submit(token).error_keys.should eq(["form.errors.limits.inbox_full"])
    end
  end
end
