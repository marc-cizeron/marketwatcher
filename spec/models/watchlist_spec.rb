require 'spec_helper'

RSpec.describe Watchlist do
  let(:item) do
    Watchlist.create(
      ticker: 'BEP', name: 'Brookfield Renewable', exchange: 'NYSE',
      sector: 'energie', thesis: 'Transition énergétique mondiale.',
      horizon: '20-30 ans', status: 'watching', source_month: '2026-05'
    )
  end

  it 'creates a watchlist item' do
    expect(item.ticker).to eq('BEP')
    expect(item.status).to eq('watching')
  end

  it 'enters a position' do
    item.enter!
    expect(item.status).to eq('entered')
  end
end
