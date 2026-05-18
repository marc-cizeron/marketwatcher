require 'json'
require_relative '../../config/settings'

module Agent
  class PromptBuilder
    def initialize(portfolio:, watchlist:, sectors: Settings::SECTORS, user_context: Settings::USER_CONTEXT)
      @portfolio    = portfolio
      @watchlist    = watchlist
      @sectors      = sectors
      @user_context = user_context
      @date         = Date.today.strftime('%Y-%m-%d')
    end

    def short_term_prompt
      existing = @portfolio.map { |p| p[:ticker] || p['ticker'] }.join(', ')
      total_value = @portfolio.sum { |p| (p[:market_value] || p['market_value'] || 0).to_f }
      sector_alloc = @portfolio.group_by { |p| p[:sector] || p['sector'] }.map do |sector, positions|
        value = positions.sum { |p| (p[:market_value] || p['market_value'] || 0).to_f }
        pct   = total_value > 0 ? (value / total_value * 100).round(1) : 0
        "#{sector}: #{pct}% (#{value.round(0)}€)"
      end.join(', ')

      <<~PROMPT
        Tu es un analyste financier senior spécialisé en actions internationales. Date d'aujourd'hui : #{@date}.

        Contexte utilisateur : #{@user_context}

        Portefeuille actuel (valeur totale : #{total_value.round(0)}€) :
        #{JSON.pretty_generate(@portfolio)}

        Allocation par secteur : #{sector_alloc.empty? ? 'portefeuille vide' : sector_alloc}

        Secteurs d'intérêt : #{@sectors.join(', ')}

        Utilise la recherche web pour analyser l'actualité boursière récente (7 derniers jours).
        Identifie 5 actions cotées (NYSE, NASDAQ, Euronext) avec potentiel haussier sur 30 jours.

        Critères de sélection :
        - Catalyseur identifiable (résultats, contrat, réglementation, macro)
        - Momentum technique ou rebond sur support
        - Liquidité suffisante (volume journalier > 500k)
        - Préférer les secteurs sous-représentés dans le portefeuille existant
        - Tenir compte des P&L latents pour évaluer le profil de risque global
        - Exclure (déjà en portefeuille) : #{existing.empty? ? 'aucun' : existing}

        Réponds UNIQUEMENT en JSON strict, sans markdown, sans commentaire :
        {
          "macro": "contexte macro en 2-3 phrases",
          "candidates": [
            {
              "ticker": "CF",
              "name": "CF Industries Holdings",
              "exchange": "NYSE",
              "sector": "industrie",
              "thesis": "thèse d'investissement détaillée",
              "catalyst": "catalyseur principal",
              "risk": "risque principal",
              "signal": "momentum|technique|rebond|catalyseur",
              "conviction": "haute|moyenne|faible",
              "avoid_reason": null
            }
          ],
          "recommendation": "TICKER_RECOMMANDÉ",
          "recommendation_rationale": "pourquoi ce ticker en particulier"
        }
      PROMPT
    end

    def long_term_prompt
      existing_tickers = @portfolio.map { |p| p[:ticker] || p['ticker'] }
      watching_tickers = @watchlist.map { |w| w[:ticker] || w['ticker'] }
      exclude = (existing_tickers + watching_tickers).uniq.join(', ')

      <<~PROMPT
        Tu es un analyste financier long terme. Date d'aujourd'hui : #{@date}.

        Secteurs d'intérêt pour le radar long terme : #{@sectors.join(', ')}

        Exclure (déjà en portefeuille ou sous surveillance) : #{exclude.empty? ? 'aucun' : exclude}

        Contexte utilisateur : #{@user_context}

        Utilise la recherche web pour identifier 1 à 2 actions pour un horizon d'investissement de 20-30 ans.

        Critères :
        - Fossé compétitif durable (brevet, réseau, coût de substitution)
        - Croissance structurelle du secteur
        - Dividende ou potentiel de croissance
        - Valorisation raisonnable (pas de bulle)

        Réponds UNIQUEMENT en JSON strict :
        {
          "radar": [
            {
              "ticker": "...",
              "name": "...",
              "exchange": "...",
              "sector": "...",
              "thesis_long": "thèse long terme détaillée",
              "entry_strategy": "DCA|attendre_support|entrer_maintenant",
              "target_price": null,
              "horizon": "20-30 ans",
              "conviction": "haute|moyenne"
            }
          ]
        }
      PROMPT
    end
  end
end
