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
  APP_PASSWORD      = ENV.fetch('APP_PASSWORD', '') unless defined?(APP_PASSWORD)
  SURE_API_URL          = ENV.fetch('SURE_API_URL', 'https://sur.cizeron.me') unless defined?(SURE_API_URL)
  SURE_API_KEY          = ENV.fetch('SURE_API_KEY', '') unless defined?(SURE_API_KEY)
  SURE_ACCOUNT_DEFAULT  = ENV.fetch('SURE_ACCOUNT_DEFAULT', '8051eea7-4b79-4116-ba1e-94dede17c60a') unless defined?(SURE_ACCOUNT_DEFAULT)
  SURE_ACCOUNT_PEA      = ENV.fetch('SURE_ACCOUNT_PEA',     '8379b33a-47b0-4c61-a178-38d5910d916e') unless defined?(SURE_ACCOUNT_PEA)

  SMTP_HOST         = ENV.fetch('SMTP_HOST', '') unless defined?(SMTP_HOST)
  SMTP_PORT         = ENV.fetch('SMTP_PORT', '587').to_i unless defined?(SMTP_PORT)
  SMTP_USER         = ENV.fetch('SMTP_USER', '') unless defined?(SMTP_USER)
  SMTP_PASS         = ENV.fetch('SMTP_PASS', '') unless defined?(SMTP_PASS)
  NOTIFY_EMAIL      = ENV.fetch('NOTIFY_EMAIL', '') unless defined?(NOTIFY_EMAIL)
  PORT              = ENV.fetch('PORT', '4567').to_i unless defined?(PORT)
  PERMITTED_HOSTS   = ENV.fetch('PERMITTED_HOSTS', '') unless defined?(PERMITTED_HOSTS)
  DATABASE_PATH     = ENV.fetch('DATABASE_PATH', 'db/marketwatch.db') unless defined?(DATABASE_PATH)

  USER_CONTEXT = ENV.fetch('USER_CONTEXT',
    'Investisseur particulier français, horizon mixte court/long terme, budget pari 50€/mois.'
  ) unless defined?(USER_CONTEXT)
end
