require 'dotenv/load'
require_relative 'config/database'

namespace :db do
  desc 'Run migrations'
  task :migrate do
    Sequel.extension :migration
    Sequel::Migrator.run(DB, 'db/migrations')
    puts 'Migrations done.'
  end

  desc 'Reset database'
  task :reset do
    File.delete('db/marketwatch.db') if File.exist?('db/marketwatch.db')
    Rake::Task['db:migrate'].invoke
    puts 'Database reset.'
  end
end

namespace :analysis do
  desc 'Trigger monthly analysis manually'
  task :run do
    require_relative 'app/jobs/monthly_analysis'
    MonthlyAnalysisJob.run!
    puts 'Analysis complete.'
  end
end
