# SPDX-License-Identifier: AGPL-3.0-or-later

class PartiduoUi::PublicExtensionHandler
  # Pour la page publique des formulaires (`/p/form/…`), sur *toute*
  # réponse, y compris celles que l'interface rend avant le handler de
  # l'extension (extension inactive, débit, taille, protection CSRF :
  # 404, 429, 413, 403) :
  #
  # - masque le jeton dans le chemin que le journal des requêtes du serveur
  #   Marten écrit après la réponse (D-FRM-015) ;
  # - pose les en-têtes stricts communs (`Extensions::PUBLIC_HEADERS`), que
  #   le point d'entrée ne pose pas encore sur le refus de la protection
  #   CSRF, rendu avant son `dispatch`.
  #
  # Contournement (D-FRM-017, amendement A-FRM-4) : à retirer quand
  # l'interface masquera les chemins publics et sécurisera ses refus.
  def process_dispatch : Marten::HTTP::Response
    response = super
    form_path? ? secured(response) : response
  ensure
    request.partiduo_form_mask_path(Forms::Ui::MASKED_PATH) if form_path?
  end

  private def form_path? : Bool
    request.path.starts_with?("#{PartiduoUi::Extensions::PUBLIC_PREFIX}#{Forms::CODE.downcase}/")
  end
end
