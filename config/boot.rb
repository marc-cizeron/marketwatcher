$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..'))

require 'dotenv/load'
require_relative 'settings'
require_relative 'database'

Sequel.extension :migration
begin
  Sequel::Migrator.run(DB, File.join(File.dirname(__FILE__), '../db/migrations'))
rescue => e
  $stderr.puts "[Boot] Migration error: #{e.message}"
  raise
end

require_relative '../app/models/analysis'
require_relative '../app/models/bet'
require_relative '../app/models/position'
require_relative '../app/models/watchlist'
require_relative '../app/web/app'
