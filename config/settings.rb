require 'dotenv/load'
require 'securerandom'

module Settings
  ANTHROPIC_API_KEY = ENV.fetch('ANTHROPIC_API_KEY', '') unless defined?(ANTHROPIC_API_KEY)
  ANALYSIS_DAY      = ENV.fetch('ANALYSIS_DAY', '1').to_i unless defined?(ANALYSIS_DAY)
  ANALYSIS_HOUR     = ENV.fetch('ANALYSIS_HOUR', '7').to_i unless defined?(ANALYSIS_HOUR)
  SECTORS           = ENV.fetch('SECTORS', 'energie,tech,defense,industrie,alimentation').split(',') unless defined?(SECTORS)
  DEFAULT_BUDGET    = ENV.fetch('DEFAULT_BUDGET', '50').to_f unless defined?(DEFAULT_BUDGET)
  APP_SECRET        = ENV.fetch('APP_SECRET', SecureRandom.hex(32)) unless defined?(APP_SECRET)
  TRIGGER_TOKEN     = ENV.fetch('TRIGGER_TOKEN', '') unless defined?(TRIGGER_TOKEN)
  PORT              = ENV.fetch('PORT', '4567').to_i unless defined?(PORT)
  DATABASE_PATH     = ENV.fetch('DATABASE_PATH', 'db/marketwatch.db') unless defined?(DATABASE_PATH)

  USER_CONTEXT = ENV.fetch('USER_CONTEXT',
    'Investisseur particulier français, horizon mixte court/long terme, budget pari 50€/mois.'
  ) unless defined?(USER_CONTEXT)
end
