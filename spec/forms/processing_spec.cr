# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Forms::SpecSupport
private alias Api = Forms::Api

private def received(files = [] of Api::FileInput) : Api::ResponseView
  form = S.contact_form(files: !files.empty?)
  S.submit(S.link(form).token, files: files).value!
  Api.responses(S.manager).first
end

describe "Formulaires : traitement par un utilisateur authentifié (D-FRM-010, D-FRM-011)" do
  it "propose la fiche d'après les cibles des champs, puis la crée par le contrat des fiches" do
    S.setup
    response = received
    draft = Api.card_draft(S.processor, response.id) || raise "fiche proposée attendue"
    draft.category_id.should eq(S.category.id)
    draft.name.should eq("Camille Martin")
    draft.email.should eq("camille@example.org")
    draft.address.try(&.city).should eq("Lyon")

    accepted = Api.accept(S.processor, response.id, draft).value!
    accepted.status.should eq("accepted")
    card = Partiduo::Api::Cards.card(S.system, accepted.card_id || raise "fiche attendue")
    card.name.should eq("Camille Martin")
    card.email.should eq("camille@example.org")
    accepted.processed_by_id.should eq(S.user_id("bruno@example.com"))
    Api.accept(S.processor, response.id, draft).error_keys.should eq(["form.errors.response.processed"])
    Api.pending_count(S.reader).should eq(0)
  end

  it "crée la fiche avec les droits de l'acteur réel : sans cards.card.write, refus" do
    S.setup
    response = received
    draft = Api.card_draft(S.processor, response.id) || raise "fiche proposée attendue"
    expect_raises(Partiduo::Api::Forbidden) { Api.accept(S.processor([] of String), response.id, draft) }
    expect_raises(Partiduo::Api::Forbidden) { Api.accept(S.reader, response.id, draft) }
    Api.response(S.manager, response.id).status.should eq("received")
  end

  it "rend les erreurs du contrat des fiches et ne change rien" do
    S.setup
    response = received
    draft = Api.card_draft(S.processor, response.id) || raise "fiche proposée attendue"
    result = Api.accept(S.processor, response.id, draft.copy_with(name: ""))
    result.failure?.should be_true
    Api.response(S.manager, response.id).status.should eq("received")
  end

  it "verse les pièces reçues au dossier par store_attachment, avec l'acteur" do
    S.setup
    response = received([S.file("devis.pdf", S::PDF)])
    draft = Api.card_draft(S.processor, response.id) || raise "fiche proposée attendue"
    without = S.processor(["cards.card.read", "cards.card.write"])
    Api.accept(without, response.id, draft).error_keys.should eq(["form.errors.files.forbidden"])
    accepted = Api.accept(S.processor, response.id, draft).value!
    attachment_id = accepted.uploads.first.attachment_id || raise "pièce versée attendue"
    view = Partiduo::Api::Core.attachment(S.system, attachment_id)
    view.filename.should eq("devis.pdf")
    view.uploaded_by_id.should eq(S.user_id("bruno@example.com"))
    String.new(Api.file(S.processor, accepted.uploads.first.id).content).should eq(S::PDF)
  end

  it "classe ou rejette une réponse sans fiche ; le téléchargement d'une pièce exige form.process" do
    S.setup
    response = received([S.file("devis.pdf", S::PDF)])
    expect_raises(Partiduo::Api::Forbidden) { Api.file(S.reader, response.uploads.first.id) }
    String.new(Api.file(S.processor, response.uploads.first.id).content).should eq(S::PDF)
    closed = Api.close(S.processor, response.id, "Déjà client").value!
    closed.status.should eq("closed")
    closed.note.should eq("Déjà client")
    Api.reject(S.processor, response.id).error_keys.should eq(["form.errors.response.processed"])
    Forms::Upload.all.count.should eq(1)
  end

  it "efface aussitôt les pièces en quarantaine d'une réponse rejetée" do
    S.setup
    response = received([S.file("devis.pdf", S::PDF)])
    Api.reject(S.processor, response.id).value!.uploads.should be_empty
    Forms::Upload.all.count.should eq(0)
  end

  it "purge les réponses échues, à la lecture de la boîte comme à la demande" do
    S.setup
    form = S.contact_form(retention: 10)
    token = S.link(form).token
    S.submit(token).value!
    Partiduo::Config.travel_to(SPEC_NOW + 5.days) { S.submit(token).value! }
    Partiduo::Config.travel_to(SPEC_NOW + 11.days) do
      Api.responses(S.manager, Api::ResponseQuery.new(status: nil)).size.should eq(1)
      S.response_count.should eq(1)
    end
    expect_raises(Partiduo::Api::Forbidden) { Api.purge(S.processor) }
    Api.purge(S.manager, SPEC_NOW + 16.days).should eq(1)
    S.response_count.should eq(0)
  end

  it "efface une réponse à la demande (droit à l'effacement), avec ses pièces en attente" do
    S.setup
    response = received([S.file("devis.pdf", S::PDF)])
    expect_raises(Partiduo::Api::Forbidden) { Api.delete_response(S.processor, response.id) }
    Api.delete_response(S.manager, response.id).success?.should be_true
    Forms::Upload.all.count.should eq(0)
  end

  it "purge en ligne de commande, avec l'acteur système" do
    S.setup
    form = S.contact_form(retention: 1)
    S.submit(S.link(form).token).value!
    Partiduo::Config.travel_to(SPEC_NOW + 2.days) do
      output = IO::Memory.new
      Forms::Commands::Purge.new([] of String, stdout: output, stderr: IO::Memory.new, exit_raises: true).handle.should eq(0)
      output.to_s.should contain(%("purged":1))
    end
  end
end
