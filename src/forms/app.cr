# SPDX-License-Identifier: AGPL-3.0-or-later

require "base64"
require "json"
require "openssl"

require "./manifest"
require "./models/**"
require "./services/**"
require "./api/**"

# Extension des formulaires de Partiduo : formulaires définis par champs
# typés, publiés par des liens à jeton (expiration, révocation, nombre
# d'envois borné), seule surface publique sans authentification ; réponses
# reçues dans une boîte à traiter par un utilisateur authentifié, qui crée
# la fiche par le contrat du cœur s'il le décide ; finalité et durée de
# conservation affichées, purge à l'échéance. Même plan qu'une application
# du cœur : `manifest.cr`, `models/`, `migrations/`, `services/` (internes),
# `api/` (contrat public `Forms::Api`), `commands/`, `locales/`.
module Forms
  # Lue à la compilation dans `shard.yml`, seule source du numéro : chaque
  # commit y incrémente le dernier chiffre.
  VERSION = {{
              (read_file("#{__DIR__}/../../shard.yml")
                .lines
                .find(&.starts_with?("version:")) || "version: 0.0.0")
                .gsub(/^version:\s*/, "")
                .chomp
            }}

  # Code du registre (ADR-003 D2) : `form` dans `PARTIDUO_MODULES`.
  CODE = "FORM"

  # Application Marten du métier : modèles (tables `form_*`), migrations et
  # libellés.
  class App < Marten::App
    label "form"
  end

  # Applications Marten du métier, à ajouter à `installed_apps` de la
  # distribution après `Partiduo::INSTALLED_APPS`.
  INSTALLED_APPS = [Forms::App] of Marten::Apps::Config.class
end
