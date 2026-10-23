# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Forms::SpecSupport
private alias Api = Forms::Api

private def menu_routes(entries : Array(Partiduo::Api::Modules::MenuView)) : Array(String?)
  entries.flat_map { |entry| [entry.route] + menu_routes(entry.children) }
end

describe "Extension des formulaires : manifeste et activation (ADR-003 D2)" do
  it "déclare une extension conforme, sans dépendance ni incompatibilité, sans abonnement" do
    manifest = Partiduo::Modules[Forms::CODE]
    manifest.kind.should eq(Partiduo::Modules::Kind::Extension)
    manifest.version.should eq(Forms::VERSION)
    Forms::VERSION.should match(/\A\d+\.\d+\.\d+\z/)
    manifest.requires_core.should eq("~> 0.1")
    manifest.permissions.should eq(["form.read", "form.process", "form.design", "form.admin"])
    manifest.depends_on.should be_empty
    manifest.incompatible_with.should be_empty
    manifest.subscribed_events.should be_empty
    manifest.uis.map(&.path).should eq(["ui/bulma"])
    manifest.menus.map { |menu| {menu.code, menu.parent, menu.route} }.should eq([
      {"FORM", nil, nil},
      {"FORM_INBOX", "FORM", "form:inbox"},
      {"FORM_DEFINITIONS", "FORM", "form:forms"},
    ])
    Partiduo::Modules.structure_errors.should be_empty
    Partiduo::Modules.dependency_errors(manifest, Set{Forms::CODE}).should be_empty
  end

  it "traduit son nom, ses permissions et ses menus dans chaque langue de l'interface" do
    manifest = Partiduo::Modules[Forms::CODE]
    keys = [manifest.name] + manifest.permission_entries.map(&.label) + manifest.menus.map(&.label)
    Partiduo::LOCALES.each do |locale|
      I18n.with_locale(locale) { keys.each { |key| I18n.t(key).should_not contain("missing") } }
    end
    I18n.with_locale("fr") { I18n.t("form.menu.form_inbox").should eq("Réponses reçues") }
  end

  it "est inactive tant que l'instance ne l'active pas : contrat fermé, page publique comprise" do
    PartiduoUi::Reference.provision
    S.user("alice@example.com", "Alice")
    S.user("bruno@example.com", "Bruno")
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.forms(S.reader) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.public_form(S.anonymous, "x" * 43) }
    expect_raises(Partiduo::Api::ModuleDisabled) { S.submit("x" * 43) }
    Api.pending_count(S.reader).should be_nil
    menu_routes(Partiduo::Api::Modules.menu(S.reader)).should_not contain("form:inbox")

    S.activate
    Partiduo::Modules.check!
    menu_routes(Partiduo::Api::Modules.menu(S.reader)).should contain("form:inbox")
    Api.pending_count(S.reader).should eq(0)
  end

  it "range ses tables sous le préfixe form_ et refuse en base les valeurs hors domaine" do
    [Forms::Definition, Forms::Field, Forms::Link, Forms::Response, Forms::Upload].map(&.db_table)
      .should eq(%w[form_definition form_field form_link form_response form_upload])
    S.setup
    form = S.contact_form
    sql_error = ->(sql : String) do
      Marten::DB::Connection.default.open(&.exec(sql))
      nil
  rescue ex : PQ::PQError
    ex.message
    end
    sql_error.call("UPDATE form_definition SET retention_days = 0 WHERE id = #{form.id}").to_s
      .should contain("form_definition_retention_check")
    sql_error.call("INSERT INTO form_link (definition_id, label, token_digest, token_hint, expires_at, max_uses, uses, " \
                   "created_at, updated_at) VALUES (#{form.id}, '', 'jeton-en-clair', 'jeto', now(), 1, 0, now(), now())")
      .to_s.should contain("form_link_digest_check")
    link = S.link(form, max_uses: 1)
    sql_error.call("UPDATE form_link SET uses = 2 WHERE id = #{link.link.id}").to_s.should contain("form_link_uses_check")
    sql_error.call("INSERT INTO form_field (definition_id, position, key, label, kind, required, choices, help, target, " \
                   "created_at, updated_at) VALUES (#{form.id}, 9, 'Nom', 'X', 'text', false, '', '', '', now(), now())")
      .to_s.should contain("form_field_key_check")
  end
end
