require 'clockwork'
require_relative 'boot'
require_relative '../app/jobs/monthly_analysis'

module Clockwork
  every(1.day, 'monthly.analysis', at: "#{Settings::ANALYSIS_HOUR.to_s.rjust(2, '0')}:00") do
    if Time.now.day == Settings::ANALYSIS_DAY
      MonthlyAnalysisJob.run!
    end
  end
end
