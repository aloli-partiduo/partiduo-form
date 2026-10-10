# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  module Ui
    def self.url(name : String, **params) : String
      Marten.routes.reverse("form:#{name}", **params)
    end

    # Adresse publique d'un lien : chemin seul, l'écran ajoute l'origine de
    # la requête.
    def self.public_path(token : String) : String
      Marten.routes.reverse(PUBLIC_NAME, token: token)
    end

    # Classe Bulma du statut d'une réponse.
    def self.status_class(status : String) : String
      case status
      when "accepted" then "is-success"
      when "rejected" then "is-danger"
      when "closed"   then "is-light"
      else                 "is-warning"
      end
    end

    # Texte reçu du public, sans danger dans un tableur : une cellule qui
    # commencerait par `=`, `+`, `-`, `@` ou une tabulation serait lue
    # comme une formule (D-FRM-012).
    def self.csv_safe(text : String) : String
      text.matches?(/\A[=+\-@\t\r]/) ? "'#{text}" : text
    end

    # Libellé d'une cible de champ dans la fiche.
    def self.target_label(target : String) : String
      return "" if target.empty?
      return target.lchop("extra.") if target.starts_with?("extra.")
      I18n.t("form.targets.#{target}")
    end
  end
end
