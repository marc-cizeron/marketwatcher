Sequel.migration do
  up do
    create_table(:ticker_mappings) do
      primary_key :id
      String  :isin,       null: false, unique: true
      String  :name,       null: false, default: ''
      String  :ticker                          # NULL = non mappé
      DateTime :created_at
      DateTime :updated_at
    end

    # Seed : correspondances connues
    now = Time.now
    [
      # Actions françaises
      ['FR0000120271', 'TotalEnergies',              'TTE.PA'],
      ['FR0000131906', 'Renault',                    'RNO.PA'],
      ['FR0000120073', 'Air Liquide',                'AI.PA'],
      ['FR0000121329', 'Thales',                     'HO.PA'],
      ['FR0000073272', 'Safran',                     'SAF.PA'],
      ['FR0014004L86', 'Dassault Aviation',          'AM.PA'],
      ['FR0010220475', 'Alstom',                     'ALO.PA'],
      ['FR0000054470', 'Ubisoft',                    'UBI.PA'],
      ['FR0010221234', 'Eutelsat Communications',    'ETL.PA'],
      # ETFs
      ['FR001400U5Q4', 'Amundi PEA Monde MSCI World', 'DCAM.PA'],
      ['FR0011550185', 'BNP Paribas Easy S&P 500',   'ESE.PA'],
      ['FR0013380607', 'Amundi Core CAC 40',          'CACC.PA'],
      ['LU1681048804', 'Amundi S&P 500 Swap EUR',     '500.PA'],
      ['IE000BI8OT95', 'Amundi Core MSCI World',      'MWRD.PA'],
      ['IE00BMTM6B32', 'WisdomTree WTI Crude Oil 3x', '3OIL.L'],
      # Actions européennes
      ['LU1598757687', 'ArcelorMittal',              'MT.AS'],
      ['NL0010273215', 'ASML',                       'ASML.AS'],
      ['NL00150001Q9', 'Stellantis',                 'NL00150001Q9.SG'],
      ['DE0005313704', 'Carl Zeiss Meditec',         'AFX.DE'],
      ['DE0007030009', 'Rheinmetall',                'RHM.DE'],
      # Actions US / Canada / Asie
      ['US67066G1040', 'NVIDIA',                     'NVDA'],
      ['US5253271028', 'Leidos',                     'LDOS'],
      ['US75513E1010', 'RTX Corporation',            'RTX'],
      ['US52661A1088', 'Leonardo DRS',               'DRS'],
      ['US5024413065', 'LVMH ADR',                   'LVMUY'],
      ['CA13321L1085', 'Cameco',                     'CCJ'],
      ['CNE100000296', 'BYD',                        '1211.HK'],
      ['KYG982AW1003', 'Xpeng',                      '9868.HK'],
      # Crypto
      ['BTC',          'Bitcoin',                    'BTC-USD'],
      # Produits structurés sans ticker — ticker NULL = ignoré à l'import
      ['DE000SQ4SUR5', 'Semiconductors ETP (SG)',    nil],
    ].each do |isin, name, ticker|
      from(:ticker_mappings).insert(
        isin: isin, name: name, ticker: ticker,
        created_at: now, updated_at: now
      )
    end
  end

  down do
    drop_table(:ticker_mappings)
  end
end
