# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  # Résolution d'un jeton reçu par la page publique (D-FRM-006). Le jeton
  # n'est jamais journalisé ; un refus ne dit pas pourquoi au visiteur
  # (lien inconnu, expiré, révoqué, épuisé ou formulaire désactivé : même
  # réponse), seul le journal en garde le motif, avec l'indice du lien.
  # Interne.
  module Links
    Log = ::Log.for("partiduo.form")

    record Resolved, link : Link, definition : Definition

    # Lien utilisable et son formulaire, ou `nil`. `lock` : verrouille la
    # ligne du lien (envoi).
    def self.resolve(token : String, lock : Bool = false) : Resolved?
      unless Tokens.well_formed?(token)
        refuse("malformed", nil)
        return
      end
      query = Link.filter(token_digest: Tokens.digest(token))
      query = query.lock if lock
      link = query.first
      if link.nil?
        refuse("unknown", nil)
        return
      end
      state = Records.link_state(link)
      unless state == "active"
        refuse(state, link)
        return
      end
      definition = Definition.filter(id: link.definition_id).first
      if definition.nil? || !definition.enabled!
        refuse("disabled", link)
        return
      end
      Resolved.new(link, definition)
    end

    private def self.refuse(reason : String, link : Link?) : Nil
      Log.info { "lien public refusé : #{reason}#{link ? " (lien #{link.id}, #{link.token_hint}…)" : ""}" }
    end
  end
end
