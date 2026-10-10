# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  module Ui
    # `/ext/FORM/forms` : les formulaires, leurs réponses à traiter et leurs
    # liens actifs.
    class FormsHandler < Handler
      def get
        columns = [
          Table::Column.new("title", I18n.t("form_ui.forms.title")),
          Table::Column.new("fields", I18n.t("form_ui.forms.fields"), "mono", secondary: true),
          Table::Column.new("pending", I18n.t("form_ui.forms.pending"), "mono"),
          Table::Column.new("links", I18n.t("form_ui.forms.links"), "mono", secondary: true),
          Table::Column.new("state", I18n.t("form_ui.forms.state")),
        ]
        rows = Api.forms(actor).map do |view|
          url = Ui.url("form", id: view.id)
          Table::Row.new([
            Table::Cell.new(view.title, url),
            Table::Cell.new(view.fields.size.to_s),
            Table::Cell.new(view.pending_count.to_s),
            Table::Cell.new(view.active_link_count.to_s),
            Table::Cell.new(I18n.t(view.enabled ? "form_ui.forms.enabled" : "form_ui.forms.disabled")),
          ], view.enabled ? "" : "pd-muted")
        end
        table = Table.new(I18n.t("form.menu.form_definitions"), columns, rows, Ui.url("forms"),
          empty_message: I18n.t("form_ui.forms.none"), id: "form-forms")
        actions = can_design? ? [link_action("form_ui.forms.new", Ui.url("form_new"), "primary", "plus")] : [] of Screen::Action
        list_page(I18n.t("form.menu.form_definitions"), table, crumbs({I18n.t("form.menu.form_definitions"), nil}),
          "form_ui.forms.csv_name", actions, intro: I18n.t("form_ui.forms.intro"))
      end
    end

    # Formulaire de définition (création, modification).
    abstract class FormScreen < Handler
      FIELDS = %w[title description purpose controller retention_days success_message category_id max_files]

      def submitted : Hash(String, String)
        values = FIELDS.to_h { |name| {name, field(name)} }
        values["accepts_files"] = checkbox("accepts_files") ? "1" : ""
        values["enabled"] = checkbox("enabled") ? "1" : ""
        values
      end

      def values_of(view : Api::FormView) : Hash(String, String)
        {"title" => view.title, "description" => view.description, "purpose" => view.purpose,
         "controller" => view.controller, "retention_days" => view.retention_days.to_s,
         "success_message" => view.success_message, "category_id" => view.category_id.to_s,
         "accepts_files" => view.accepts_files ? "1" : "", "max_files" => view.max_files.to_s,
         "enabled" => view.enabled ? "1" : ""}
      end

      def definition_form(values : Hash(String, String)) : UiForm
        value = ->(name : String) { values[name]? || "" }
        category_options = [option("", I18n.t("form_ui.definition.no_category"))] +
                           categories.map { |category| option(category.id.to_s, "#{category.code} · #{category.name}") }
        files = (1..Api::MAX_FILES).map { |count| option(count.to_s, count.to_s) }
        presentation = [
          UiForm::Field.new("title", I18n.t("form_ui.definition.title"), value: value.call("title"), required: true,
            maxlength: 120),
          UiForm::Field.new("description", I18n.t("form_ui.definition.description"), "textarea",
            value.call("description"), help: I18n.t("form_ui.definition.description_help"), maxlength: 4000),
          UiForm::Field.new("success_message", I18n.t("form_ui.definition.success_message"), "textarea",
            value.call("success_message"), help: I18n.t("form_ui.definition.success_message_help"), maxlength: 1000),
          UiForm::Field.new("enabled", I18n.t("form_ui.definition.enabled"), "checkbox", value.call("enabled")),
        ]
        privacy = [
          UiForm::Field.new("purpose", I18n.t("form_ui.definition.purpose"), "textarea", value.call("purpose"),
            required: true, help: I18n.t("form_ui.definition.purpose_help"), maxlength: 2000),
          UiForm::Field.new("controller", I18n.t("form_ui.definition.controller"), value: value.call("controller"),
            required: true, help: I18n.t("form_ui.definition.controller_help"), maxlength: 300),
          UiForm::Field.new("retention_days", I18n.t("form_ui.definition.retention_days"), "number",
            value.call("retention_days"), required: true,
            help: I18n.t("form_ui.definition.retention_help", max: Api::MAX_RETENTION)),
        ]
        reception = [
          UiForm::Field.new("category_id", I18n.t("form_ui.definition.category"), "select", value.call("category_id"),
            options: category_options, help: I18n.t("form_ui.definition.category_help")),
          UiForm::Field.new("accepts_files", I18n.t("form_ui.definition.accepts_files"), "checkbox",
            value.call("accepts_files"), help: I18n.t("form_ui.definition.accepts_files_help")),
          UiForm::Field.new("max_files", I18n.t("form_ui.definition.max_files"), "select", value.call("max_files"),
            options: files),
        ]
        UiForm.new([
          UiForm::Group.new(I18n.t("form_ui.definition.presentation"), presentation),
          UiForm::Group.new(I18n.t("form_ui.definition.privacy"), privacy),
          UiForm::Group.new(I18n.t("form_ui.definition.reception"), reception),
        ])
      end

      def read_input(form : UiForm) : Api::FormInput?
        errors = [] of {String, String}
        retention = integer("retention_days", errors)
        max_files = integer("max_files", errors) || 1
        errors.each { |(name, message)| form.add_error(name, message) }
        return if form.invalid || retention.nil?
        Api::FormInput.new(title: field("title"), purpose: field("purpose"), controller: field("controller"),
          description: field("description"), retention_days: retention, success_message: field("success_message"),
          category_id: field("category_id").to_i64?, accepts_files: checkbox("accepts_files"), max_files: max_files,
          enabled: checkbox("enabled"))
      end
    end

    class FormNewHandler < FormScreen
      def get
        show(definition_form({"retention_days" => Api::DEFAULT_RETENTION.to_s, "max_files" => "1", "enabled" => "1"}))
      end

      def post
        form = definition_form(submitted)
        if input = read_input(form)
          result = Api.create_form(actor, input)
          if result.success?
            flash["success"] = I18n.t("form_ui.flash.form_saved", title: result.value!.title)
            return go(Ui.url("form", id: result.value!.id))
          end
          form.add_errors(result.errors, fmt)
        end
        show(form)
      end

      private def show(form : UiForm) : Marten::HTTP::Response
        title = I18n.t("form_ui.forms.new")
        form_page(title, crumbs({I18n.t("form.menu.form_definitions"), Ui.url("forms")}, {title, nil}), form,
          Ui.url("form_new"), I18n.t("ui.forms.create"), Ui.url("forms"), intro: I18n.t("form_ui.definition.intro"))
      end
    end

    class FormEditHandler < FormScreen
      def get
        view = Api.form(actor, id_param)
        show(view, definition_form(values_of(view)))
      end

      def post
        view = Api.form(actor, id_param)
        form = definition_form(submitted)
        if input = read_input(form)
          result = Api.update_form(actor, view.id, input)
          if result.success?
            flash["success"] = I18n.t("form_ui.flash.form_saved", title: result.value!.title)
            return go(Ui.url("form", id: view.id))
          end
          form.add_errors(result.errors, fmt)
        end
        show(view, form)
      end

      private def show(view : Api::FormView, form : UiForm) : Marten::HTTP::Response
        title = I18n.t("form_ui.forms.edit")
        form_page(title, crumbs({I18n.t("form.menu.form_definitions"), Ui.url("forms")},
          {view.title, Ui.url("form", id: view.id)}, {title, nil}), form, Ui.url("form_edit", id: view.id),
          I18n.t("ui.forms.save"), Ui.url("form", id: view.id), intro: I18n.t("form_ui.definition.intro"))
      end
    end

    # `/ext/FORM/forms/<id>` : un formulaire, ses champs et ses liens publics.
    class FormHandler < Handler
      def get
        view = Api.form(actor, id_param)
        items = [
          Screen::Item.new(I18n.t("form_ui.definition.purpose"), view.purpose),
          Screen::Item.new(I18n.t("form_ui.definition.controller"), view.controller),
          Screen::Item.new(I18n.t("form_ui.definition.retention_days"), I18n.t("form_ui.definition.days", count: view.retention_days)),
          Screen::Item.new(I18n.t("form_ui.definition.category"), view.category_id ? category_name(view.category_id) : I18n.t("form_ui.definition.no_category")),
          Screen::Item.new(I18n.t("form_ui.definition.accepts_files"),
            view.accepts_files ? I18n.t("form_ui.definition.files_up_to", count: view.max_files) : yes_no(false)),
          Screen::Item.new(I18n.t("form_ui.forms.pending"), view.pending_count.to_s, Ui.url("inbox") + "?form=#{view.id}"),
        ]
        sections = [
          Screen::Section.new(I18n.t("form_ui.definition.summary"), items, note: view.description.presence),
          Screen::Section.new(I18n.t("form_ui.fields.title"), table: fields_table(view),
            actions: can_design? ? [link_action("form_ui.fields.new", Ui.url("field_new", id: view.id), "small", "plus")] : nil),
          Screen::Section.new(I18n.t("form_ui.links.title"), table: links_table(view),
            note: I18n.t("form_ui.links.note"),
            actions: can_admin? ? [link_action("form_ui.links.new", Ui.url("link_new", id: view.id), "small", "send")] : nil),
        ]
        actions = [] of Screen::Action
        actions << link_action("form_ui.forms.edit", Ui.url("form_edit", id: view.id), "", "pencil") if can_design?
        if can_admin?
          actions << post_action("form_ui.forms.delete", Ui.url("form_delete", id: view.id), "form_ui.forms.delete_confirm",
            "danger", "trash-2")
        end
        status = I18n.t(view.enabled ? "form_ui.forms.enabled" : "form_ui.forms.disabled")
        detail_page(view.title, crumbs({I18n.t("form.menu.form_definitions"), Ui.url("forms")}, {view.title, nil}),
          sections, actions, status_tag: status)
      end

      private def fields_table(view : Api::FormView) : Table
        columns = [
          Table::Column.new("label", I18n.t("form_ui.fields.label"), sortable: false),
          Table::Column.new("key", I18n.t("form_ui.fields.key"), "mono", secondary: true, sortable: false),
          Table::Column.new("kind", I18n.t("form_ui.fields.kind"), sortable: false),
          Table::Column.new("required", I18n.t("form_ui.fields.required"), sortable: false),
          Table::Column.new("target", I18n.t("form_ui.fields.target"), secondary: true, sortable: false),
          Table::Column.new("actions", "", "actions"),
        ]
        last = view.fields.size - 1
        rows = view.fields.map_with_index do |field, index|
          actions = [] of Screen::Action
          if can_design?
            actions << row_post("form_ui.fields.up", Ui.url("field_up", id: field.id), field.label) if index > 0
            actions << row_post("form_ui.fields.down", Ui.url("field_down", id: field.id), field.label) if index < last
            actions << row_post("form_ui.fields.delete", Ui.url("field_delete", id: field.id), field.label,
              "form_ui.fields.delete_confirm", "row-danger")
          end
          url = can_design? ? Ui.url("field_edit", id: field.id) : nil
          Table::Row.new([
            Table::Cell.new(field.label, url),
            Table::Cell.new(field.key),
            Table::Cell.new(I18n.t(field.kind_key)),
            Table::Cell.new(yes_no(field.required)),
            Table::Cell.new(Ui.target_label(field.target)),
            Table::Cell.new("", actions: actions),
          ])
        end
        Table.new(I18n.t("form_ui.fields.title"), columns, rows, Ui.url("form", id: view.id),
          empty_message: I18n.t("form_ui.fields.none"), id: "form-fields")
      end

      private def links_table(view : Api::FormView) : Table
        columns = [
          Table::Column.new("label", I18n.t("form_ui.links.label"), sortable: false),
          Table::Column.new("hint", I18n.t("form_ui.links.hint"), "mono", sortable: false),
          Table::Column.new("expires", I18n.t("form_ui.links.expires_at"), "mono", sortable: false),
          Table::Column.new("uses", I18n.t("form_ui.links.uses"), "mono", sortable: false),
          Table::Column.new("state", I18n.t("form_ui.links.state"), sortable: false),
          Table::Column.new("actions", "", "actions"),
        ]
        rows = Api.links(actor, view.id).map do |link|
          actions = [] of Screen::Action
          if can_admin? && link.revoked_at.nil?
            actions << row_post("form_ui.links.revoke", Ui.url("link_revoke", id: link.id), link.hint,
              "form_ui.links.revoke_confirm", "row-danger")
          end
          Table::Row.new([
            Table::Cell.new(link.label.presence || "—"),
            Table::Cell.new("#{link.hint}…"),
            Table::Cell.new(fmt.datetime(link.expires_at)),
            Table::Cell.new("#{link.uses} / #{link.max_uses}"),
            Table::Cell.new(I18n.t(link.state_key)),
            Table::Cell.new("", actions: actions),
          ], link.active? ? "" : "pd-muted")
        end
        Table.new(I18n.t("form_ui.links.title"), columns, rows, Ui.url("form", id: view.id),
          empty_message: I18n.t("form_ui.links.none"), id: "form-links")
      end

      private def row_post(label_key : String, url : String, subject : String, confirm_key : String? = nil,
                           style : String = "row") : Screen::Action
        action = post_action(label_key, url, confirm_key, style)
        action.aria_label = "#{I18n.t(label_key)} #{subject}"
        action
      end
    end

    class FormDeleteHandler < Handler
      def get
        go(Ui.url("form", id: id_param))
      end

      def post
        result = Api.delete_form(actor, id_param)
        return after(result, "form_ui.flash.form_deleted", Ui.url("forms")) if result.success?
        after(result, "form_ui.flash.form_deleted", Ui.url("form", id: id_param))
      end
    end
  end
end
