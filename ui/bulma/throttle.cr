# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  module Ui
    # Limitation de débit propre à la page publique (D-FRM-007, D-FRM-017),
    # en plus du débit par adresse que l'interface applique à toute la route
    # (`PartiduoUi::Extensions.public_mount`) : envois par adresse et par
    # lien, blocage des essais de jetons. Sur le modèle de
    # `PartiduoUi::RateLimit` (fenêtre glissante en mémoire, par processus ;
    # adresse du client lue par `PartiduoUi::RateLimit.client_ip`, derrière
    # le proxy de confiance). Les adresses ne sont gardées qu'en mémoire, le
    # temps de la fenêtre, jamais en base ni dans le journal. Le contrat
    # ajoute une limite durable par lien et par heure, en base.
    module Throttle
      record Rule, limit : Int32, window : Time::Span

      RULES = {
        # Envois, par adresse et par lien.
        "submit_ip"   => Rule.new(10, 10.minutes),
        "submit_link" => Rule.new(20, 10.minutes),
        # Jetons refusés, par adresse : au-delà, l'adresse est bloquée pour
        # la fenêtre, même avec un lien valide (essais de jetons).
        "invalid" => Rule.new(10, 15.minutes),
      }

      @@hits = {} of String => Array(Time)
      @@mutex = Mutex.new

      # Enregistre une demande ; `false` si la limite est atteinte.
      def self.allow?(bucket : String, key : String, now : Time = Time.utc) : Bool
        rule = RULES[bucket]
        @@mutex.synchronize do
          purge(now) if @@hits.size > 10_000
          hits = recent("#{bucket}|#{key}", rule, now)
          return false if hits.size >= rule.limit
          hits << now
          true
        end
      end

      # Enregistre un échec, sans refuser.
      def self.record(bucket : String, key : String, now : Time = Time.utc) : Nil
        rule = RULES[bucket]
        @@mutex.synchronize { recent("#{bucket}|#{key}", rule, now) << now }
      end

      def self.exceeded?(bucket : String, key : String, now : Time = Time.utc) : Bool
        rule = RULES[bucket]
        @@mutex.synchronize { recent("#{bucket}|#{key}", rule, now).size >= rule.limit }
      end

      def self.reset! : Nil
        @@mutex.synchronize { @@hits.clear }
      end

      private def self.recent(key : String, rule : Rule, now : Time) : Array(Time)
        hits = (@@hits[key] ||= [] of Time)
        hits.reject! { |time| time <= now - rule.window }
        hits
      end

      private def self.purge(now : Time) : Nil
        longest = RULES.values.max_of(&.window)
        @@hits.reject! { |_, hits| hits.all? { |time| time <= now - longest } }
      end
    end
  end
end
