# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  module Ui
    # Formulaire d'un champ (création, modification) : clé, libellé,
    # nature, obligatoire, longueur, choix, aide et cible dans la fiche.
    abstract class FieldScreen < Handler
      FIELDS = %w[key label kind max_length choices help target]

      def submitted : Hash(String, String)
        values = FIELDS.to_h { |name| {name, field(name)} }
        values["required"] = checkbox("required") ? "1" : ""
        values
      end

      def values_of(view : Api::FieldView) : Hash(String, String)
        {"key" => view.key, "label" => view.label, "kind" => view.kind, "max_length" => view.max_length.to_s,
         "choices" => view.choices.join("\n"), "help" => view.help, "target" => view.target,
         "required" => view.required ? "1" : ""}
      end

      def field_form(form : Api::FormView, values : Hash(String, String)) : UiForm
        value = ->(name : String) { values[name]? || "" }
        kinds = Api::FIELD_KINDS.map { |kind| option(kind, I18n.t("form.kinds.#{kind}")) }
        UiForm.new([UiForm::Group.new(nil, [
          UiForm::Field.new("label", I18n.t("form_ui.fields.label"), value: value.call("label"), required: true,
            maxlength: 200),
          UiForm::Field.new("key", I18n.t("form_ui.fields.key"), value: value.call("key"), required: true, mono: true,
            maxlength: 40, help: I18n.t("form_ui.fields.key_help")),
          UiForm::Field.new("kind", I18n.t("form_ui.fields.kind"), "select", value.call("kind"), options: kinds),
          UiForm::Field.new("required", I18n.t("form_ui.fields.required"), "checkbox", value.call("required"),
            help: I18n.t("form_ui.fields.required_help")),
          UiForm::Field.new("max_length", I18n.t("form_ui.fields.max_length"), "number", value.call("max_length"),
            help: I18n.t("form_ui.fields.max_length_help")),
          UiForm::Field.new("choices", I18n.t("form_ui.fields.choices"), "textarea", value.call("choices"),
            help: I18n.t("form_ui.fields.choices_help")),
          UiForm::Field.new("help", I18n.t("form_ui.fields.help"), value: value.call("help"), maxlength: 300),
          UiForm::Field.new("target", I18n.t("form_ui.fields.target"), "select", value.call("target"),
            options: target_options(form), help: I18n.t("form_ui.fields.target_help")),
        ])])
      end

      # Cibles offertes : champs de la fiche, attributs propres de la
      # catégorie du formulaire ; aucune si le formulaire n'en vise pas.
      def target_options(form : Api::FormView) : Array(UiForm::Option)
        list = [option("", I18n.t("form_ui.fields.no_target"))]
        category_id = form.category_id || return list
        list += Api::CARD_TARGETS.map { |target| option(target, Ui.target_label(target)) }
        if category = categories.find { |item| item.id == category_id }
          list += category.attributes.map { |attribute| option("extra.#{attribute.key}", attribute.label) }
        end
        list
      end

      def read_input(form : UiForm) : Api::FieldInput?
        errors = [] of {String, String}
        max_length = integer("max_length", errors, required: false)
        errors.each { |(name, message)| form.add_error(name, message) }
        return if form.invalid
        Api::FieldInput.new(key: field("key"), label: field("label"), kind: field("kind").presence || "text",
          required: checkbox("required"), max_length: max_length, choices: field("choices", strip: false),
          help: field("help"), target: field("target"))
      end

      def field_crumbs(form : Api::FormView, title : String) : Array(Screen::Crumb)
        crumbs({I18n.t("form.menu.form_definitions"), Ui.url("forms")}, {form.title, Ui.url("form", id: form.id)},
          {title, nil})
      end
    end

    class FieldNewHandler < FieldScreen
      def get
        form = Api.form(actor, id_param)
        show(form, field_form(form, {"kind" => "text"}))
      end

      def post
        form = Api.form(actor, id_param)
        ui_form = field_form(form, submitted)
        if input = read_input(ui_form)
          result = Api.add_field(actor, form.id, input)
          if result.success?
            flash["success"] = I18n.t("form_ui.flash.field_saved", label: result.value!.label)
            return go(Ui.url("form", id: form.id))
          end
          ui_form.add_errors(result.errors, fmt)
        end
        show(form, ui_form)
      end

      private def show(form : Api::FormView, ui_form : UiForm) : Marten::HTTP::Response
        title = I18n.t("form_ui.fields.new")
        form_page(title, field_crumbs(form, title), ui_form, Ui.url("field_new", id: form.id), I18n.t("ui.forms.create"),
          Ui.url("form", id: form.id), intro: I18n.t("form_ui.fields.intro"))
      end
    end

    class FieldEditHandler < FieldScreen
      def get
        view, form = load
        show(form, view, field_form(form, values_of(view)))
      end

      def post
        view, form = load
        ui_form = field_form(form, submitted)
        if input = read_input(ui_form)
          result = Api.update_field(actor, view.id, input)
          if result.success?
            flash["success"] = I18n.t("form_ui.flash.field_saved", label: result.value!.label)
            return go(Ui.url("form", id: form.id))
          end
          ui_form.add_errors(result.errors, fmt)
        end
        show(form, view, ui_form)
      end

      private def load : {Api::FieldView, Api::FormView}
        view = Api.field(actor, id_param)
        {view, Api.form(actor, view.form_id)}
      end

      private def show(form : Api::FormView, view : Api::FieldView, ui_form : UiForm) : Marten::HTTP::Response
        form_page(view.label, field_crumbs(form, view.label), ui_form, Ui.url("field_edit", id: view.id),
          I18n.t("ui.forms.save"), Ui.url("form", id: form.id), intro: I18n.t("form_ui.fields.intro"))
      end
    end

    # Commandes d'un champ (effacer, monter, descendre) : retour au
    # formulaire.
    abstract class FieldCommand < Handler
      def get
        go(Ui.url("forms"))
      end

      def form_url : String
        Ui.url("form", id: Api.field(actor, id_param).form_id)
      end
    end

    class FieldDeleteHandler < FieldCommand
      def post
        url = form_url
        after(Api.delete_field(actor, id_param), "form_ui.flash.field_deleted", url)
      end
    end

    class FieldUpHandler < FieldCommand
      def post
        url = form_url
        after(Api.move_field(actor, id_param, up: true), "form_ui.flash.field_moved", url)
      end
    end

    class FieldDownHandler < FieldCommand
      def post
        url = form_url
        after(Api.move_field(actor, id_param, up: false), "form_ui.flash.field_moved", url)
      end
    end
  end
end
