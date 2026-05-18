require 'sequel'
require_relative 'settings'

DB = Sequel.sqlite(Settings::DATABASE_PATH)
DB.extension(:pagination)

Sequel::Model.db = DB
