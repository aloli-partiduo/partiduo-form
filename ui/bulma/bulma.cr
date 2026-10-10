# SPDX-License-Identifier: AGPL-3.0-or-later

# Interface Bulma de l'extension des formulaires (ADR-005 D4) : écrans
# authentifiés montés par `partiduo-ui-bulma` sous `/ext/FORM/`
# (ADR-003 D3) — boîte de réception, traitement d'une réponse, définitions,
# champs, liens publics — et la *page publique* `/f/<jeton>`, seule route
# de l'extension hors de ce montage (D-FRM-007). La distribution la
# requiert après l'interface :
#
# ```
# require "partiduo-ui-bulma/partiduo_ui"
# require "partiduo-form"
# require "partiduo-form/ui/bulma"
# ```
#
# puis ajoute `Forms::Ui::INSTALLED_APPS` à ses applications Marten.
#
# Ce dossier ne parle au métier que par `Forms::Api` et `Partiduo::Api`
# (vérifié par `spec/architecture/conventions_spec.cr`) ; le contrôle
# d'accès des écrans authentifiés est fait par l'interface, avant le
# handler, à partir du montage, puis par le contrat. La page publique n'a
# que le jeton : elle passe par `Forms::Api.public_form` et
# `Forms::Api.submit`, derrière la limitation de débit, la limite de
# taille et la protection CSRF.
require "../../src/partiduo-form"

require "./presenters"
require "./throttle"
require "./handlers/base"
require "./handlers/**"

module Forms
  module Ui
    # Application Marten de l'interface Bulma de l'extension : gabarits
    # (`templates/forms/`), fichiers statiques (`assets/forms/`) et
    # libellés d'écran (`locales/`, clés `form_ui.*`).
    class App < Marten::App
      label "form_ui"

      # Ajoute la route publique aux routes de l'instance, hors du montage
      # `/ext/FORM/` (qui exige une session) : l'interface commune n'offre
      # pas de route publique aux extensions (amendement A-FRM-1). Appelé
      # par Marten avant la préparation des routes, comme le montage des
      # extensions par `PartiduoUi::App#setup`.
      def setup
        Ui.draw_public
      end
    end

    INSTALLED_APPS = [Forms::Ui::App] of Marten::Apps::Config.class

    # Chemin de la page publique d'un formulaire : `/f/<jeton>`.
    PUBLIC_PATH = "/f/<token:str>"
    PUBLIC_NAME = "form_public"

    @@public_drawn = false

    def self.draw_public(map : Marten::Routing::Map = Marten.routes) : Nil
      return if @@public_drawn
      map.path PUBLIC_PATH, Forms::Ui::PublicHandler, name: PUBLIC_NAME
      @@public_drawn = true
    end

    # Routes servies sous `/ext/FORM/`, nommées `form:<nom>` : celles que
    # citent les menus du manifeste.
    ROUTES = Marten::Routing::Map.draw do
      path "/", Forms::Ui::IndexHandler, name: "index"
      path "/inbox", Forms::Ui::InboxHandler, name: "inbox"
      path "/inbox/purge", Forms::Ui::PurgeHandler, name: "purge"
      path "/responses/<id:int>", Forms::Ui::ResponseHandler, name: "response"
      path "/responses/<id:int>/accept", Forms::Ui::ResponseAcceptHandler, name: "response_accept"
      path "/responses/<id:int>/close", Forms::Ui::ResponseCloseHandler, name: "response_close"
      path "/responses/<id:int>/reject", Forms::Ui::ResponseRejectHandler, name: "response_reject"
      path "/responses/<id:int>/delete", Forms::Ui::ResponseDeleteHandler, name: "response_delete"
      path "/files/<id:int>", Forms::Ui::FileHandler, name: "file"
      path "/forms", Forms::Ui::FormsHandler, name: "forms"
      path "/forms/new", Forms::Ui::FormNewHandler, name: "form_new"
      path "/forms/<id:int>", Forms::Ui::FormHandler, name: "form"
      path "/forms/<id:int>/edit", Forms::Ui::FormEditHandler, name: "form_edit"
      path "/forms/<id:int>/delete", Forms::Ui::FormDeleteHandler, name: "form_delete"
      path "/forms/<id:int>/fields/new", Forms::Ui::FieldNewHandler, name: "field_new"
      path "/forms/<id:int>/links/new", Forms::Ui::LinkNewHandler, name: "link_new"
      path "/fields/<id:int>", Forms::Ui::FieldEditHandler, name: "field_edit"
      path "/fields/<id:int>/delete", Forms::Ui::FieldDeleteHandler, name: "field_delete"
      path "/fields/<id:int>/up", Forms::Ui::FieldUpHandler, name: "field_up"
      path "/fields/<id:int>/down", Forms::Ui::FieldDownHandler, name: "field_down"
      path "/links/<id:int>/revoke", Forms::Ui::LinkRevokeHandler, name: "link_revoke"
    end

    # Routes qui traitent une réponse : `form.process` ; qui définissent :
    # `form.design` ; liens publics, effacements et purge : `form.admin` ;
    # les autres : `form.read`. Le contrat vérifie encore les permissions
    # du cœur (fiches, pièces jointes).
    PROCESS_ROUTES = %w[response_accept response_close response_reject file]
    DESIGN_ROUTES  = %w[form_new form_edit field_new field_edit field_delete field_up field_down]
    ADMIN_ROUTES   = %w[form_delete link_new link_revoke response_delete purge]
  end
end

PartiduoUi::Extensions.mount Forms::CODE, Forms::Ui::ROUTES, permission: Forms::Api::READ,
  permissions: Forms::Ui::PROCESS_ROUTES.to_h { |route| {route, Forms::Api::PROCESS} }
    .merge(Forms::Ui::DESIGN_ROUTES.to_h { |route| {route, Forms::Api::DESIGN} })
    .merge(Forms::Ui::ADMIN_ROUTES.to_h { |route| {route, Forms::Api::ADMIN} })

# Compteur du menu « Réponses reçues » et ligne de « À traiter » du
# tableau de bord : réponses qui attendent d'être traitées.
PartiduoUi::Extensions.counter("FORM_INBOX", route: "form:inbox", todo: "form_ui.todo", tone: "warn") do |actor|
  Forms::Api.pending_count(actor)
end
