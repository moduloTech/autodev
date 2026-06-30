# frozen_string_literal: true

require_relative '../../../autodev_test_helper'

# The sidebar surfaces the three "needs-a-human" tabs as quick links in the
# Autodev section: Erreurs (red), Question en attente + Livrée (à vérifier)
# (yellow), each with its own count badge and the right /issues?tab= href. Also
# covers the labelled sections (Autodev / AutoSpec / Configuration / Admin) and
# the admin-only gating of the Admin section.
class SidebarWatchItemsTest < ActiveSupport::TestCase
  def render_sidebar(active: 'dashboard', counts: {}, admin: false)
    Web::Views::Components::Sidebar.new(
      active: active, locale: :fr, request_path: '/',
      counts: counts, admin: admin,
      translator: ->(key, **vars) { Locales.t(key, locale: :fr, **vars) }
    ).call
  end

  def test_renders_waiting_and_delivered_review_links
    html = render_sidebar

    assert_includes html, '/issues?tab=waiting'
    assert_includes html, '/issues?tab=delivered_review'
  end

  def test_renders_waiting_and_delivered_review_labels
    html = render_sidebar

    assert_includes html, 'Question en attente'
    assert_includes html, 'Livrée (à vérifier)'
  end

  def test_renders_their_count_badges
    html = render_sidebar(counts: { waiting: 6, delivered_review: 4 })

    assert_includes html, '>6<'
    assert_includes html, '>4<'
  end

  def test_highlights_active_delivered_review_item
    html = render_sidebar(active: 'delivered_review')

    # Active items get the accent background on their <a>.
    assert_includes html, 'var(--accent-bg)'
  end

  def test_renders_section_labels
    html = render_sidebar

    assert_includes html, 'Autodev'
    assert_includes html, 'AutoSpec'
    assert_includes html, 'Configuration'
  end

  def test_admin_section_hidden_for_non_admin
    html = render_sidebar(admin: false)

    refute_includes html, '/admin/users'
    refute_includes html, '>Admin<'
  end

  def test_admin_section_shown_for_admin
    html = render_sidebar(admin: true)

    assert_includes html, '/admin/users'
    assert_includes html, '>Admin<'
  end
end
