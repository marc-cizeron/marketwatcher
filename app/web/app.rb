require 'sinatra/base'
require 'sinatra/reloader'
require 'json'
require 'digest'
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
    redirect "/portfolio?notice=#{results[:created]}+créées,+#{results[:updated]}+mises+à+jour"
  rescue => e
    halt 500, "Erreur sync Sure : #{e.message}"
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
