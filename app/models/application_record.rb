# frozen_string_literal: true

# Abstract base class for every model backed by the primary SQLite
# database (`~/.autodev/autodev.db`). Solid Queue's tables live in a
# second database and are routed by `config/database.yml`, so they do
# not inherit from this class.
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
end
