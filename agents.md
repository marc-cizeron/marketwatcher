# MarketWatch — Agent Reference

Application personnelle de suivi de portefeuille et d'analyse boursière pilotée par IA (Claude).

## Stack technique

- **Langage :** Ruby 3.3
- **Framework web :** Sinatra 4.0 (Rack via `config.ru`)
- **Base de données :** SQLite + Sequel ORM (migrations dans `db/migrations/`)
- **Planificateur :** Clockwork (`config/schedule.rb`)
- **HTTP client :** Faraday
- **IA :** Anthropic Claude API (`claude-sonnet-4-6`)
- **Email :** gem Mail (SMTP)
- **Tests :** RSpec
- **Déploiement :** Docker Compose (2 services : `app` + `clock`)

## Architecture

```
marketwatch/
├── app/
│   ├── agent/          # Intégration Claude (analyzer, prompt_builder, web_search)
│   ├── jobs/           # Jobs planifiés (monthly_analysis)
│   ├── models/         # Modèles Sequel (Analysis, Bet, Position, Watchlist)
│   ├── services/       # Mailer, SureSync
│   └── web/            # Sinatra app + vues ERB
├── config/             # boot, database, settings, schedule
├── db/migrations/      # Schéma via migrations Sequel
└── spec/               # Tests RSpec
```

## Base de données (4 tables)

| Table | Rôle |
|-------|------|
| `analyses` | Analyses mensuelles générées par Claude (macro, candidats, radar) |
| `bets` | Paris boursiers (ticker, prix entrée/sortie, P&L) |
| `positions` | Portefeuille en cours (ticker, parts, prix moyen/actuel, secteur) |
| `watchlists` | Actions sous surveillance |

## Intégrations externes

| Service | Rôle | Variable d'env |
|---------|------|---------------|
| Anthropic Claude API | Génération des analyses (2 prompts : court/long terme) | `ANTHROPIC_API_KEY` |
| Sure API | Sync automatique du portefeuille broker | `SURE_API_URL`, `SURE_API_KEY` |
| SMTP | Notification email après analyse | `SMTP_*`, `NOTIFY_EMAIL` |

## Jobs planifiés

| Job | Fréquence | Rôle |
|-----|-----------|------|
| `MonthlyAnalysis` | 1×/mois (J1, 7h) | Claude génère 5 candidats courts termes + 1-2 longs termes |
| `SureSync` | 4×/jour (8h, 12h, 17h, 21h) | Synchronise trades et prix depuis le broker Sure |

## Routes principales (`app/web/app.rb`)

| Route | Rôle |
|-------|------|
| `GET /login` | Authentification par mot de passe |
| `GET /` | Dashboard (dernière analyse, paris ouverts, positions) |
| `GET /analysis/:month` | Détail d'une analyse mensuelle |
| `GET /bets` | Historique des paris (pending / open / closed) |
| `GET /portfolio` | Gestion du portefeuille + bouton sync Sure |
| `GET /watchlist` | Actions sous surveillance |
| `GET /settings` | Affichage de la config |
| `POST /trigger` | Déclenchement manuel d'une analyse (`TRIGGER_TOKEN`) |

## Variables d'environnement clés

| Variable | Description |
|----------|-------------|
| `ANTHROPIC_API_KEY` | Clé API Anthropic (obligatoire) |
| `APP_PASSWORD` | Mot de passe de connexion à l'app |
| `TRIGGER_TOKEN` | Token pour déclencher une analyse manuellement |
| `ANALYSIS_DAY` / `ANALYSIS_HOUR` | Contrôle du planning d'analyse |
| `DEFAULT_BUDGET` | Budget par pari (€) |
| `SECTORS` | Filtrage des secteurs d'analyse |
| `SURE_API_KEY` / `SURE_API_URL` | Accès à l'API broker Sure |

## Commandes utiles

```bash
# Développement
bundle install
rake db:migrate
bundle exec rackup config.ru        # Serveur web → localhost:4567
bundle exec clockwork config/schedule.rb  # Planificateur

# Tests
bundle exec rspec spec/

# Déclencher une analyse manuellement
rake analysis:run

# Production (Docker)
docker-compose up -d
```

## Pipeline d'analyse IA

1. `MonthlyAnalysis` orchestre l'ensemble
2. `PromptBuilder` construit 2 prompts (court terme + long terme)
3. `Analyzer` appelle l'API Claude avec outil `web_search` (2 appels avec gestion du rate limit)
4. Résultat JSON parsé → stocké dans `analyses`
5. Email de notification envoyé via `Mailer`
