# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/review_skill_source'

# Autodev #89, review round — the skill subtree read is the one list read in the
# lot that had no pagination (constat 4).
#
# `blobs_under` called `client.tree(..., recursive: true, per_page: 100)` and
# iterated the result. The house convention everywhere else in this repository is
# `per_page: 100` followed by `.auto_paginate` (`gitlab_helpers.rb` does it four
# times), and it is not decoration: GitLab caps `per_page` at 100, and
# `Gitlab::PaginatedResponse#each` walks the *current page* only. So the answer
# was silently truncated at 100 entries.
#
# What a truncation costs here is out of proportion with its likelihood, which is
# why it is worth a test rather than a shrug. `materialise` removes the clone's
# copy of the declared skill **first and unconditionally** — deliberately, so a
# stale copy on the branch under review cannot win — and then writes back only
# what the answer named. A skill whose `SKILL.md` did not make page 1 therefore
# leaves an empty directory, `skill_available?` is false, and the review raises
# `MissingReviewSkillError`: a **terminal** give-up, on a message asserting that a
# file is missing which `locate` had just proved present, one request earlier, on
# that very ref.
#
# Not reachable on today's fleet — powerpanne's `mr-review` is 3 blobs and
# `prepare-mr` 2 — and it is the last route left by which an incomplete read
# produces an abandon, which is the whole subject of this lot.
#
# The cap is the corollary the same constat raises: one `file_contents` per blob,
# with no ceiling on how many blobs or how many bytes. A cap that is never reached
# by a real skill, and that answers the pathological case as a review failure
# (bounded at `REVIEW_FAILURE_THRESHOLD`, and the review genuinely could not run)
# rather than as an outage or as a missing file.
class TheReviewSkillSubtreeIsReadWholeTest < Minitest::Test
  SKILL = 'mr-review'
  DIR = ".claude/skills/#{SKILL}".freeze
  CANONICAL = "#{DIR}/SKILL.md".freeze
  REF = 'master'
  PROJECT_PATH = 'modulosource/powerpanne/powerpanne'

  # Behaves like `Gitlab::PaginatedResponse`: enumerable over the page it holds,
  # `auto_paginate` for everything the query matched. That asymmetry *is* the
  # defect, so the fake has to have it.
  class FakePaginated
    include Enumerable

    PAGE = 100

    def initialize(items) = @items = items
    def each(&) = @items.first(PAGE).each(&)
    def auto_paginate = @items
  end

  class FakeGitlab
    Blob = Struct.new(:type, :path)

    attr_reader :contents_reads

    def initialize(paths)
      @paths = paths
      @contents_reads = []
    end

    def tree(_path, options)
      under = @paths.select { |file| file.start_with?("#{options[:path]}/") }
      FakePaginated.new(under.map { |file| Blob.new('blob', file) })
    end

    def file_contents(_path, file, _ref)
      @contents_reads << file
      "# #{file}"
    end
  end

  def setup
    @work_dir = Dir.mktmpdir('review_skill_subtree_test')
  end

  def teardown = FileUtils.rm_rf(@work_dir)

  def source = { status: ReviewSkillSource::PRESENT, ref: REF, layout: CANONICAL }

  # A skill directory of `count` files whose `SKILL.md` is **not** on the first
  # page — the ordering GitLab's own `tree` produces, since it sorts by path and
  # `SKILL.md` is upper-case-late among lower-case reference files.
  def subtree(count)
    references = (1..count).map { |n| format("#{DIR}/references/r%03d.md", n) }
    references + [CANONICAL]
  end

  def materialise(paths)
    client = FakeGitlab.new(paths)
    ReviewSkillSource.materialise(client, PROJECT_PATH, @work_dir, SKILL, source)
    client
  end

  def written?(repo_path) = File.exist?(File.join(@work_dir, repo_path))

  # --- 1. the whole subtree, not the first page ----------------------------

  def test_a_skill_md_past_the_first_page_is_still_materialised
    materialise(subtree(150))

    assert written?(CANONICAL), 'SKILL.md was on page 2 of the tree and was never written'
  end

  def test_every_blob_of_the_subtree_is_materialised
    client = materialise(subtree(150))

    assert_equal 151, client.contents_reads.size
  end

  # The control: a skill that fits on one page — every real one — is unaffected,
  # and still costs exactly one read per blob.
  def test_a_two_file_skill_still_costs_two_reads
    client = materialise([CANONICAL, "#{DIR}/references/posting.md"])

    assert_equal [CANONICAL, "#{DIR}/references/posting.md"].sort, client.contents_reads.sort
  end

  # --- 2. the corollary: the read is bounded -------------------------------

  # A `review_skill` pointed at a directory that is not a skill would otherwise
  # download it file by file, with no ceiling. It is an `ImplementationError`
  # because that is what "the review could not be run, and it is not GitLab's
  # fault" already means on this path (`overlay_review_skill` normalises local
  # failures to it): bounded by `REVIEW_FAILURE_THRESHOLD`, never terminal on its
  # own, and never a claim that a file is missing.
  def test_a_subtree_beyond_the_cap_is_refused_rather_than_downloaded
    error = assert_raises(ImplementationError) do
      materialise(subtree(ReviewSkillSource::MAX_SKILL_BLOBS + 5))
    end

    assert_includes error.message, SKILL
  end

  def test_a_subtree_beyond_the_cap_downloads_nothing
    client = FakeGitlab.new(subtree(ReviewSkillSource::MAX_SKILL_BLOBS + 5))

    assert_raises(ImplementationError) do
      ReviewSkillSource.materialise(client, PROJECT_PATH, @work_dir, SKILL, source)
    end
    assert_empty client.contents_reads, 'the cap must be applied before the first byte is fetched'
  end

  # The byte ceiling is the other half: a hundred files is not a lot, and a
  # hundred files of a hundred megabytes is.
  def test_a_subtree_beyond_the_byte_cap_stops
    client = FatGitlab.new(subtree(20))

    assert_raises(ImplementationError) do
      ReviewSkillSource.materialise(client, PROJECT_PATH, @work_dir, SKILL, source)
    end
  end

  # Answers blobs of a megabyte each, so the byte ceiling is reached long before
  # the blob one.
  class FatGitlab < FakeGitlab
    def file_contents(path, file, ref)
      super
      'x' * 1_000_000
    end
  end
end
