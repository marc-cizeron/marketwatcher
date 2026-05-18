Sequel.migration do
  change do
    create_table(:bets) do
      primary_key :id
      foreign_key :analysis_id, :analyses, null: true
      String   :month,        null: false
      String   :ticker,       null: false
      String   :name,         null: false
      String   :exchange,     null: false
      String   :thesis,       null: false, text: true
      Float    :entry_price
      Float    :exit_price
      Float    :budget,       default: 50.0
      Date     :entry_date
      Date     :exit_date
      String   :status,       default: 'pending'
      Float    :pct_change
      Float    :gain_eur
      String   :notes,        text: true
      DateTime :created_at,   default: Sequel::CURRENT_TIMESTAMP
    end
  end
end
