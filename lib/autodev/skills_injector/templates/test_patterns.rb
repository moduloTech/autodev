# frozen_string_literal: true

module SkillsInjector
  module Templates
    # Test patterns skill template.
    module TestPatterns
      HEADER = <<~HEADER
        ---
        name: test-patterns
        description: Testing conventions and patterns for this project. Loaded automatically when writing or modifying tests.
        ---

        # Test Patterns
      HEADER

      RSPEC_SECTION = <<~RSPEC
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

      MINITEST_SECTION = <<~MINI
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

      GENERAL_SECTION = <<~GENERAL
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

      REQUEST_SECTION = <<~REQ
        ## Prefer Request Specs / Integration Tests

        For controller testing, prefer request specs (`spec/requests/`) or integration tests
        (`test/integration/`) over controller unit tests. They test the full stack including
        routing, middleware, and serialization.
      REQ

      module_function

      def build(stack)
        framework = stack[:test_framework]
        major = Templates.rails_major(stack)

        sections = [HEADER]
        sections << RSPEC_SECTION if %w[rspec both].include?(framework)
        sections << MINITEST_SECTION if %w[minitest both].include?(framework)
        sections << GENERAL_SECTION
        sections << REQUEST_SECTION if major && major >= 5
        sections.join("\n")
      end
    end
  end
end
