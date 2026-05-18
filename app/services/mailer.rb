require 'mail'
require_relative '../../config/settings'

class Mailer
  def self.notify_analysis(month:, bet_ticker:, candidates:, macro:)
    return if Settings::SMTP_HOST.empty? || Settings::NOTIFY_EMAIL.empty?

    Mail.defaults do
      delivery_method :smtp,
        address:              Settings::SMTP_HOST,
        port:                 Settings::SMTP_PORT,
        user_name:            Settings::SMTP_USER,
        password:             Settings::SMTP_PASS,
        authentication:       :plain,
        enable_starttls_auto: true
    end

    subject = "MarketWatch — Analyse #{month} disponible"

    candidates_text = candidates.first(3).map.with_index(1) do |c, i|
      ticker     = c['ticker'] || c[:ticker]
      name       = c['name']   || c[:name]
      conviction = c['conviction'] || c[:conviction]
      thesis     = c['thesis'] || c[:thesis]
      "#{i}. #{ticker} — #{name} (#{conviction})\n   #{thesis}"
    end.join("\n\n")

    body = <<~BODY
      Bonjour,

      Une nouvelle analyse MarketWatch est disponible pour #{month}.

      CONTEXTE MACRO
      #{macro}

      PARI DU MOIS
      #{bet_ticker || 'Aucun'}

      TOP CANDIDATS
      #{candidates_text}

      ---
      Voir l'analyse complète : #{Settings::PERMITTED_HOSTS.split(',').first&.strip&.then { |h| "https://#{h}/analysis/#{month}" }}
    BODY

    Mail.new do
      from    Settings::SMTP_USER
      to      Settings::NOTIFY_EMAIL
      subject subject
      body    body
    end.deliver!
  end
end
