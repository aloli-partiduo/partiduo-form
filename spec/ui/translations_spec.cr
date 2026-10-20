# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Traductions des écrans de l'extension (ADR-005 D7) : chaque route de
# `/ext/FORM/` et de la page publique `/p/form/` servie en `GET` (liste
# tirée du routeur de Marten), obtenue en fr, en et nl, par un
# administrateur pour les écrans de gestion et sans session pour la page
# publique. Jeu de données : un formulaire de contact à pièces jointes,
# des liens actif, épuisé et révoqué, des réponses reçue (avec pièce),
# acceptée, classée et rejetée, et un formulaire sans champ. Contrôle de
# l'interface (`PartiduoUi::Translations`) : ni marqueur de traduction
# absente, ni clé brute, ni interpolation non résolue, et toute route
# atteinte par les liens des pages.

private alias S = Forms::SpecSupport
private alias Api = Forms::Api

describe "Traductions des écrans des formulaires (fr, en, nl)" do
  it "rend chaque écran dans chaque langue, sans clé absente, brute ni interpolation non résolue" do
    browser = PartiduoUi::Books.admin
    S.user("bruno@example.com", "Bruno")
    S.activate
    form = S.contact_form(files: true)
    token = S.link(form, max_uses: 50).token
    S.submit(token, files: [S.file("devis.pdf", S::PDF)]).value!
    3.times { S.submit(token).value! }
    _, accepted, closed, rejected = Api.responses(S.manager).map(&.id).sort!
    draft = Api.card_draft(S.processor, accepted) || raise "brouillon de fiche attendu"
    Api.accept(S.processor, accepted, draft).value!
    Api.close(S.processor, closed, "Doublon").value!
    Api.reject(S.processor, rejected, "Indésirable").value!
    exhausted = S.link(form, max_uses: 1)
    S.submit(exhausted.token).value!
    Api.revoke_link(S.manager, S.link(form).link.id).value!
    Api.create_form(S.manager, Api::FormInput.new(title: "Inscription", purpose: "Vous inscrire.",
      controller: "Atelier Brunet SARL", retention_days: 60, category_id: S.category.id)).value!

    explorer = PartiduoUi::Translations::Explorer.new do |route|
      route.name.starts_with?("form:") || route.name.starts_with?("form_public")
    end
    explorer.crawl(browser, "FORM")
    # Page publique : sans session ; l'ancienne adresse `/f/<jeton>` ne fait
    # que rediriger et aucune page n'y renvoie.
    explorer.crawl(PartiduoUi::Browser.new, "anonyme", ["/p/form/#{token}", "/f/#{token}"])
    puts "\nTraductions de FORM : #{explorer.report}"
    (explorer.failures + explorer.unreached.map { |route| "route jamais atteinte : #{route}" }).should eq([] of String)
  end
end
