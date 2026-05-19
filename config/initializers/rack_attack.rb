# Rate limiting + crawler control. Mild limits — enough to stop automated
# abuse and misbehaving crawlers without inconveniencing real users.

class Rack::Attack
  # --- Hard blocks for clearly-malformed bot traffic on /search ---------------
  # We've seen crawlers requesting URLs where "section" got split on the
  # letter "s", producing literal "§ion[]=" tokens in the querystring.
  # Real users never generate these; cheap to short-circuit at the edge.
  blocklist("search/malformed-params") do |req|
    next false unless req.path == "/search"
    qs = req.query_string.to_s
    # § byte sequence — appears literal, percent-encoded UTF-8, or
    # percent-encoded Latin-1 in scraper-generated URLs.
    qs.include?("§") || qs.include?("%C2%A7") || qs.include?("%A7")
  end

  # /search is also disallowed by robots.txt; well-behaved crawlers obey it.
  # Misbehaving ones get a tight throttle on top of the general limit.
  throttle("search/ip", limit: 10, period: 60) do |req|
    req.ip if req.path == "/search"
  end

  # --- General-purpose throttles ---------------------------------------------
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

  self.throttled_responder = lambda do |req|
    [429, { "Content-Type" => "text/plain" },
     ["Rate limit exceeded. Please slow down.\n"]]
  end

  self.blocklisted_responder = lambda do |req|
    [400, { "Content-Type" => "text/plain" }, ["Bad request\n"]]
  end
end
