require 'sinatra/base'
require 'sinatra/reloader'
require 'json'
require 'digest'
require 'cgi'
require_relative '../../config/settings'
require_relative '../../app/models/analysis'
require_relative '../../app/models/bet'
require_relative '../../app/models/position'
require_relative '../../app/models/watchlist'

class MarketwatchApp < Sinatra::Base
  configure :development do
    register Sinatra::Reloader
  end

  set :root,          File.join(File.dirname(__FILE__))
  set :views,         File.join(File.dirname(__FILE__), 'views')
  set :public_folder, File.join(File.dirname(__FILE__), '../../public')

  permitted = ENV.fetch('PERMITTED_HOSTS', '').split(',').map(&:strip).reject(&:empty?)
  set :host_authorization, { permitted_hosts: permitted } unless permitted.empty?

  use Rack::Session::Cookie,
      key:    'mw_session',
      secret: Digest::SHA512.hexdigest(Settings::APP_SECRET),
      expire_after: 60 * 60 * 24 * 30

  before do
    unless request.path_info.start_with?('/login')
      redirect '/login' unless session[:authenticated]
    end
  end

  get '/login' do
    erb :login, layout: false
  end

  post '/login' do
    if params[:password] == Settings::APP_PASSWORD
      session[:authenticated] = true
      redirect '/'
    else
      @error = 'Mot de passe incorrect'
      erb :login, layout: false
    end
  end

  get '/logout' do
    session.clear
    redirect '/login'
  end

  get '/' do
    @analysis    = Analysis.order(Sequel.desc(:created_at)).first
    @current_bet = Bet.where(status: %w[pending open]).order(Sequel.desc(:created_at)).first
    @positions   = Position.order(:sector, :ticker).all
    @recent_bets = Bet.where(status: 'closed').order(Sequel.desc(:exit_date)).limit(6).all
    erb :dashboard
  end

  get '/analysis/:month' do
    @analysis = Analysis.where(month: params[:month]).first
    halt 404, 'Analysis not found' unless @analysis
    erb :analysis
  end

  get '/bets' do
    @bets = Bet.order(Sequel.desc(:created_at)).all
    erb :bets
  end

  post '/bets/:id/open' do
    bet = Bet.find(id: params[:id].to_i)
    halt 404 unless bet
    bet.open!(params[:entry_price].to_f, Date.parse(params[:entry_date]))
    redirect '/bets'
  end

  post '/bets/:id/close' do
    bet = Bet.find(id: params[:id].to_i)
    halt 404 unless bet
    bet.close!(params[:exit_price].to_f, Date.parse(params[:exit_date]))
    redirect '/bets'
  end

  get '/portfolio' do
    @positions = Position.order(:sector, :ticker).all

    @total_value    = @positions.sum { |p| p.market_value || 0 }.round(2)
    @total_cost     = @positions.sum { |p| p.cost_basis   || 0 }.round(2)
    @total_pnl_eur  = @positions.sum { |p| p.pnl_eur      || 0 }.round(2)
    @total_pnl_pct  = @total_cost > 0 ? (@total_pnl_eur / @total_cost * 100).round(2) : nil
    @position_count = @positions.count

    @long_count  = @positions.count { |p| p.horizon == 'long' }
    @medium_count = @positions.count { |p| p.horizon == 'medium' }
    @long_pct    = @position_count > 0 ? (@long_count.to_f / @position_count * 100).round(0).to_i : 0

    @by_sector = @positions.group_by(&:sector).transform_values { |ps|
      ps.sum { |p| p.market_value || 0 }.round(2)
    }.sort_by { |_, v| -v }.to_h

    erb :portfolio
  end

  post '/portfolio' do
    attrs = {
      ticker:        params[:ticker].upcase,
      name:          params[:name],
      exchange:      params[:exchange],
      sector:        params[:sector],
      horizon:       params[:horizon] || 'long',
      avg_price:     params[:avg_price].to_f,
      current_price: params[:current_price].to_f,
      shares:        params[:shares].to_f,
      conviction:    params[:conviction] || 'haute',
      notes:         params[:notes],
      added_at:      Date.today,
      updated_at:    Time.now
    }
    Position.create(attrs)
    redirect '/portfolio'
  end

  post '/portfolio/sync' do
    require_relative '../../app/services/sure_sync'
    results = SureSync.new.sync!
    notice = CGI.escape("#{results[:created]} créées, #{results[:updated]} mises à jour, #{results[:deleted]} supprimées")
    redirect "/portfolio?notice=#{notice}"
  rescue => e
    halt 500, "Erreur sync Sure : #{e.message}"
  end

  get '/portfolio/:id/edit' do
    @position = Position.find(id: params[:id].to_i)
    halt 404 unless @position
    erb :portfolio_edit
  end

  post '/portfolio/:id' do
    pos = Position.find(id: params[:id].to_i)
    halt 404 unless pos
    pos.update(
      sector:     params[:sector],
      horizon:    params[:horizon],
      conviction: params[:conviction],
      notes:      params[:notes],
      exchange:   params[:exchange],
      updated_at: Time.now
    )
    redirect '/portfolio'
  end


  get '/watchlist' do
    @items = Watchlist.order(:status, :ticker).all
    erb :watchlist
  end

  post '/watchlist/:id/enter' do
    item = Watchlist.find(id: params[:id].to_i)
    halt 404 unless item
    item.enter!
    redirect '/watchlist'
  end

  get '/settings' do
    erb :settings
  end

  get '/import' do
    @result = nil
    erb :import
  end

  post '/import' do
    unless params[:file] && params[:file][:tempfile]
      @error = 'Aucun fichier sélectionné'
      @result = nil
      next erb :import
    end

    csv_content = params[:file][:tempfile].read.force_encoding('UTF-8')
    dry_run     = params[:dry_run] != 'false'
    from_date   = params[:from_date].to_s.strip

    require_relative '../../app/services/tr_importer'
    importer = TrImporter.new(dry_run: dry_run, from_date: from_date.empty? ? nil : from_date)
    @result  = importer.import!(csv_content)
    @dry_run = dry_run
    erb :import
  rescue CSV::MalformedCSVError => e
    @error  = "CSV invalide : #{e.message}"
    @result = nil
    erb :import
  rescue => e
    @error  = "Erreur : #{e.message}"
    @result = nil
    erb :import
  end

  post '/trigger' do
    halt 403 unless params[:token] == Settings::TRIGGER_TOKEN
    require_relative '../../app/jobs/monthly_analysis'
    if params[:force] == 'true'
      month = Date.today.strftime('%Y-%m')
      existing = Analysis.where(month: month).first
      if existing
        Bet.where(analysis_id: existing.id).delete
        existing.delete
        $stdout.puts "Deleted existing analysis for #{month}"
      end
    end
    Thread.new do
      MonthlyAnalysisJob.run!
    rescue => e
      $stderr.puts "[MonthlyAnalysisJob ERROR] #{e.message}"
      $stderr.puts e.backtrace.first(10).join("\n")
    end
    'Analysis triggered. Check logs for progress.'
  end
end
