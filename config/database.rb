require 'sequel'
require_relative 'settings'

DB = Sequel.sqlite(Settings::DATABASE_PATH, timeout: 10_000)
DB.extension(:pagination)

Sequel::Model.db = DB
