# frozen_string_literal: true

module SkillsInjector
  module Templates
    # Database patterns skill template.
    module DatabasePatterns
      HEADER = <<~HEADER
        ---
        name: database-patterns
        description: Database migration and query patterns for this project. Loaded automatically for database-related changes.
        ---

        # Database Patterns
      HEADER

      PG_SECTION = <<~PG
        ## PostgreSQL

        - Use `text` instead of `string` for unbounded text (no performance difference in PG).
        - `citext` extension available for case-insensitive text.
        - Use `jsonb` (not `json`) for JSON columns — it's indexable and faster.
        - Array columns: `t.string :tags, array: true, default: []`.
        - Use `uuid` primary keys if the project already does.
        - `ILIKE` for case-insensitive search (or `citext`).
        - `EXPLAIN ANALYZE` to check query plans.
      PG

      MYSQL_SECTION = <<~MY
        ## MySQL

        - `string` columns default to `varchar(255)`. Specify `limit:` when needed.
        - Use `utf8mb4` charset for full Unicode support (check existing schema).
        - No partial index support before MySQL 8.0.13 — use full indices.
        - `LIKE` is case-insensitive by default with utf8 collation.
        - Use `EXPLAIN` to check query plans.
        - Maximum index key length depends on charset and row format.
        - `datetime` precision: use `precision: 6` for microseconds if the project does.
      MY

      QUERIES_SECTION = <<~QUERIES
        ## Query Patterns

        - Use ActiveRecord query interface. Avoid raw SQL unless necessary.
        - Use `includes` / `preload` / `eager_load` to prevent N+1 queries.
        - Use `find_each` / `in_batches` for iterating over large datasets.
        - Use `pluck` when you only need specific columns.
        - Use `exists?` instead of `present?` on relations (avoids loading records).
        - Prefer `where.not(...)` over raw SQL for negation.
        - Add `null: false` to required columns in migrations.
        - Add database-level constraints (unique indices, foreign keys) — don't rely solely on validations.
      QUERIES

      MIGRATION_TEMPLATE = <<~MIG
        ## Migrations

        Migration superclass: `ActiveRecord::Migration%s`

        ```ruby
        class AddFieldToTable < ActiveRecord::Migration%s
          def change
            add_column :table, :field, :type
          end
        end
        ```

        - Use `change` for reversible migrations. Use `up`/`down` only when `change` can't reverse.
        - Add indices for foreign keys and columns used in `WHERE`/`ORDER BY`.
        - Use `add_reference` for foreign keys (adds index automatically).
        - For large tables, consider `disable_ddl_transaction!` + `algorithm: :concurrently` for index creation.
      MIG

      module_function

      def build(stack)
        sections = [HEADER]
        sections << migration_for(Templates.rails_major(stack))
        sections.concat(db_sections(stack[:databases] || []))
        sections << QUERIES_SECTION
        sections.compact.join("\n")
      end

      def migration_for(major)
        return nil unless major

        version = major >= 5 ? "[#{major}.0]" : ''
        format(MIGRATION_TEMPLATE, version, version)
      end

      def db_sections(dbs)
        sections = []
        sections << PG_SECTION if dbs.include?('postgresql')
        sections << MYSQL_SECTION if dbs.include?('mysql')
        sections
      end

      private_class_method :migration_for, :db_sections
    end
  end
end
