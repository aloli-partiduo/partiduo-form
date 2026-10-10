# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  # Purge des réponses arrivées à l'échéance de leur durée de conservation
  # (D-FRM-011), pièces en quarantaine comprises (clé étrangère en
  # cascade). Une pièce déjà versée au dossier y reste : elle relève alors
  # de la conservation du dossier, comme la fiche créée. Interne.
  module Purge
    Log = ::Log.for("partiduo.form")

    def self.run(now : Time = Records.now) : Int64
      count = Response.filter(purge_after__lte: now).delete(raw: true)
      Log.info { "purge : #{count} réponse(s) effacée(s)" } if count > 0
      count
    end
  end
end
