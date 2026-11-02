# =============================================================================
# Open Scriptorium — production stage
# =============================================================================
# Single host: sethkush.com (Toronto VPS), running Apache as the front-end
# reverse proxy. The Rails app, Postgres database, and Puma server all live
# on this single box.

set :stage, :production

server "sethkush.com",
  user: "seth",
  roles: %w[app web db],
  ssh_options: {
    keys_only: false,
    auth_methods: %w[publickey]
  }

# Ensure Capistrano uses your local SSH config + agent
set :ssh_options, {
  auth_methods: %w[publickey],
  keys_only: false
}
