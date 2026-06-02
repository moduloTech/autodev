# frozen_string_literal: true

# ActiveRecord mirror of the `issues` table — phase A of the railsification.
#
# bin/autodev (Sinatra+Sequel) is still the writer/transitioner; this AR
# model exists only so that `bin/rails console` and AutoSpec backends
# (phase D) can read the same rows. AASM is intentionally NOT mounted here
# yet — that switch happens in phase B/C when Rails routes start serving
# the dashboard and we need transitions on the AR side. Mounting AASM here
# now would double-register the state machine if a future test ever loads
# both the Sequel `IssueBehavior` and this class in the same process.
class Issue < ApplicationRecord
  self.table_name = 'issues'
end
