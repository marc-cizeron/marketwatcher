Sequel.migration do
  up do
    # La migration 006 ne s'exécute que si ticker_mappings n'existait pas
    # encore — sur un environnement où 005 vient de créer la table avec ses
    # 30 correspondances d'origine (sans STMicro), 006 est un no-op et ce
    # mapping n'est jamais inséré. On le force ici, indépendamment de l'état.
    next unless table_exists?(:ticker_mappings)
    next if from(:ticker_mappings).where(isin: 'NL0000226223').count > 0

    from(:ticker_mappings).insert(
      isin: 'NL0000226223', name: 'STMicroelectronics', ticker: 'STMPA.PA',
      created_at: Time.now, updated_at: Time.now
    )
  end

  down do
  end
end
