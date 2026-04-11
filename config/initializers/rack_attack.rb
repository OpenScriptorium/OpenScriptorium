# Rate limiting to stay within bandwidth limits.
# Mild limits — enough to stop automated abuse without
# inconveniencing real users or researchers.

class Rack::Attack
  # API: 60 requests per minute per IP
  throttle("api/ip", limit: 60, period: 60) do |req|
    req.ip if req.path.start_with?("/api/")
  end

  # Bulk downloads: 5 per hour per IP (these are large files)
  throttle("downloads/ip", limit: 5, period: 3600) do |req|
    req.ip if req.path.start_with?("/downloads/") && req.path =~ /\.(sqlite3|csv)$/
  end

  # General pages: 120 requests per minute per IP
  throttle("general/ip", limit: 120, period: 60) do |req|
    req.ip unless req.path.start_with?("/assets/")
  end

  # Custom response
  self.throttled_responder = lambda do |req|
    [429, { "Content-Type" => "text/plain" },
     ["Rate limit exceeded. Please slow down.\n"]]
  end
end
