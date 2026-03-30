# frozen_string_literal: true

class AppLogger
  LEVELS = { "DEBUG" => 0, "INFO" => 1, "WARN" => 2, "ERROR" => 3 }.freeze

  def initialize(pastel:)
    @pastel       = pastel
    @mutex        = Mutex.new
    @log_dir      = nil
    @project_dirs = {}
    @global_file  = nil
    @global_date  = nil
    @level        = LEVELS["INFO"]
  end

  def configure(log_dir:, level: "INFO")
    @log_dir = File.expand_path(log_dir)
    @level   = LEVELS[level.to_s.upcase] || LEVELS["INFO"]
    FileUtils.mkdir_p(File.join(@log_dir, "autodev"))
  end

  def debug(msg, project: nil) = write("DEBUG", msg, project: project)
  def info(msg, project: nil)  = write("INFO",  msg, project: project)
  def warn(msg, project: nil)  = write("WARN",  msg, project: project)
  def error(msg, project: nil) = write("ERROR", msg, project: project)

  def close
    @mutex.synchronize do
      @global_file&.close
      @project_dirs.each_value { |f| f[:file]&.close }
    end
  end

  private

  def write(level, msg, project: nil)
    return if LEVELS[level] < @level

    timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
    prefix = project ? "[#{project}]" : "[autodev]"
    line = "#{timestamp} #{level.ljust(5)} #{prefix} #{msg}"

    @mutex.synchronize do
      # Truncate multiline messages on console (full message goes to log files)
      console_msg = msg.include?("\n") ? msg.lines.first.chomp : msg
      console_line = case level
                     when "ERROR" then @pastel.red("  #{prefix} #{console_msg}")
                     when "WARN"  then @pastel.yellow("  #{prefix} #{console_msg}")
                     when "DEBUG" then @pastel.dim("  #{prefix} #{console_msg}")
                     else "  #{@pastel.cyan(prefix)} #{console_msg}"
                     end
      if level == "ERROR"
        $stderr.puts console_line
      else
        $stdout.puts console_line
      end

      write_to_global_file(line) if @log_dir
      write_to_project_file(project, line) if @log_dir && project
    end
  end

  def write_to_global_file(line)
    today = Time.now.strftime("%Y-%m-%d")
    if @global_date != today
      @global_file&.close
      path = File.join(@log_dir, "autodev", "#{today}.log")
      @global_file = File.open(path, "a")
      @global_file.sync = true
      @global_date = today
    end
    @global_file.puts(line)
  end

  def write_to_project_file(project, line)
    slug = project.gsub("/", "_")
    today = Time.now.strftime("%Y-%m-%d")
    entry = @project_dirs[slug] ||= { file: nil, date: nil }

    if entry[:date] != today
      entry[:file]&.close
      dir = File.join(@log_dir, slug)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{today}.log")
      entry[:file] = File.open(path, "a")
      entry[:file].sync = true
      entry[:date] = today
    end
    entry[:file].puts(line)
  end
end
