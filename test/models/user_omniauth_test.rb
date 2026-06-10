# frozen_string_literal: true

require_relative '../rails_helper'

class UserOmniauthTest < ActiveSupport::TestCase
  AUTH_HASH = OmniAuth::AuthHash.new(
    provider: 'entra_id',
    uid: 'azure-oid-abc-123',
    info: OmniAuth::AuthHash::InfoHash.new(
      email: 'alice@modulotech.fr',
      name: 'Alice'
    )
  ).freeze

  def test_first_sign_in_creates_one_user
    assert_difference -> { User.count }, +1 do
      User.from_omniauth(AUTH_HASH)
    end
  end

  def test_first_sign_in_populates_microsoft_uid_email_name_from_auth_hash
    user = User.from_omniauth(AUTH_HASH)

    assert_equal 'azure-oid-abc-123', user.microsoft_uid
    assert_equal 'alice@modulotech.fr', user.email
    assert_equal 'Alice',               user.name
  end

  def test_second_sign_in_with_same_uid_does_not_create_duplicate
    existing = User.from_omniauth(AUTH_HASH)

    assert_no_difference -> { User.count } do
      again = User.from_omniauth(AUTH_HASH)

      assert_equal existing.id, again.id
    end
  end

  RENAMED_HASH = OmniAuth::AuthHash.new(
    provider: 'entra_id',
    uid: 'azure-oid-abc-123',
    info: OmniAuth::AuthHash::InfoHash.new(
      email: 'alice.smith@modulotech.fr',
      name: 'Alice Smith'
    )
  ).freeze

  def test_subsequent_sign_in_refreshes_email_if_renamed_in_entra
    User.from_omniauth(AUTH_HASH)
    user = User.from_omniauth(RENAMED_HASH)

    assert_equal 'alice.smith@modulotech.fr', user.email
  end

  def test_subsequent_sign_in_refreshes_name_if_renamed_in_entra
    User.from_omniauth(AUTH_HASH)
    user = User.from_omniauth(RENAMED_HASH)

    assert_equal 'Alice Smith', user.name
  end

  def test_blank_email_in_auth_hash_does_not_overwrite_existing_email
    User.from_omniauth(AUTH_HASH)

    missing_email = OmniAuth::AuthHash.new(
      provider: 'entra_id',
      uid: 'azure-oid-abc-123',
      info: OmniAuth::AuthHash::InfoHash.new(name: 'Alice', email: nil)
    )
    user = User.from_omniauth(missing_email)

    assert_equal 'alice@modulotech.fr', user.email
  end

  # Regression: alpha.7's `autodev:seed_admin` rake creates a User row
  # with email + admin: true but no microsoft_uid. When that same person
  # later signs in via Entra ID, find_or_initialize_by(microsoft_uid:)
  # wouldn't see the existing row and would try to create a duplicate,
  # bombing on the unique-email index. We fall back to a case-
  # insensitive email lookup and attach the uid to the seeded row.
  def test_seeded_user_without_uid_gets_uid_attached_on_first_sso
    User.create!(email: 'alice@modulotech.fr', name: 'Pre-seeded', admin: true)

    assert_no_difference -> { User.count } do
      user = User.from_omniauth(AUTH_HASH)

      assert_equal 'azure-oid-abc-123', user.microsoft_uid
      assert_predicate user, :admin?
    end
  end

  def test_email_match_is_case_insensitive
    User.create!(email: 'Alice@modulotech.fr', name: 'Pre-seeded')

    assert_no_difference -> { User.count } do
      User.from_omniauth(AUTH_HASH) # auth hash has alice@modulotech.fr (lowercase)
    end
  end
end
