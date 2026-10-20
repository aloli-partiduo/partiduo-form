# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

module Forms
  module Commands
    # `manage form_attach_files` : reprise, à lancer une fois après la mise à
    # jour (D-FRM-019) ; rattache à leur fiche les pièces des réponses
    # acceptées *avant* que l'acceptation ne les rattache elle-même, tant
    # que ces réponses sont conservées (après leur purge, plus rien ne relie
    # la pièce à la fiche). Idempotente. Réponse JSON sur la sortie
    # standard ; extension inactive : rien n'est fait (code 0).
    #
    # ```
    # partiduo - manage form_attach_files
    # ```
    class AttachFiles < Marten::CLI::Manage::Command::Base
      command_name :form_attach_files
      help "Rattache à leur fiche les pièces des réponses aux formulaires acceptées avant ce rattachement."

      def run
        unless Partiduo::Modules.active?(Forms::CODE)
          return print({"status" => "skipped", "reason" => "module_inactive"}.to_json)
        end
        count = Forms::Api.attach_accepted_files(Partiduo::Api::Actor.system)
        print({"status" => "ok", "responses" => count}.to_json)
      end
    end
  end
end
