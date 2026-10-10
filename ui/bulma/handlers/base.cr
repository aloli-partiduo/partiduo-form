# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  module Ui
    # Base des écrans authentifiés de l'extension, sur celle des écrans du
    # référentiel de l'interface (listes, formulaires et consultations des
    # gabarits `ui/reference/*.html`) : fil d'Ariane « Formulaires › … »,
    # lecture des champs, messages des commandes. L'accès a déjà été
    # contrôlé par `PartiduoUi::ExtensionHandler` à partir du montage ;
    # `Forms::Api` vérifie encore la permission de chaque commande.
    abstract class Handler < PartiduoUi::ReferenceHandler
      alias Api = Forms::Api
      alias UiForm = PartiduoUi::Form
      alias Table = PartiduoUi::Table
      alias Screen = PartiduoUi::Screen

      def actor : Partiduo::Api::Actor
        current.actor
      end

      def crumbs(*items : {String, String?}) : Array(Screen::Crumb)
        list = [crumb("form.menu.form")]
        items.each { |(label, url)| list << Screen::Crumb.new(label, url) }
        list
      end

      def can_process? : Bool
        can?(Api::PROCESS)
      end

      def can_design? : Bool
        can?(Api::DESIGN)
      end

      def can_admin? : Bool
        can?(Api::ADMIN)
      end

      def messages(result) : String
        result.errors.map { |error| fmt.message(error) }.join(" ")
      end

      # Redirection après une commande, avec le message du résultat.
      def after(result, success_key : String, url : String, params = {} of String => String) : Marten::HTTP::Response
        if result.success?
          flash["success"] = I18n.t(success_key, params)
        else
          flash["danger"] = messages(result)
        end
        go(url)
      end

      # Catégories de fiches lisibles par l'acteur.
      def categories : Array(Partiduo::Api::Cards::CategoryView)
        @categories ||= begin
          Partiduo::Api::Cards.categories(actor)
        rescue Partiduo::Api::AccessDenied
          [] of Partiduo::Api::Cards::CategoryView
        end
      end

      @categories : Array(Partiduo::Api::Cards::CategoryView)?

      def category_name(id : Int64?) : String
        return "" unless id
        categories.find { |category| category.id == id }.try(&.name) || "##{id}"
      end
    end

    # `/ext/FORM/` : la boîte de réception.
    class IndexHandler < Handler
      def get
        go(Ui.url("inbox"))
      end
    end
  end
end
