# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module Forms
  module Commands
    # `manage form_purge` : efface les réponses arrivées à l'échéance de
    # leur durée de conservation (D-FRM-011), à lancer *chaque jour* par le
    # planificateur de l'instance. Idempotente. Réponse JSON sur la sortie
    # standard ; extension inactive : rien n'est fait (code 0). La boîte de
    # réception purge aussi à chaque lecture.
    #
    # ```
    # partiduo - manage form_purge
    # ```
    class Purge < Marten::CLI::Manage::Command::Base
      command_name :form_purge
      help "Efface les réponses aux formulaires arrivées à l'échéance de leur durée de conservation."

      def run
        unless Partiduo::Modules.active?(Forms::CODE)
          return print({"status" => "skipped", "reason" => "module_inactive"}.to_json)
        end
        count = Forms::Api.purge(Partiduo::Api::Actor.system)
        print({"status" => "ok", "purged" => count}.to_json)
      end
    end
  end
end
