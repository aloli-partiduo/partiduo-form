# SPDX-License-Identifier: AGPL-3.0-or-later

# Migration de données (D-FRM-021) : reprise `form_attach_files` (D-FRM-019)
# jouée d'elle-même au démarrage de chaque instance, puisque le script rc.d
# passe `partiduo-manage migrate` avant le serveur (D-PKG-012 du cœur).
# Rattache à leur fiche les pièces des réponses acceptées avant que
# l'acceptation ne les rattache elle-même, avec l'acteur système, une
# transaction par réponse ; idempotente, sans effet sur une base neuve. Elle
# est jouée que l'extension soit active ou non : elle ne fait qu'écrire le
# lien que l'acceptation aurait écrit, et une migration ne se rejoue pas à
# l'activation. La commande `manage form_attach_files` reste pour un
# passage manuel. Retour arrière : rien à défaire (un lien rattaché reste
# vrai).
class Migration::Forms::V0002 < Marten::Migration
  depends_on :form, "0001_create_form"
  depends_on :cards, "0006_card_attachments_iban"

  def plan
    run_code :attach_accepted_files, :keep_links
  end

  def attach_accepted_files : Nil
    count = ::Forms::Processing.attach_accepted_files(Partiduo::Api::Actor.system)
    Log.for("partiduo.form").info { "pièces de #{count} réponse(s) acceptée(s) rattachées à leur fiche (D-FRM-021)" } if count > 0
  end

  def keep_links : Nil
  end
end
