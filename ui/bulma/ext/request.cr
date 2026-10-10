# SPDX-License-Identifier: AGPL-3.0-or-later

class Marten::HTTP::Request
  # Remplace le chemin de la requête HTTP sous-jacente, une fois la réponse
  # produite : le journal des requêtes du serveur Marten
  # (`Marten::Server::Handlers::Logger`) l'écrit après coup et n'y lit plus
  # le jeton de la page publique (D-FRM-015, amendement A-FRM-4).
  def partiduo_form_mask_path(path : String) : Nil
    @request.path = path
  end
end
