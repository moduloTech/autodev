# frozen_string_literal: true

# Detects the target project's Ruby/Rails/DB/test stack and injects
# default Claude Code skills into `.claude/skills/` when the repo
# doesn't already provide its own.
#
# Skills are only injected into the temporary clone — the original
# repo is never modified. Existing skills are always preserved.
module SkillsInjector
  module_function

  # Main entry point. Call after clone + ensure_claude_md, before implement.
  # Returns a hash describing what was detected and injected.
  def inject(work_dir, logger:, project_path:)
    stack = detect_stack(work_dir)
    logger.info("Detected stack: #{stack.inspect}", project: project_path)

    skills_dir = File.join(work_dir, '.claude', 'skills')
    migrated = migrate_legacy_skills(skills_dir)
    if migrated.any?
      logger.info("Migrated #{migrated.size} legacy skill(s) to subdirectory format: #{migrated.join(', ')}",
                  project: project_path)
    end

    existing = existing_skills(skills_dir)

    if existing.any?
      logger.info("Project already has #{existing.size} skill(s): #{existing.join(', ')}", project: project_path)
    end

    injected = []

    unless existing.include?('code-conventions')
      write_skill(skills_dir, 'code-conventions', code_conventions_skill)
      injected << 'code-conventions'
    end

    unless existing.include?('rails-conventions')
      write_skill(skills_dir, 'rails-conventions', rails_conventions_skill(stack))
      injected << 'rails-conventions'
    end

    unless existing.include?('test-patterns')
      write_skill(skills_dir, 'test-patterns', test_patterns_skill(stack))
      injected << 'test-patterns'
    end

    unless existing.include?('database-patterns')
      write_skill(skills_dir, 'database-patterns', database_patterns_skill(stack))
      injected << 'database-patterns'
    end

    if injected.any?
      logger.info("Injected #{injected.size} skill(s): #{injected.join(', ')}", project: project_path)
    else
      logger.info('No skills injection needed', project: project_path)
    end

    all_skills = (existing + injected).uniq.sort
    { stack: stack, existing: existing, injected: injected, all_skills: all_skills }
  end

  # Builds a prompt instruction line listing skills to load.
  # Returns empty string if no skills.
  def skills_instruction(all_skills)
    return '' if all_skills.nil? || all_skills.empty?

    skill_list = all_skills.map { |s| "`#{s}`" }.join(', ')
    "- Avant de commencer, charge les skills suivants : #{skill_list}."
  end

  # ---------------------------------------------------------------------------
  # Stack detection
  # ---------------------------------------------------------------------------

  def detect_stack(work_dir)
    gemfile = read_file(work_dir, 'Gemfile')
    lockfile = read_file(work_dir, 'Gemfile.lock')
    database_yml = read_file(work_dir, 'config/database.yml')

    {
      ruby_version: detect_ruby_version(work_dir, gemfile),
      rails_version: detect_rails_version(gemfile, lockfile),
      databases: detect_databases(gemfile, database_yml),
      test_framework: detect_test_framework(work_dir, gemfile),
      api_only: gemfile&.include?('api_only') || gemfile&.match?(/config\.api_only/),
      has_sidekiq: gemfile&.include?('sidekiq') || false,
      sidekiq_mode: detect_sidekiq_mode(work_dir, gemfile),
      has_devise: gemfile&.include?('devise') || false,
      has_pundit: gemfile&.include?('pundit') || false,
      has_cancancan: gemfile&.include?('cancancan') || false,
      has_rubocop: gemfile&.include?('rubocop') || false
    }
  end

  def detect_ruby_version(work_dir, gemfile)
    # .ruby-version takes precedence
    rv = read_file(work_dir, '.ruby-version')&.strip
    return rv if rv && !rv.empty?

    # .tool-versions (mise/asdf)
    tv = read_file(work_dir, '.tool-versions')
    if tv
      match = tv.match(/^ruby\s+(\S+)/)
      return match[1] if match
    end

    # Gemfile ruby directive
    if gemfile
      match = gemfile.match(/^\s*ruby\s+["']([^"']+)["']/)
      return match[1] if match
    end

    nil
  end

  def detect_rails_version(gemfile, lockfile)
    # Lockfile is most precise
    if lockfile
      match = lockfile.match(/^\s+rails\s+\((\d+\.\d+(?:\.\d+)?)\)/)
      return match[1] if match

      match = lockfile.match(/^\s+railties\s+\((\d+\.\d+(?:\.\d+)?)\)/)
      return match[1] if match
    end

    # Gemfile constraint
    if gemfile
      match = gemfile.match(/gem\s+["']rails["']\s*,\s*["']~>\s*(\d+\.\d+(?:\.\d+)?)["']/)
      return match[1] if match

      match = gemfile.match(/gem\s+["']rails["']\s*,\s*["'](\d+\.\d+(?:\.\d+)?)["']/)
      return match[1] if match
    end

    nil
  end

  def detect_databases(gemfile, database_yml)
    dbs = []

    if gemfile
      dbs << 'postgresql' if gemfile.match?(/gem\s+["']pg["']/)
      dbs << 'mysql' if gemfile.match?(/gem\s+["']mysql2["']/)
      dbs << 'sqlite' if gemfile.match?(/gem\s+["']sqlite3["']/)
    end

    # database.yml can reveal DBs not obvious from Gemfile
    if database_yml && dbs.empty?
      dbs << 'postgresql' if database_yml.include?('postgresql')
      dbs << 'mysql' if database_yml.match?(/mysql2?(?:\s|$)/)
      dbs << 'sqlite' if database_yml.include?('sqlite')
    end

    dbs.uniq
  end

  def detect_sidekiq_mode(work_dir, gemfile)
    return nil unless gemfile&.include?('sidekiq')

    has_workers = Dir.exist?(File.join(work_dir, 'app', 'workers'))
    has_jobs = Dir.exist?(File.join(work_dir, 'app', 'jobs'))

    if has_workers && has_jobs
      'both'
    elsif has_workers
      'direct'    # perform_async, app/workers/
    else
      'activejob' # perform_later, app/jobs/, or Rails default since 4.2
    end
  end

  def detect_test_framework(work_dir, gemfile)
    has_rspec = gemfile&.match?(/gem\s+["']rspec/) || Dir.exist?(File.join(work_dir, 'spec'))
    has_minitest = Dir.exist?(File.join(work_dir, 'test'))

    if has_rspec && has_minitest
      'both'
    elsif has_rspec
      'rspec'
    elsif has_minitest
      'minitest'
    else
      'unknown'
    end
  end

  # ---------------------------------------------------------------------------
  # Skill templates
  # ---------------------------------------------------------------------------

  def code_conventions_skill
    <<~SKILL
      ---
      name: code-conventions
      description: Language-agnostic code conventions (comments, commit messages). Loaded automatically for any implementation task.
      ---

      # Code Conventions

      ## Code Comments

      **Always write comments in English.** Every class, module, method, and non-trivial block of code must be commented. Comments should address three questions:

      1. **WHAT** — What does this code do? A concise summary of its purpose.
      2. **WHY** — Why does it exist? The business reason, constraint, or decision behind it.
      3. **HOW** — How does it work? Explain the approach when the logic is not self-evident.

      Not every comment needs all three — use judgement:
      - A simple method may only need WHAT.
      - A workaround or edge-case handler should explain WHY.
      - A complex algorithm or non-obvious flow should explain HOW.

      ### Examples

      **Ruby:**
      ```ruby
      # Recalculates the invoice total after line items change.
      # Needed because cached totals can drift when discounts are applied retroactively.
      # Iterates line items in DB-order to match the rounding behavior of the billing API.
      def recalculate_total
        # ...
      end
      ```

      **JavaScript:**
      ```javascript
      // Removes expired group entries from the list and triggers a DOM refresh.
      // The backend may return stale entries when the cache TTL hasn't elapsed yet,
      // so we filter client-side to avoid displaying items the user just deleted.
      function pruneExpiredGroups(entries, cutoff) {
        // ...
      }
      ```

      ## Commit Messages

      **Always write commit messages in English.** Use the **Conventional Commits** format:

      ```
      <type>: <description>

      <body>
      ```

      ### Types

      - `feat` — new feature
      - `fix` — bug fix
      - `refactor` — code restructuring with no behavior change
      - `test` — adding or modifying tests
      - `docs` — documentation only
      - `chore` — maintenance tasks (dependencies, CI, tooling)

      ### Rules

      1. **Summary line** — `<type>: <concise description>` (imperative mood, no period, lowercase after colon).
      2. **Blank line**.
      3. **Body** — A detailed explanation of what changed and why. Wrap at 72 characters.

      The summary should be specific enough to be useful in `git log --oneline`. The body should explain
      the reasoning behind the change, not just restate the diff.

      ```
      fix: check discount expiration during invoice recalculation

      Invoices with expired discounts were still applying the reduced rate
      because recalculate_total read the discount amount without checking
      its validity period. Now checks discount.expired? before applying
      and falls back to the full line item price.
      ```

      Do not push. Do not ask for confirmation.
    SKILL
  end

  def rails_conventions_skill(stack)
    rails_v = stack[:rails_version]
    ruby_v = stack[:ruby_version]
    major = rails_v ? rails_v.split('.').first.to_i : nil

    sections = []

    sections << <<~HEADER
      ---
      name: rails-conventions
      description: Ruby on Rails project conventions, patterns, and version-specific guidance. Loaded automatically for Rails implementation tasks.
      ---

      # Rails Conventions
    HEADER

    # Version context
    if rails_v || ruby_v
      versions = []
      versions << "Ruby #{ruby_v}" if ruby_v
      versions << "Rails #{rails_v}" if rails_v
      sections << "This project uses **#{versions.join(' / ')}**."
    end

    # Version-specific guidance
    if major
      if major <= 4
        sections << <<~V4
          ## Rails 4.x Specifics

          - Use `before_action` (not `before_filter`, deprecated).
          - Strong Parameters via `params.require(:x).permit(...)` in controllers.
          - Assets pipeline via Sprockets (`app/assets/`).
          - `ActiveRecord::Base` is the model superclass (not `ApplicationRecord`).
          - Use `rake` for tasks (not `rails` — `rails` tasks came in Rails 5).
          - Migrations use `ActiveRecord::Migration` without version suffix.
        V4
      elsif major == 5
        sections << <<~V5
          ## Rails 5.x Specifics

          - `ApplicationRecord` is the model superclass.
          - `ApplicationController` is the controller superclass.
          - Migrations must specify version: `ActiveRecord::Migration[5.0]` (or 5.1, 5.2).
          - `belongs_to` is required by default (use `optional: true` if nullable).
          - Use `rails` CLI for tasks (not `rake`).
          - System tests with Capybara available via `test/system/`.
        V5
      elsif major == 6
        sections << <<~V6
          ## Rails 6.x Specifics

          - Webpacker is the default JS bundler (`app/javascript/`).
          - Action Mailbox and Action Text available.
          - Multi-database support via `connects_to`.
          - Migrations: `ActiveRecord::Migration[6.0]` (or 6.1).
          - `insert_all` / `upsert_all` for bulk operations.
          - Zeitwerk autoloader is default.
        V6
      elsif major == 7
        sections << <<~V7
          ## Rails 7.x Specifics

          - Import maps or jsbundling-rails/cssbundling-rails for assets (no Webpacker).
          - Hotwire (Turbo + Stimulus) is the default frontend approach.
          - Encrypted credentials via `rails credentials:edit`.
          - `query_constraints` for composite primary keys (7.1+).
          - `normalizes` for attribute normalization (7.1+).
          - `generates_token_for` for token generation (7.1+).
          - Migrations: `ActiveRecord::Migration[7.0]` (or 7.1, 7.2).
        V7
      elsif major >= 8
        sections << <<~V8
          ## Rails 8.x Specifics

          - Solid Queue, Solid Cache, Solid Cable as default backends.
          - Kamal 2 for deployment.
          - Propshaft as default asset pipeline.
          - Authentication generator: `rails generate authentication`.
          - `params.expect` for strong parameters (safer than `permit`).
          - Migrations: `ActiveRecord::Migration[8.0]` (or 8.1).
          - Script folder: `script/` for one-off scripts.
        V8
      end
    end

    # General conventions (Rails-specific only; language-agnostic rules are in code-conventions)
    sections << <<~GENERAL
      ## General Conventions

      - Follow existing code style in the project. Look at similar files before creating new ones.
      - Place business logic in models or service objects (`app/services/`), not controllers.
      - Keep controllers thin: one public action method per route, delegate to models/services.
      - Use `before_action` callbacks for authentication/authorization.
      - Prefer scopes on models for reusable queries.
      - Use I18n for user-facing strings when the project already does.
      - Follow RESTful routing patterns. Avoid custom routes when a standard CRUD action works.
    GENERAL

    if stack[:has_devise]
      sections << <<~DEVISE
        ## Authentication (Devise)

        This project uses Devise. Do not reimplement authentication. Use the existing Devise setup:
        `current_user`, `authenticate_user!`, `user_signed_in?`.
      DEVISE
    end

    if stack[:has_pundit]
      sections << <<~PUNDIT
        ## Authorization (Pundit)

        This project uses Pundit. Add policy classes in `app/policies/`. Call `authorize @record`
        in controllers. Use `policy_scope` for index queries.
      PUNDIT
    elsif stack[:has_cancancan]
      sections << <<~CAN
        ## Authorization (CanCanCan)

        This project uses CanCanCan. Define abilities in `app/models/ability.rb`.
        Use `authorize!` or `load_and_authorize_resource` in controllers.
      CAN
    end

    if stack[:has_sidekiq]
      case stack[:sidekiq_mode]
      when 'direct'
        sections << <<~SQ
          ## Background Jobs (Sidekiq direct)

          This project uses Sidekiq directly (not via ActiveJob). Jobs live in `app/workers/`.
          - Include `Sidekiq::Worker` (or `Sidekiq::Job` in Sidekiq 7+).
          - Enqueue with `MyWorker.perform_async(args)` or `perform_in` / `perform_at`.
          - Do NOT use `perform_later` — that is the ActiveJob API and is not used here.
        SQ
      when 'activejob'
        sections << <<~SQ
          ## Background Jobs (ActiveJob + Sidekiq)

          This project uses ActiveJob with Sidekiq as the queue adapter. Jobs live in `app/jobs/`.
          - Inherit from `ApplicationJob` (or `ActiveJob::Base`).
          - Enqueue with `MyJob.perform_later(args)` or `set(wait: 5.minutes).perform_later`.
          - Do NOT use `perform_async` — that is the direct Sidekiq API and is not used here.
        SQ
      when 'both'
        sections << <<~SQ
          ## Background Jobs (Sidekiq + ActiveJob)

          This project uses BOTH patterns. Check existing code to determine which to use:
          - `app/jobs/` — ActiveJob: inherit `ApplicationJob`, enqueue with `perform_later`.
          - `app/workers/` — direct Sidekiq: `include Sidekiq::Worker`, enqueue with `perform_async`.
          Follow the pattern of the module you are modifying. Do not mix patterns in the same class.
          **When creating new jobs, prefer ActiveJob** (`app/jobs/` + `perform_later`) unless
          the surrounding code explicitly uses direct Sidekiq workers.
        SQ
      end
    end

    if stack[:api_only]
      sections << <<~API
        ## API-Only Application

        This is a Rails API-only app. No views or view helpers. Respond with JSON.
        Use serializers or `as_json` / `to_json` following the project's existing pattern.
      API
    end

    if stack[:has_rubocop]
      sections << <<~RC
        ## Code Style (RuboCop)

        This project uses RuboCop. Follow the existing `.rubocop.yml` configuration. NEVER CHANGE THE CONFIGURATION.
        Run `bundle exec rubocop --autocorrect` on files you modify if unsure about style.
      RC
    end

    sections.join("\n")
  end

  def test_patterns_skill(stack)
    framework = stack[:test_framework]
    rails_v = stack[:rails_version]
    major = rails_v ? rails_v.split('.').first.to_i : nil

    sections = []

    sections << <<~HEADER
      ---
      name: test-patterns
      description: Testing conventions and patterns for this project. Loaded automatically when writing or modifying tests.
      ---

      # Test Patterns
    HEADER

    if %w[rspec both].include?(framework)
      sections << <<~RSPEC
        ## RSpec

        - Tests live in `spec/`. Mirror the `app/` directory structure.
        - Use `describe` for the class/method under test, `context` for scenarios, `it` for assertions.
        - Use `let` / `let!` for test data, `before` for shared setup.
        - Prefer `create` / `build` (FactoryBot) or fixtures — follow whichever the project uses.
          - If project uses both, prefer fixtures for global setup and factories for test-specific data.
        - Check `spec/support/` and `spec/rails_helper.rb` for shared helpers and configuration.
        - Use `shared_examples` and `shared_context` when the project already does.

        ### File naming

        | Source | Test |
        |--------|------|
        | `app/models/user.rb` | `spec/models/user_spec.rb` |
        | `app/controllers/users_controller.rb` | `spec/controllers/users_controller_spec.rb` or `spec/requests/users_spec.rb` |
        | `app/services/foo_service.rb` | `spec/services/foo_service_spec.rb` |

        ### Running tests

        ```bash
        bundle exec rspec                     # all
        bundle exec rspec spec/models/        # directory
        bundle exec rspec spec/models/user_spec.rb:42  # single example
        ```
      RSPEC
    end

    if %w[minitest both].include?(framework)
      sections << <<~MINI
        ## Minitest

        - Tests live in `test/`. Mirror the `app/` directory structure.
        - Use `test "description" do ... end` or `def test_method_name` — follow the project's pattern.
        - Use `setup` for shared test data.
        - Check `test/test_helper.rb` for shared configuration and helpers.
        - Use fixtures (`test/fixtures/`) or FactoryBot — follow whichever the project uses.
          - If project uses both, prefer fixtures for global setup and factories for test-specific data.

        ### File naming

        | Source | Test |
        |--------|------|
        | `app/models/user.rb` | `test/models/user_test.rb` |
        | `app/controllers/users_controller.rb` | `test/controllers/users_controller_test.rb` |
        | `app/services/foo_service.rb` | `test/services/foo_service_test.rb` |

        ### Running tests

        ```bash
        bundle exec rails test                  # all
        bundle exec rails test test/models/     # directory
        bundle exec rails test test/models/user_test.rb:42  # single test
        ```
      MINI
    end

    # General testing advice
    sections << <<~GENERAL
      ## General Guidelines

      - **Always look at existing tests first.** Match the style, helpers, and patterns already in use.
      - Test behavior, not implementation. Focus on inputs and expected outputs.
      - Each test should be independent. Don't rely on test execution order.
      - Test edge cases: nil values, empty collections, boundary conditions, authorization failures.
      - For model tests: validations, scopes, associations, and business logic methods.
      - For controller/request tests: HTTP status codes, response body, and side effects.
      - For service tests: the return value and any side effects (DB changes, API calls).
      - **Avoid mocking when possible.**
    GENERAL

    if major && major >= 5
      sections << <<~REQ
        ## Prefer Request Specs / Integration Tests

        For controller testing, prefer request specs (`spec/requests/`) or integration tests
        (`test/integration/`) over controller unit tests. They test the full stack including
        routing, middleware, and serialization.
      REQ
    end

    sections.join("\n")
  end

  def database_patterns_skill(stack)
    dbs = stack[:databases]
    rails_v = stack[:rails_version]
    major = rails_v ? rails_v.split('.').first.to_i : nil

    sections = []

    sections << <<~HEADER
      ---
      name: database-patterns
      description: Database migration and query patterns for this project. Loaded automatically for database-related changes.
      ---

      # Database Patterns
    HEADER

    # Migration version
    if major
      migration_version = if major >= 5 then "[#{major}.0]"
                          else '' # Rails 4 has no version suffix
                          end

      sections << <<~MIG
        ## Migrations

        Migration superclass: `ActiveRecord::Migration#{migration_version}`

        ```ruby
        class AddFieldToTable < ActiveRecord::Migration#{migration_version}
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
    end

    # DB-specific
    if dbs.include?('postgresql')
      sections << <<~PG
        ## PostgreSQL

        - Use `text` instead of `string` for unbounded text (no performance difference in PG).
        - `citext` extension available for case-insensitive text.
        - Use `jsonb` (not `json`) for JSON columns — it's indexable and faster.
        - Array columns: `t.string :tags, array: true, default: []`.
        - Use `uuid` primary keys if the project already does.
        - `ILIKE` for case-insensitive search (or `citext`).
        - `EXPLAIN ANALYZE` to check query plans.
      PG
    end

    if dbs.include?('mysql')
      sections << <<~MY
        ## MySQL

        - `string` columns default to `varchar(255)`. Specify `limit:` when needed.
        - Use `utf8mb4` charset for full Unicode support (check existing schema).
        - No partial index support before MySQL 8.0.13 — use full indices.
        - `LIKE` is case-insensitive by default with utf8 collation.
        - Use `EXPLAIN` to check query plans.
        - Maximum index key length depends on charset and row format.
        - `datetime` precision: use `precision: 6` for microseconds if the project does.
      MY
    end

    # General query patterns
    sections << <<~QUERIES
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

    sections.join("\n")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def read_file(work_dir, relative_path)
    path = File.join(work_dir, relative_path)
    File.exist?(path) ? File.read(path) : nil
  end

  def existing_skills(skills_dir)
    return [] unless Dir.exist?(skills_dir)

    Dir.glob(File.join(skills_dir, '*', 'SKILL.md')).map do |f|
      File.basename(File.dirname(f))
    end
  end

  # Migrate bare .md files in skills_dir to subdirectory/SKILL.md format.
  def migrate_legacy_skills(skills_dir)
    return [] unless Dir.exist?(skills_dir)

    migrated = []
    Dir.glob(File.join(skills_dir, '*.md')).each do |legacy_path|
      skill_name = File.basename(legacy_path, '.md')
      skill_dir = File.join(skills_dir, skill_name)
      new_path = File.join(skill_dir, 'SKILL.md')

      next if File.exist?(new_path) # already migrated

      FileUtils.mkdir_p(skill_dir)
      FileUtils.mv(legacy_path, new_path)
      migrated << skill_name
    end
    migrated
  end

  def write_skill(skills_dir, skill_name, content)
    skill_dir = File.join(skills_dir, skill_name)
    FileUtils.mkdir_p(skill_dir)
    File.write(File.join(skill_dir, 'SKILL.md'), content)
  end
end
