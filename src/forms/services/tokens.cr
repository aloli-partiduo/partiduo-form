# SPDX-License-Identifier: AGPL-3.0-or-later

module Forms
  # Jetons des liens publics (D-FRM-006) : 256 bits aléatoires
  # (`Random::Secure`), en base64url sans remplissage (43 caractères). Seule
  # l'empreinte SHA-256 est conservée : une fuite de la table ne donne aucun
  # lien utilisable. Un jeton mal formé est écarté avant toute requête.
  # Interne.
  module Tokens
    BYTES  = 32
    FORMAT = /\A[A-Za-z0-9_-]{43}\z/

    def self.generate : String
      Base64.urlsafe_encode(Random::Secure.random_bytes(BYTES), padding: false)
    end

    def self.digest(token : String) : String
      OpenSSL::Digest.new("SHA256").update(token).final.hexstring
    end

    def self.well_formed?(token : String) : Bool
      token.matches?(FORMAT)
    end

    # Quatre premiers caractères : de quoi reconnaître un lien dans la liste
    # et dans le journal, sans rien livrer d'utile (24 bits sur 256).
    def self.hint(token : String) : String
      token[0, 4]
    end
  end
end
