# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  module Ui
    # Émission d'un lien public (D-FRM-006) : expiration, nombre d'envois,
    # libellé. Le lien complet n'est montré qu'une fois, sur la page qui
    # suit l'émission, jamais mise en cache ; ensuite, seuls ses quatre
    # premiers caractères restent visibles.
    class LinkNewHandler < Handler
      def get
        form = Api.form(actor, id_param)
        expires = Partiduo::Api::Core.today + 30.days
        show(form, link_form({"expires_on" => expires.to_s("%Y-%m-%d"), "max_uses" => "1"}))
      end

      def post
        form = Api.form(actor, id_param)
        values = {"label" => field("label"), "expires_on" => field("expires_on"), "max_uses" => field("max_uses")}
        ui_form = link_form(values)
        errors = [] of {String, String}
        expires = date("expires_on", errors)
        uses = integer("max_uses", errors)
        errors.each { |(name, message)| ui_form.add_error(name, message) }
        if expires && uses && !ui_form.invalid
          result = Api.create_link(actor, form.id, Api::LinkInput.new(expires_on: expires, max_uses: uses,
            label: field("label")))
          return issued(form, result.value!) if result.success?
          ui_form.add_errors(result.errors, fmt)
        end
        show(form, ui_form)
      end

      private def link_form(values : Hash(String, String)) : UiForm
        value = ->(name : String) { values[name]? || "" }
        UiForm.new([UiForm::Group.new(nil, [
          UiForm::Field.new("label", I18n.t("form_ui.links.label"), value: value.call("label"), maxlength: 120,
            help: I18n.t("form_ui.links.label_help")),
          UiForm::Field.new("expires_on", I18n.t("form_ui.links.expires_on"), "date", value.call("expires_on"),
            required: true, help: I18n.t("form_ui.links.expires_help", max: Api::MAX_LINK_DAYS)),
          UiForm::Field.new("max_uses", I18n.t("form_ui.links.max_uses"), "number", value.call("max_uses"),
            required: true, help: I18n.t("form_ui.links.max_uses_help", max: Api::MAX_LINK_USES)),
        ])])
      end

      private def show(form : Api::FormView, ui_form : UiForm) : Marten::HTTP::Response
        title = I18n.t("form_ui.links.new")
        form_page(title, crumbs({I18n.t("form.menu.form_definitions"), Ui.url("forms")},
          {form.title, Ui.url("form", id: form.id)}, {title, nil}), ui_form, Ui.url("link_new", id: form.id),
          I18n.t("form_ui.links.issue"), Ui.url("form", id: form.id), intro: I18n.t("form_ui.links.intro"))
      end

      private def issued(form : Api::FormView, view : Api::IssuedLinkView) : Marten::HTTP::Response
        url = "#{request.scheme}://#{request.host}#{Ui.public_path(view.token)}"
        items = [
          Screen::Item.new(I18n.t("form_ui.links.address"), url, mono: true),
          Screen::Item.new(I18n.t("form_ui.links.expires_at"), fmt.datetime(view.link.expires_at)),
          Screen::Item.new(I18n.t("form_ui.links.max_uses"), view.link.max_uses.to_s),
        ]
        sections = [Screen::Section.new(I18n.t("form_ui.links.issued"), items, note: I18n.t("form_ui.links.once"))]
        actions = [link_action("form_ui.links.back", Ui.url("form", id: form.id), "primary")]
        response = detail_page(I18n.t("form_ui.links.issued"), crumbs({I18n.t("form.menu.form_definitions"), Ui.url("forms")},
          {form.title, Ui.url("form", id: form.id)}, {I18n.t("form_ui.links.issued"), nil}), sections, actions)
        response.headers["Cache-Control"] = "no-store"
        response.headers["Referrer-Policy"] = "no-referrer"
        response
      end
    end

    class LinkRevokeHandler < Handler
      def get
        go(Ui.url("forms"))
      end

      def post
        result = Api.revoke_link(actor, id_param)
        url = result.value?.try { |link| Ui.url("form", id: link.form_id) } || Ui.url("forms")
        after(result, "form_ui.flash.link_revoked", url)
      end
    end
  end
end
