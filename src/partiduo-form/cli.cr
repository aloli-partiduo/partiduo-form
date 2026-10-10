# SPDX-License-Identifier: AGPL-3.0-or-later

# Migrations et commandes de l'extension, requises par la ligne de commande
# Marten de la distribution (`require "partiduo-form/cli"`), comme
# `partiduo/cli` pour le cœur : `manage form_purge` efface les réponses
# arrivées à l'échéance de leur durée de conservation (D-FRM-011).
require "marten/cli"

require "../forms/migrations/**"
require "../forms/commands/**"
