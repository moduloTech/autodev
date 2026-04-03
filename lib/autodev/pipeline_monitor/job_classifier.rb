# frozen_string_literal: true

class PipelineMonitor
  # Pre-triage and job categorization logic.
  module JobClassifier
    private

    def pre_triage(failed_jobs)
      reasons = extract_job_reasons(failed_jobs)
      classify_failures(reasons)
    end

    def extract_job_reasons(failed_jobs)
      failed_jobs.map { |job| extract_single_reason(job) }
    end

    def extract_single_reason(job)
      if job.is_a?(Hash)
        { reason: job['failure_reason'], name: job['name'].to_s, stage: job['stage'].to_s }
      else
        { reason: job.failure_reason, name: job.name.to_s, stage: job.stage.to_s }
      end
    end

    def classify_failures(reasons)
      counts = count_by_type(reasons)
      return infra_verdict(counts[:infra]) if counts[:infra].size == reasons.size
      return deploy_verdict(counts[:deploy]) if all_code_deploy?(counts, reasons)
      return code_verdict if counts[:code].size == reasons.size

      { verdict: :uncertain, explanation: 'Raisons mixtes ou inconnues' }
    end

    def count_by_type(reasons)
      {
        infra: reasons.select { |r| INFRA_FAILURE_REASONS.include?(r[:reason]) },
        code: reasons.select { |r| CODE_FAILURE_REASONS.include?(r[:reason]) },
        deploy: reasons.select { |r| deploy_job?(r) }
      }
    end

    def all_code_deploy?(counts, reasons)
      counts[:code].size == reasons.size && counts[:deploy].size == reasons.size
    end

    def deploy_job?(reason)
      reason[:name].match?(DEPLOY_JOB_PATTERN) || reason[:stage].match?(DEPLOY_JOB_PATTERN)
    end

    def infra_verdict(infra_jobs)
      names = infra_jobs.map { |r| "#{r[:name]} (#{r[:reason]})" }.join(', ')
      { verdict: :infra, explanation: "Tous les jobs en echec ont une raison d'infrastructure: #{names}" }
    end

    def deploy_verdict(deploy_jobs)
      names = deploy_jobs.map { |r| r[:name] }.join(', ')
      { verdict: :infra, explanation: "Tous les jobs en echec sont des jobs de deploiement: #{names}" }
    end

    def code_verdict
      { verdict: :code, explanation: 'Tous les jobs en echec ont script_failure comme raison' }
    end

    def categorize_jobs!(job_entries, log_dir)
      job_entries.each { |entry| entry[:category] = categorize_job(entry, log_dir) }
    end

    def categorize_job(entry, log_dir)
      CATEGORY_PATTERNS.each do |category, patterns|
        return category if entry[:name].to_s.match?(patterns[:names]) || entry[:stage].to_s.match?(patterns[:stages])
      end
      categorize_by_log(log_dir, entry) || :unknown
    end

    def categorize_by_log(log_dir, entry)
      log_path = File.join(log_dir, File.basename(entry[:log_path]))
      return nil unless File.exist?(log_path)

      log_head = File.foreach(log_path).first(200)&.join
      return nil unless log_head

      CATEGORY_PATTERNS.each do |category, patterns|
        return category if log_head.match?(patterns[:logs])
      end
      nil
    end
  end
end
