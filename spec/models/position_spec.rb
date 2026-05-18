require 'spec_helper'

RSpec.describe Position do
  let(:position) do
    Position.create(
      ticker: 'NEE', name: 'NextEra Energy', exchange: 'NYSE',
      sector: 'energie', horizon: 'long',
      avg_price: 60.0, current_price: 72.0,
      shares: 10.0, conviction: 'haute',
      added_at: Date.today
    )
  end

  it 'creates a position' do
    expect(position.ticker).to eq('NEE')
  end

  it 'calculates P&L percentage' do
    expect(position.pnl_pct).to eq(20.0)
  end

  it 'calculates P&L in EUR' do
    expect(position.pnl_eur).to eq(120.0)
  end

  it 'calculates market value' do
    expect(position.market_value).to eq(720.0)
  end

  it 'calculates cost basis' do
    expect(position.cost_basis).to eq(600.0)
  end
end
