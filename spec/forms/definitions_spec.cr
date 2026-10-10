# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Forms::SpecSupport
private alias Api = Forms::Api

describe "Formulaires : définitions, champs et liens (D-FRM-004 à D-FRM-006)" do
  it "exige titre, finalité, responsable et une durée de conservation bornée" do
    S.setup
    result = Api.create_form(S.manager, Api::FormInput.new(title: " ", purpose: "", controller: "", retention_days: 2000,
      max_files: 9))
    result.error_keys.should eq(["form.errors.text.blank", "form.errors.text.blank", "form.errors.text.blank",
                                 "form.errors.retention.range", "form.errors.max_files.range"])
    Api.create_form(S.manager, Api::FormInput.new(title: "X", purpose: "P", controller: "C", category_id: 999_999))
      .error_keys.should eq(["form.errors.category.unknown"])
  end

  it "réserve la définition à form.design et les liens à form.admin" do
    S.setup
    input = Api::FormInput.new(title: "X", purpose: "P", controller: "C")
    expect_raises(Partiduo::Api::Forbidden) { Api.create_form(S.reader, input) }
    form = S.contact_form
    expect_raises(Partiduo::Api::Forbidden) { Api.add_field(S.processor, form.id, Api::FieldInput.new(key: "a", label: "A")) }
    expect_raises(Partiduo::Api::Forbidden) do
      Api.create_link(S.processor, form.id, Api::LinkInput.new(expires_on: Partiduo::Config.today + 1.day))
    end
    expect_raises(Partiduo::Api::Forbidden) { Api.forms(S.anonymous) }
  end

  it "contrôle les champs : clé, nature, choix, cible dans la fiche" do
    S.setup
    form = S.contact_form
    add = ->(input : Api::FieldInput) { Api.add_field(S.manager, form.id, input).error_keys }
    add.call(Api::FieldInput.new(key: "Nom complet", label: "X")).should eq(["form.errors.field.key_format"])
    add.call(Api::FieldInput.new(key: "csrftoken", label: "X")).should eq(["form.errors.field.key_reserved"])
    add.call(Api::FieldInput.new(key: "nom", label: "X")).should eq(["form.errors.field.key_taken"])
    add.call(Api::FieldInput.new(key: "a", label: "X", kind: "script")).should eq(["form.errors.field.kind_invalid"])
    add.call(Api::FieldInput.new(key: "a", label: "X", kind: "select")).should eq(["form.errors.field.choices_blank"])
    add.call(Api::FieldInput.new(key: "a", label: "X", max_length: 6000, kind: "textarea")).should eq(["form.errors.field.max_length"])
    add.call(Api::FieldInput.new(key: "a", label: "X", target: "name")).should eq(["form.errors.field.target_taken"])
    add.call(Api::FieldInput.new(key: "a", label: "X", target: "iban")).should eq(["form.errors.field.target_invalid"])
    add.call(Api::FieldInput.new(key: "a", label: "X", target: "extra.inconnu")).should eq(["form.errors.field.target_invalid"])
    add.call(Api::FieldInput.new(key: "telephone", label: "Téléphone", kind: "phone", target: "phone")).should be_empty
  end

  it "range et réordonne les champs ; un champ retiré reste dans les réponses reçues" do
    S.setup
    form = S.contact_form
    form.fields.map(&.key).should eq(%w[nom courriel ville budget sujet message accord])
    Api.move_field(S.manager, form.fields[1].id, up: true).success?.should be_true
    Api.move_field(S.manager, form.fields[6].id, up: false).success?.should be_true
    Api.form(S.manager, form.id).fields.map(&.key).should eq(%w[courriel nom ville budget sujet message accord])
    token = S.link(form).token
    S.submit(token).success?.should be_true
    Api.delete_field(S.manager, form.fields[5].id).success?.should be_true
    Api.responses(S.manager).first.values.map(&.key).should contain("message")
  end

  it "émet un jeton long et aléatoire, ne garde que son empreinte, et le rend une seule fois" do
    S.setup
    form = S.contact_form
    issued = S.link(form)
    issued.token.should match(/\A[A-Za-z0-9_-]{43}\z/)
    S.link(form).token.should_not eq(issued.token)
    row = Forms::Link.all.order(:id).first!
    row.token_digest.should eq(OpenSSL::Digest.new("SHA256").update(issued.token).final.hexstring)
    row.token_hint.should eq(issued.token[0, 4])
    Forms::Link.all.to_a.none? { |link| link.token_digest == issued.token }.should be_true
    Api.links(S.reader, form.id).first.hint.size.should eq(4)
  end

  it "borne l'expiration et le nombre d'envois d'un lien, refuse un formulaire sans champ" do
    S.setup
    form = S.contact_form
    today = Partiduo::Config.today
    Api.create_link(S.manager, form.id, Api::LinkInput.new(expires_on: today - 1.day)).error_keys
      .should eq(["form.errors.link.expires_past"])
    Api.create_link(S.manager, form.id, Api::LinkInput.new(expires_on: today + 400.days)).error_keys
      .should eq(["form.errors.link.expires_far"])
    Api.create_link(S.manager, form.id, Api::LinkInput.new(expires_on: today + 1.day, max_uses: 0)).error_keys
      .should eq(["form.errors.link.max_uses"])
    empty = Api.create_form(S.manager, Api::FormInput.new(title: "Vide", purpose: "P", controller: "C")).value!
    Api.create_link(S.manager, empty.id, Api::LinkInput.new(expires_on: today + 1.day)).error_keys
      .should eq(["form.errors.link.no_fields"])
  end

  it "révoque un lien une fois pour toutes" do
    S.setup
    form = S.contact_form
    issued = S.link(form)
    revoked = Api.revoke_link(S.manager, issued.link.id).value!
    revoked.state.should eq("revoked")
    Api.revoke_link(S.manager, issued.link.id).error_keys.should eq(["form.errors.link.revoked"])
    Api.public_form(S.anonymous, issued.token).should be_nil
  end

  it "n'efface pas un formulaire dont des réponses attendent, puis l'efface avec tout ce qui en dépend" do
    S.setup
    form = S.contact_form
    S.submit(S.link(form).token).success?.should be_true
    Api.delete_form(S.manager, form.id).error_keys.should eq(["form.errors.form.pending"])
    Api.reject(S.processor, Api.responses(S.manager).first.id).success?.should be_true
    Api.delete_form(S.manager, form.id).success?.should be_true
    Forms::Link.all.count.should eq(0)
    S.response_count.should eq(0)
  end
end
