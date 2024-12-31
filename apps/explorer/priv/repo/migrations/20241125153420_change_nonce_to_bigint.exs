defmodule Explorer.Repo.Migrations.ChangeNonceToBigint do
  use Ecto.Migration

  def change do
    alter table(:transactions) do
      modify(:nonce, :decimal, precision: 100, null: true)
    end

    alter table(:addresses) do
      modify(:nonce, :decimal, precision: 100, null: true)
    end
  end
end
