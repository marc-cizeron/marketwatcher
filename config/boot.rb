$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..'))

require 'dotenv/load'
require_relative 'settings'
require_relative 'database'

Sequel.extension :migration
Sequel::Migrator.run(DB, File.join(File.dirname(__FILE__), '../db/migrations')) rescue nil

require_relative '../app/models/analysis'
require_relative '../app/models/bet'
require_relative '../app/models/position'
require_relative '../app/models/watchlist'
require_relative '../app/web/app'
