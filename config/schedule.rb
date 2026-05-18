require 'clockwork'
require_relative 'boot'
require_relative '../app/jobs/monthly_analysis'
require_relative '../app/services/sure_sync'

module Clockwork
  every(1.day, 'monthly.analysis', at: "#{Settings::ANALYSIS_HOUR.to_s.rjust(2, '0')}:00") do
    if Time.now.day == Settings::ANALYSIS_DAY
      MonthlyAnalysisJob.run!
    end
  end

  every(1.day, 'sure.sync', at: ['08:00', '12:00', '17:00', '21:00']) do
    results = SureSync.new.sync!
    $stdout.puts "[SureSync] #{results[:created]} créées, #{results[:updated]} mises à jour"
  rescue => e
    $stderr.puts "[SureSync ERROR] #{e.message}"
  end
end
