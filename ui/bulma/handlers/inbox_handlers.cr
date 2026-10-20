# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  module Ui
    # `/ext/FORM/inbox` : réponses reçues (à traiter par défaut, toutes sur
    # demande), filtrables par formulaire. Rien n'y entre en comptabilité ni
    # dans les fiches tant qu'un utilisateur ne l'a pas décidé (D-FRM-010).
    class InboxHandler < Handler
      def get
        status = query("status") == "all" ? nil : "received"
        form_id = query("form").to_i64?
        forms = Api.forms(actor)
        columns = [
          Table::Column.new("received", I18n.t("form_ui.inbox.received_at"), "mono"),
          Table::Column.new("form", I18n.t("form_ui.inbox.form")),
          Table::Column.new("summary", I18n.t("form_ui.inbox.summary")),
          Table::Column.new("files", I18n.t("form_ui.inbox.files"), "mono", secondary: true),
          Table::Column.new("status", I18n.t("form_ui.inbox.status")),
          Table::Column.new("purge", I18n.t("form_ui.inbox.purge_after"), "mono", secondary: true),
        ]
        rows = Api.responses(actor, Api::ResponseQuery.new(form_id: form_id, status: status)).map do |view|
          url = Ui.url("response", id: view.id)
          summary = view.summary
          Table::Row.new([
            Table::Cell.new(fmt.datetime(view.received_at), url, sort: view.received_at.to_rfc3339),
            Table::Cell.new(view.form_title),
            Table::Cell.new(summary.size > 80 ? "#{summary[0, 80]}…" : summary, url, csv: summary),
            Table::Cell.new(view.uploads.size.to_s),
            Table::Cell.new(I18n.t(view.status_key)),
            Table::Cell.new(fmt.date(view.purge_after), sort: date_key(view.purge_after)),
          ])
        end
        params = {"status" => query("status"), "form" => query("form")}.reject { |_, value| value.empty? }
        table = Table.new(I18n.t("form.menu.form_inbox"), columns, rows, Ui.url("inbox"), params,
          empty_message: I18n.t("form_ui.inbox.none"), id: "form-inbox")
        tabs = [
          Screen::Tab.new(I18n.t("form_ui.inbox.pending"), tab_url("", form_id), status == "received"),
          Screen::Tab.new(I18n.t("form_ui.inbox.all"), tab_url("all", form_id), status.nil?),
        ]
        filters = search_filters([UiForm::Field.new("form", I18n.t("form_ui.inbox.form"), "select", query("form"),
          options: [option("", I18n.t("form_ui.inbox.all_forms"))] + forms.map { |form| option(form.id.to_s, form.title) })])
        actions = [] of Screen::Action
        if can_admin?
          actions << post_action("form_ui.inbox.purge", Ui.url("purge"), "form_ui.inbox.purge_confirm", "", "trash-2")
        end
        list_page(I18n.t("form.menu.form_inbox"), table, crumbs({I18n.t("form.menu.form_inbox"), nil}),
          "form_ui.inbox.csv_name", actions, tabs: tabs, tabs_label: I18n.t("form_ui.inbox.tabs"), filters: filters,
          intro: I18n.t("form_ui.inbox.intro"))
      end

      private def tab_url(status : String, form_id : Int64?) : String
        params = [] of String
        params << "status=#{status}" unless status.empty?
        params << "form=#{form_id}" if form_id
        params.empty? ? Ui.url("inbox") : "#{Ui.url("inbox")}?#{params.join("&")}"
      end
    end

    # `/ext/FORM/responses/<id>` : une réponse, ses valeurs telles que
    # reçues, ses pièces, et les décisions possibles.
    class ResponseHandler < Handler
      def get
        view = Api.response(actor, id_param)
        items = [
          Screen::Item.new(I18n.t("form_ui.inbox.form"), view.form_title, Ui.url("form", id: view.form_id)),
          Screen::Item.new(I18n.t("form_ui.inbox.received_at"), fmt.datetime(view.received_at)),
          Screen::Item.new(I18n.t("form_ui.response.link"), view.link_hint.try { |hint| "#{hint}…" } || "—", mono: true),
          Screen::Item.new(I18n.t("form_ui.inbox.purge_after"), fmt.date(view.purge_after)),
          Screen::Item.new(I18n.t("form_ui.response.processed_at"), view.processed_at.try { |time| fmt.datetime(time) } || ""),
          Screen::Item.new(I18n.t("form_ui.response.card"), view.card_id ? I18n.t("form_ui.response.card_open") : "",
            view.card_id.try { |id| Marten.routes.reverse("cards:show", id: id) }),
          Screen::Item.new(I18n.t("form_ui.response.note"), view.note),
        ]
        sections = [
          Screen::Section.new(I18n.t("form_ui.response.values"), table: values_table(view)),
          Screen::Section.new(I18n.t("form_ui.response.details"), items),
        ]
        sections << Screen::Section.new(I18n.t("form_ui.response.files"), table: files_table(view)) unless view.uploads.empty?
        actions = [] of Screen::Action
        if view.received? && can_process?
          if view.category_id
            actions << link_action("form_ui.response.accept", Ui.url("response_accept", id: view.id), "primary", "check")
          end
          actions << post_action("form_ui.response.close", Ui.url("response_close", id: view.id),
            "form_ui.response.close_confirm", "", "file-text")
          actions << post_action("form_ui.response.reject", Ui.url("response_reject", id: view.id),
            "form_ui.response.reject_confirm", "danger", "x")
        end
        if can_admin?
          actions << post_action("form_ui.response.delete", Ui.url("response_delete", id: view.id),
            "form_ui.response.delete_confirm", "danger", "trash-2")
        end
        title = I18n.t("form_ui.response.title", id: view.id)
        intro = view.received? && view.category_id.nil? ? I18n.t("form_ui.response.no_category") : nil
        detail_page(title, crumbs({I18n.t("form.menu.form_inbox"), Ui.url("inbox")}, {title, nil}), sections, actions,
          status_tag: I18n.t(view.status_key), intro: intro)
      end

      private def values_table(view : Api::ResponseView) : Table
        columns = [
          Table::Column.new("label", I18n.t("form_ui.fields.label"), sortable: false),
          Table::Column.new("value", I18n.t("form_ui.response.value"), sortable: false),
        ]
        rows = view.values.map do |value|
          text = value.kind == "checkbox" ? yes_no(value.value == "1") : value.value
          Table::Row.new([Table::Cell.new(value.label), Table::Cell.new(text)])
        end
        Table.new(I18n.t("form_ui.response.values"), columns, rows, Ui.url("response", id: view.id), id: "form-values")
      end

      private def files_table(view : Api::ResponseView) : Table
        columns = [
          Table::Column.new("name", I18n.t("form_ui.response.file_name"), sortable: false),
          Table::Column.new("type", I18n.t("form_ui.response.file_type"), "mono", sortable: false),
          Table::Column.new("size", I18n.t("form_ui.response.file_size"), "mono", sortable: false),
          Table::Column.new("state", I18n.t("form_ui.response.file_state"), sortable: false),
        ]
        rows = view.uploads.map do |upload|
          url = can_process? ? Ui.url("file", id: upload.id) : nil
          state = upload.attachment_id ? "form_ui.response.file_stored" : "form_ui.response.file_quarantine"
          Table::Row.new([
            Table::Cell.new(upload.filename, url),
            Table::Cell.new(upload.content_type),
            Table::Cell.new(I18n.t("form_ui.response.kilobytes", count: (upload.byte_size + 1023) // 1024)),
            Table::Cell.new(I18n.t(state)),
          ])
        end
        Table.new(I18n.t("form_ui.response.files"), columns, rows, Ui.url("response", id: view.id), id: "form-files")
      end
    end

    # Accepter une réponse : la fiche proposée, à vérifier et corriger, est
    # créée par le contrat des fiches avec l'utilisateur connecté.
    class ResponseAcceptHandler < Handler
      PLAIN   = %w[name email phone contact_name vat_number siren siret description]
      ADDRESS = %w[line1 line2 postcode city country_code]

      def get
        require!("CARDS", Api::CARD_PERMISSION)
        view = Api.response(actor, id_param)
        return go(Ui.url("response", id: view.id)) unless view.received?
        draft = Api.card_draft(actor, view.id) || return go(Ui.url("response", id: view.id))
        show(view, card_form(draft, values_of(draft), store_files: true))
      end

      def post
        require!("CARDS", Api::CARD_PERMISSION)
        view = Api.response(actor, id_param)
        draft = Api.card_draft(actor, view.id) || return go(Ui.url("response", id: view.id))
        values = submitted(draft)
        ui_form = card_form(draft, values, checkbox("store_files"))
        result = Api.accept(actor, view.id, input_of(draft), store_files: checkbox("store_files"))
        if result.success?
          flash["success"] = I18n.t("form_ui.flash.accepted")
          return go(Ui.url("response", id: view.id))
        end
        ui_form.add_errors(result.errors, fmt)
        show(view, ui_form)
      end

      private def values_of(draft : Partiduo::Api::Cards::CardInput) : Hash(String, String)
        values = {
          "name" => draft.name, "email" => draft.email.to_s, "phone" => draft.phone.to_s,
          "contact_name" => draft.contact_name.to_s, "vat_number" => draft.vat_number.to_s,
          "siren" => draft.siren.to_s, "siret" => draft.siret.to_s, "description" => draft.description.to_s,
        }
        address = draft.address
        values["address.line1"] = address.try(&.line1).to_s
        values["address.line2"] = address.try(&.line2).to_s
        values["address.postcode"] = address.try(&.postcode).to_s
        values["address.city"] = address.try(&.city).to_s
        values["address.country_code"] = address.try(&.country_code).to_s
        draft.extra.each { |key, value| values["extra.#{key}"] = value.as_bool? ? "1" : value.as_s? || "" }
        values
      end

      private def submitted(draft : Partiduo::Api::Cards::CardInput) : Hash(String, String)
        names = PLAIN + ADDRESS.map { |part| "address.#{part}" } + attributes(draft).map { |item| "extra.#{item.key}" }
        names.to_h { |name| {name, field(name)} }
      end

      private def attributes(draft : Partiduo::Api::Cards::CardInput) : Array(Partiduo::Api::Cards::AttributeView)
        categories.find { |category| category.id == draft.category_id }.try(&.attributes) ||
          [] of Partiduo::Api::Cards::AttributeView
      end

      private def input_of(draft : Partiduo::Api::Cards::CardInput) : Partiduo::Api::Cards::CardInput
        address = Partiduo::Api::Cards::AddressInput.new(line1: field("address.line1"), line2: field("address.line2"),
          postcode: field("address.postcode"), city: field("address.city"),
          country_code: field("address.country_code").upcase.presence)
        extra = {} of String => JSON::Any
        attributes(draft).each do |attribute|
          name = "extra.#{attribute.key}"
          if attribute.value_type == "boolean"
            extra[attribute.key] = JSON::Any.new(checkbox(name))
          elsif text = field(name).presence
            extra[attribute.key] = JSON::Any.new(text)
          end
        end
        draft.copy_with(name: field("name"), email: field("email").presence, phone: field("phone").presence,
          contact_name: field("contact_name").presence, vat_number: field("vat_number").presence,
          siren: field("siren").presence, siret: field("siret").presence, description: field("description").presence,
          address: address, extra: extra)
      end

      private def card_form(draft : Partiduo::Api::Cards::CardInput, values : Hash(String, String),
                            store_files : Bool) : UiForm
        value = ->(name : String) { values[name]? || "" }
        identity = PLAIN.map do |name|
          UiForm::Field.new(name, I18n.t("form.targets.#{name}"), name == "description" ? "textarea" : "text",
            value.call(name), required: name == "name")
        end
        address = ADDRESS.map do |part|
          UiForm::Field.new("address.#{part}", I18n.t("form.targets.address.#{part}"), value: value.call("address.#{part}"))
        end
        extra = attributes(draft).map do |attribute|
          type = attribute.value_type == "boolean" ? "checkbox" : (attribute.value_type == "date" ? "date" : "text")
          UiForm::Field.new("extra.#{attribute.key}", attribute.label, type, value.call("extra.#{attribute.key}"),
            required: attribute.required)
        end
        groups = [
          UiForm::Group.new(I18n.t("form_ui.accept.identity"), identity),
          UiForm::Group.new(I18n.t("form_ui.accept.address"), address),
        ]
        groups << UiForm::Group.new(I18n.t("form_ui.accept.attributes"), extra) unless extra.empty?
        groups << UiForm::Group.new(I18n.t("form_ui.accept.files"), [
          UiForm::Field.new("store_files", I18n.t("form_ui.accept.store_files"), "checkbox", store_files ? "1" : "",
            help: I18n.t("form_ui.accept.store_files_help")),
        ])
        UiForm.new(groups)
      end

      private def show(view : Api::ResponseView, ui_form : UiForm) : Marten::HTTP::Response
        title = I18n.t("form_ui.accept.title")
        form_page(title, crumbs({I18n.t("form.menu.form_inbox"), Ui.url("inbox")},
          {I18n.t("form_ui.response.title", id: view.id), Ui.url("response", id: view.id)}, {title, nil}), ui_form,
          Ui.url("response_accept", id: view.id), I18n.t("form_ui.accept.submit"), Ui.url("response", id: view.id),
          intro: I18n.t("form_ui.accept.intro", category: category_name(view.category_id)))
      end
    end

    abstract class ResponseCommand < Handler
      def get
        go(Ui.url("response", id: id_param))
      end
    end

    class ResponseCloseHandler < ResponseCommand
      def post
        after(Api.close(actor, id_param, field("note")), "form_ui.flash.closed", Ui.url("response", id: id_param))
      end
    end

    class ResponseRejectHandler < ResponseCommand
      def post
        after(Api.reject(actor, id_param, field("note")), "form_ui.flash.rejected", Ui.url("response", id: id_param))
      end
    end

    class ResponseDeleteHandler < ResponseCommand
      def post
        after(Api.delete_response(actor, id_param), "form_ui.flash.response_deleted", Ui.url("inbox"))
      end
    end

    class PurgeHandler < Handler
      def get
        go(Ui.url("inbox"))
      end

      def post
        count = Api.purge(actor)
        flash["success"] = I18n.t("form_ui.flash.purged", count: count)
        go(Ui.url("inbox"))
      end
    end

    # Téléchargement d'une pièce reçue : toujours en pièce jointe, jamais
    # affichée dans la page ni interprétée par le navigateur (D-FRM-009).
    class FileHandler < Handler
      def get
        file = Api.file(actor, id_param)
        response = Marten::HTTP::Response.new(content: String.new(file.content), content_type: file.content_type)
        response.headers["Content-Disposition"] = %(attachment; filename="#{file.filename.gsub(/[^A-Za-z0-9._-]/, "_")}")
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Content-Security-Policy"] = "default-src 'none'; sandbox"
        response.headers["Cache-Control"] = "no-store"
        response
      end
    end
  end
end
