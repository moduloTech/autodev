# frozen_string_literal: true

# Structured logger with per-project and global log files.
class AppLogger
  LEVELS = { 'DEBUG' => 0, 'INFO' => 1, 'WARN' => 2, 'ERROR' => 3 }.freeze

  def initialize(pastel:)
    @pastel       = pastel
    @mutex        = Mutex.new
    @log_dir      = nil
    @project_dirs = {}
    @global_file  = nil
    @global_date  = nil
    @level        = LEVELS['INFO']
  end

  def configure(log_dir:, level: 'INFO')
    @log_dir = File.expand_path(log_dir)
    @level   = LEVELS[level.to_s.upcase] || LEVELS['INFO']
    FileUtils.mkdir_p(File.join(@log_dir, 'autodev'))
  end

  def debug(msg, project: nil, **context) = write('DEBUG', msg, project: project, **context)
  def info(msg, project: nil, **context)  = write('INFO',  msg, project: project, **context)
  def warn(msg, project: nil, **context)  = write('WARN',  msg, project: project, **context)
  def error(msg, project: nil, **context) = write('ERROR', msg, project: project, **context)

  def close
    @mutex.synchronize do
      @global_file&.close
      @project_dirs.each_value { |f| f[:file]&.close }
    end
  end

  private

  def write(level, msg, project: nil, **context)
    return if LEVELS[level] < @level

    @mutex.synchronize do
      print_console(level, msg, project)
      write_log_files(level, msg, project, context)
    end
  end

  def print_console(level, msg, project)
    console_msg = msg.include?("\n") ? msg.lines.first.chomp : msg
    prefix = project ? "[#{project}]" : '[autodev]'
    line = format_console_line(level, prefix, console_msg)
    level == 'ERROR' ? Kernel.warn(line) : $stdout.puts(line)
  end

  def format_console_line(level, prefix, msg)
    case level
    when 'ERROR' then @pastel.red("  #{prefix} #{msg}")
    when 'WARN'  then @pastel.yellow("  #{prefix} #{msg}")
    when 'DEBUG' then @pastel.dim("  #{prefix} #{msg}")
    else "  #{@pastel.cyan(prefix)} #{msg}"
    end
  end

  def write_log_files(level, msg, project, context)
    return unless @log_dir

    json_line = build_json_line(level, msg, project, context)
    write_to_global_file(json_line)
    write_to_project_file(project, json_line) if project
  end

  def build_json_line(level, msg, project, context)
    entry = base_entry(level, msg, project, context)
    extra = context.except(:issue_iid, :state, :event)
    entry[:context] = extra unless extra.empty?
    JSON.generate(entry)
  end

  def base_entry(level, msg, project, context)
    {
      timestamp: Time.now.utc.iso8601, level: level, project: project,
      issue_iid: context[:issue_iid], state: context[:state],
      event: context[:event], message: msg
    }
  end

  def write_to_global_file(json_line)
    today = Time.now.strftime('%Y-%m-%d')
    if @global_date != today
      @global_file&.close
      @global_file = open_log_file(File.join(@log_dir, 'autodev'), today)
      @global_date = today
    end
    @global_file.puts(json_line)
  end

  def write_to_project_file(project, json_line)
    slug = project.gsub('/', '_')
    today = Time.now.strftime('%Y-%m-%d')
    entry = @project_dirs[slug] ||= { file: nil, date: nil }
    rotate_project_log(entry, slug, today)
    entry[:file].puts(json_line)
  end

  def rotate_project_log(entry, slug, today)
    return if entry[:date] == today

    entry[:file]&.close
    entry[:file] = open_log_file(File.join(@log_dir, slug), today)
    entry[:date] = today
  end

  def open_log_file(dir, date)
    FileUtils.mkdir_p(dir)
    file = File.open(File.join(dir, "#{date}.jsonl"), 'a') # rubocop:disable Style/FileOpen
    file.sync = true
    file
  end
end
