# Register MIME type for SQLite database downloads so Puma/Propshaft
# serves them with Content-Type: application/octet-stream instead of
# text/plain, triggering a browser download instead of rendering as text.
Rack::Mime::MIME_TYPES[".sqlite3"] = "application/octet-stream"
