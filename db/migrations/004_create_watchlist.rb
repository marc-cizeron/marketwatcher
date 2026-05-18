Sequel.migration do
  change do
    create_table(:watchlists) do
      primary_key :id
      String   :ticker,       null: false
      String   :name,         null: false
      String   :exchange,     null: false
      String   :sector,       null: false
      String   :thesis,       text: true
      Float    :target_entry
      String   :horizon
      String   :status,       default: 'watching'
      String   :source_month
      String   :notes,        text: true
      DateTime :created_at,   default: Sequel::CURRENT_TIMESTAMP
    end
  end
end
