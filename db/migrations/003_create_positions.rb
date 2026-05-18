Sequel.migration do
  change do
    create_table(:positions) do
      primary_key :id
      String   :ticker,        null: false
      String   :name,          null: false
      String   :exchange,      null: false
      String   :sector,        null: false
      String   :horizon,       default: 'long'
      Float    :avg_price
      Float    :current_price
      Float    :shares
      String   :conviction,    default: 'haute'
      String   :notes,         text: true
      Date     :added_at
      DateTime :updated_at
    end
  end
end
