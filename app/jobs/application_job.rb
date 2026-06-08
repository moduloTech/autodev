# frozen_string_literal: true

# Base class for all ActiveJob jobs. Solid Queue backs the adapter
# (cf. config/application.rb step 5 wiring).
class ApplicationJob < ActiveJob::Base
  # Bubble up the DB-busy retry that SQLite + WAL exposes when several
  # workers commit at the same instant. The Sequel side already wraps every
  # write in busy_timeout, so AR seeing one is rare but possible at the
  # process boundary between Sequel issues and AR queue jobs.
  retry_on ActiveRecord::Deadlocked, wait: :polynomially_longer, attempts: 5

  # If a job's arguments reference a model that has been deleted (e.g. the
  # underlying Sequel `Issue` row was hard-deleted between enqueue and run)
  # we want the job to drop silently rather than retry forever.
  discard_on ActiveJob::DeserializationError
end
