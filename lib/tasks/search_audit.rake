namespace :search do
  desc "Run search quality audit against test queries in tmp/audit_v6/"
  task audit: :environment do
    require "json"

    audit_dir = Rails.root.join("tmp/audit_v6")
    unless audit_dir.exist?
      puts "No audit directory at #{audit_dir}"
      exit 1
    end

    files = Dir.glob(audit_dir.join("*.json")).sort
    all_queries = []
    files.each do |f|
      queries = JSON.parse(File.read(f))
      queries.each { |q| q["file"] = File.basename(f, ".json") }
      all_queries.concat(queries)
    end

    puts "Loaded #{all_queries.size} test queries from #{files.size} files"
    puts
    $stdout.sync = true

    pass = 0
    fail = 0
    error = 0
    by_category = Hash.new { |h, k| h[k] = { pass: 0, fail: 0, error: 0, total: 0 } }
    by_file = Hash.new { |h, k| h[k] = { pass: 0, fail: 0, error: 0, total: 0 } }
    failures = []

    # Optional: only run a specific category
    filter_category = ENV["CATEGORY"]
    filter_file = ENV["FILE"]
    limit = ENV["LIMIT"]&.to_i

    if filter_category
      all_queries.select! { |q| q["category"] == filter_category }
      puts "Filtered to category '#{filter_category}': #{all_queries.size} queries"
    end
    if filter_file
      all_queries.select! { |q| q["file"] == filter_file }
      puts "Filtered to file '#{filter_file}': #{all_queries.size} queries"
    end
    if limit
      all_queries = all_queries.first(limit)
      puts "Limited to first #{limit} queries"
    end

    total = all_queries.size
    start_time = Time.now

    all_queries.each_with_index do |q, idx|
      query = q["query"]
      check = q["check"]
      expected = q["expected"]
      category = q["category"] || "unknown"
      file = q["file"] || "unknown"

      by_category[category][:total] += 1
      by_file[file][:total] += 1

      begin
        scope = ENV["MODE"] == "keyword" ? { mode: "keyword" } : nil
        result = Search::Executor.new(query, scope: scope).call
        citations = result.results.map { |r| r[:citation] }

        passed = case check
        when "top1"
          citations.first == expected
        when "top3"
          citations.first(3).include?(expected)
        when "top5"
          citations.first(5).include?(expected)
        when "top10"
          citations.first(10).include?(expected)
        when "any"
          # No expected value — just needs to not crash and return something
          true
        when "count_gt"
          result.total_count > (q["threshold"] || 0).to_i
        when "no_crash"
          true
        else
          citations.first(10).include?(expected)
        end

        if passed
          pass += 1
          by_category[category][:pass] += 1
          by_file[file][:pass] += 1
        else
          fail += 1
          by_category[category][:fail] += 1
          by_file[file][:fail] += 1
          failures << {
            query: query,
            expected: expected,
            check: check,
            category: category,
            got_top3: citations.first(3)
          }
        end
      rescue => e
        error += 1
        by_category[category][:error] += 1
        by_file[file][:error] += 1
        failures << {
          query: query,
          expected: expected,
          check: check,
          category: category,
          error: e.message
        }
      end

      # Progress indicator every 10 queries
      if (idx + 1) % 10 == 0
        elapsed = Time.now - start_time
        rate = (idx + 1) / elapsed
        eta = ((total - idx - 1) / rate).round
        pct = ((pass.to_f / (idx + 1)) * 100).round(1)
        print "\r  #{idx + 1}/#{total} (#{pct}% passing, ~#{eta}s remaining)    "
        $stdout.flush
      end
    end

    elapsed = Time.now - start_time
    puts "\r" + " " * 80 + "\r"
    puts "=" * 70
    puts "SEARCH AUDIT RESULTS"
    puts "=" * 70
    puts
    puts "  Total:  #{total}"
    puts "  Pass:   #{pass} (#{(pass.to_f / total * 100).round(1)}%)"
    puts "  Fail:   #{fail}"
    puts "  Error:  #{error}"
    puts "  Time:   #{elapsed.round(1)}s (#{(total / elapsed).round(1)} queries/sec)"
    puts

    puts "By file:"
    by_file.sort_by { |k, _| k }.each do |file, stats|
      pct = (stats[:pass].to_f / stats[:total] * 100).round(1)
      puts "  %-25s %3d/%3d  (%5.1f%%)" % [file, stats[:pass], stats[:total], pct]
    end
    puts

    puts "By category:"
    by_category.sort_by { |_, v| v[:pass].to_f / [v[:total], 1].max }.each do |cat, stats|
      pct = (stats[:pass].to_f / stats[:total] * 100).round(1)
      puts "  %-25s %3d/%3d  (%5.1f%%)" % [cat, stats[:pass], stats[:total], pct]
    end
    puts

    if ENV["VERBOSE"] && failures.any?
      puts "Failures (first 50):"
      failures.first(50).each do |f|
        if f[:error]
          puts "  ERROR: #{f[:query]} — #{f[:error]}"
        else
          puts "  FAIL [#{f[:check]}]: \"#{f[:query]}\""
          puts "    expected: #{f[:expected]}"
          puts "    got top3: #{f[:got_top3].join(', ')}"
        end
      end
    end

    # Write results to tmp for later comparison
    results_file = Rails.root.join("tmp/audit_results_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json")
    File.write(results_file, JSON.pretty_generate({
      timestamp: Time.now.iso8601,
      total: total,
      pass: pass,
      fail: fail,
      error: error,
      pass_rate: (pass.to_f / total * 100).round(2),
      elapsed_seconds: elapsed.round(1),
      by_file: by_file,
      by_category: by_category,
      failures: failures
    }))
    puts "Results written to #{results_file}"
  end
end
