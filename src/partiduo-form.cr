# SPDX-License-Identifier: AGPL-3.0-or-later

# Point d'entrée du shard `partiduo-form` : le métier de l'extension des
# formulaires (manifeste, modèles, jetons, contrôle des envois, boîte de
# réception, purge, contrat `Forms::Api`), sans interface. L'interface
# Bulma, qui porte aussi la page publique, est dans `ui/bulma/`, requise à
# part par la distribution : `require "partiduo-form/ui/bulma"`.
#
# La distribution ajoute ensuite `Forms::INSTALLED_APPS` à ses applications
# Marten, et `require "partiduo-form/cli"` à sa ligne de commande
# (migrations, purge).
require "partiduo"

require "./forms/app"
