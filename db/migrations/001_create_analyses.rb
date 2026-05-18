Sequel.migration do
  change do
    create_table(:analyses) do
      primary_key :id
      String  :month,        null: false
      String  :sectors,      null: false
      String  :macro,        null: false, text: true
      String  :candidates,   null: false, text: true
      String  :radar,        text: true
      String  :raw_response, text: true
      DateTime :created_at,  default: Sequel::CURRENT_TIMESTAMP
    end
  end
end
