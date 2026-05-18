require 'spec_helper'

RSpec.describe Bet do
  let(:analysis) do
    Analysis.create(
      month: '2026-05', sectors: '[]', macro: 'test',
      candidates: '[{"ticker":"CF","name":"CF Industries","exchange":"NYSE"}]'
    )
  end

  let(:bet) do
    Bet.create(
      analysis_id: analysis.id,
      month: '2026-05',
      ticker: 'CF',
      name: 'CF Industries',
      exchange: 'NYSE',
      thesis: 'Test thesis',
      budget: 50.0,
      status: 'pending'
    )
  end

  it 'creates a bet' do
    expect(bet.ticker).to eq('CF')
    expect(bet.status).to eq('pending')
  end

  it 'opens a bet with entry price' do
    bet.open!(42.50)
    expect(bet.status).to eq('open')
    expect(bet.entry_price).to eq(42.50)
    expect(bet.entry_date).to eq(Date.today)
  end

  it 'closes a bet and calculates P&L' do
    bet.open!(40.0)
    bet.close!(44.0)
    expect(bet.status).to eq('closed')
    expect(bet.pct_change).to eq(10.0)
    expect(bet.gain_eur).to eq(5.0)
  end

  it 'calculates days remaining after opening' do
    bet.open!(40.0, Date.today - 10)
    expect(bet.days_remaining).to eq(20)
  end

  it 'calculates unrealized P&L' do
    bet.open!(40.0)
    pnl = bet.unrealized_pnl(42.0)
    expect(pnl[:pct]).to eq(5.0)
    expect(pnl[:eur]).to be_within(0.01).of(2.5)
  end
end
