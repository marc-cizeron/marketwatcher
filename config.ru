$LOAD_PATH.unshift(File.dirname(__FILE__))
$stdout.sync = true
$stderr.sync = true

require 'dotenv/load'
require_relative 'config/settings'
require_relative 'config/database'

Sequel.extension :migration
begin
  Sequel::Migrator.run(DB, File.join(File.dirname(__FILE__), 'db/migrations'))
rescue => e
  warn "Migration error: #{e.message}"
  raise
end

require_relative 'app/models/analysis'
require_relative 'app/models/bet'
require_relative 'app/models/position'
require_relative 'app/models/watchlist'
require_relative 'app/web/app'

run MarketwatchApp
