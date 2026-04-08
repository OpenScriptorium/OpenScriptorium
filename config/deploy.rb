# =============================================================================
# Open Scriptorium — Capistrano deploy config (shared across stages)
# =============================================================================

# Lock to the major version of Capistrano installed in the bundle
lock "~> 3.19"

set :application, "openscriptorium"
set :repo_url,    "git@git.sr.ht:~sethkush/openscriptorium"

# Branch to deploy. Override on the command line with:
#   cap production deploy BRANCH=some-feature
set :branch, ENV.fetch("BRANCH", "master")

# Where the app lives on the server. Capistrano creates current/, releases/,
# shared/, and revisions.log under here. Stage 9 of the bootstrap pre-created
# this with seth:www-data ownership and group-readable perms.
set :deploy_to, "/var/www/openscriptorium"

# Keep the last N releases on disk for fast rollback
set :keep_releases, 5

# Use a real PTY for sudo prompts (we won't sudo, but capistrano-puma's
# systemd integration prefers a tty)
set :pty, true

# -----------------------------------------------------------------------------
# Linked files & dirs
# -----------------------------------------------------------------------------
# These live under shared/ on the server and get symlinked into each release.
# Files in linked_files MUST exist on the server before the first deploy or
# the deploy will abort. We'll seed them in the bootstrap section below.
append :linked_files,
  "config/database.yml",
  "config/master.key"

# Linked dirs are persisted across releases (logs, uploads, the bundle, etc.)
append :linked_dirs,
  "log",
  "tmp/pids",
  "tmp/cache",
  "tmp/sockets",
  "public/assets",
  "public/storage",
  "storage",
  ".bundle",
  "vendor/bundle",
  "node_modules"

# -----------------------------------------------------------------------------
# rbenv (capistrano-rbenv)
# -----------------------------------------------------------------------------
# Use the same Ruby that's installed on the server via rbenv.
set :rbenv_type,        :user
set :rbenv_ruby,        "3.4.8"
set :rbenv_prefix,      "RBENV_ROOT=#{fetch(:rbenv_path)} RBENV_VERSION=#{fetch(:rbenv_ruby)} #{fetch(:rbenv_path)}/bin/rbenv exec"
set :rbenv_map_bins,    %w[rake gem bundle ruby rails puma pumactl]
set :rbenv_roles,       :all

# -----------------------------------------------------------------------------
# Bundler (capistrano-bundler)
# -----------------------------------------------------------------------------
set :bundle_path,    -> { shared_path.join("vendor/bundle") }
set :bundle_jobs,    4
# Note: don't pass --deployment as a flag — modern bundler uses
# `bundle config set deployment true`, which capistrano-bundler 2.x
# handles for us automatically in the bundler:config step.
set :bundle_without, %w[development test].join(" ")

# -----------------------------------------------------------------------------
# Puma (capistrano3-puma)
# -----------------------------------------------------------------------------
# Run as a systemd USER service under the seth user (no root needed).
# `loginctl enable-linger seth` must be set on the server so the user
# service stays running across logout — we'll do that as part of bootstrap.
set :puma_systemctl_user,    :user
set :puma_enable_lingering,  false   # we set this manually once during bootstrap
set :puma_service_unit_name, "puma_openscriptorium"

# Wrap ExecStart in `/bin/bash -lc '...'` so the rbenv-style env-var
# prefix (RBENV_ROOT=... rbenv exec ...) gets interpreted by bash.
# Without this, systemd treats the prefix as part of the executable name
# and rejects the unit file with "bad unit file setting".
set :puma_use_login_shell, true

# Bind to a Unix socket inside shared/tmp/sockets/. Apache reverse-proxies
# to this from the openscriptorium.org vhost. Permissions: 0660, owned
# seth:seth — Apache (www-data) needs to traverse the parent dirs (already
# set up via 2755 perms in Stage 9) and read the socket. We add www-data to
# the seth group during bootstrap so this works.
set :puma_bind, "unix://#{shared_path}/tmp/sockets/puma.sock?umask=0117"

# Logs
set :puma_access_log, -> { File.join(shared_path, "log", "puma.access.log") }
set :puma_error_log,  -> { File.join(shared_path, "log", "puma.error.log") }

# -----------------------------------------------------------------------------
# Custom hooks
# -----------------------------------------------------------------------------
namespace :deploy do
  # Restart Puma after a successful publish
  after :publishing, "puma:smart_restart"
end
