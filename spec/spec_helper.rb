ENV['DATABASE_PATH'] = ':memory:'
ENV['ANTHROPIC_API_KEY'] ||= 'test'

require 'dotenv/load'
require_relative '../config/database'
require_relative '../config/settings'

Sequel.extension :migration
Sequel::Migrator.run(DB, File.join(File.dirname(__FILE__), '../db/migrations'))

require_relative '../app/models/analysis'
require_relative '../app/models/bet'
require_relative '../app/models/position'
require_relative '../app/models/watchlist'

RSpec.configure do |config|
  config.before(:each) do
    DB.run('PRAGMA foreign_keys = OFF')
    DB.tables.each { |t| DB[t].delete }
    DB.run('PRAGMA foreign_keys = ON')
  end
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
