require 'spec_helper'

RSpec.describe Analysis do
  let(:valid_attrs) do
    {
      month:      '2026-05',
      sectors:    '["energie","tech"]',
      macro:      'Contexte macro test.',
      candidates: '[{"ticker":"CF","name":"CF Industries","exchange":"NYSE","sector":"industrie","thesis":"...","conviction":"haute"}]',
      radar:      '[{"ticker":"NEE","name":"NextEra Energy","sector":"energie"}]'
    }
  end

  it 'creates a valid analysis' do
    analysis = Analysis.create(valid_attrs)
    expect(analysis.id).not_to be_nil
    expect(analysis.month).to eq('2026-05')
  end

  it 'parses candidates from JSON' do
    analysis = Analysis.create(valid_attrs)
    expect(analysis.candidates_parsed).to be_an(Array)
    expect(analysis.candidates_parsed.first['ticker']).to eq('CF')
  end

  it 'parses radar from JSON' do
    analysis = Analysis.create(valid_attrs)
    expect(analysis.radar_parsed.first['ticker']).to eq('NEE')
  end

  it 'parses sectors from JSON' do
    analysis = Analysis.create(valid_attrs)
    expect(analysis.sectors_parsed).to eq(['energie', 'tech'])
  end

  it 'returns empty array for malformed JSON candidates' do
    analysis = Analysis.create(valid_attrs.merge(candidates: 'bad json'))
    expect(analysis.candidates_parsed).to eq([])
  end
end
