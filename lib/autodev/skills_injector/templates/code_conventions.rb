# frozen_string_literal: true

module SkillsInjector
  module Templates
    # Code conventions skill template (language-agnostic).
    module CodeConventions
      module_function

      def build
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
    end
  end
end
