# =============================================================================
# Open Scriptorium — Capistrano deploy config (shared across stages)
# =============================================================================

# Lock to the major version of Capistrano installed in the bundle
lock "~> 3.19"

set :application, "openscriptorium"
set :repo_url,    "git@github-openscriptorium:OpenScriptorium/OpenScriptorium.git"

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
  "public/downloads",
  "public/storage",
  "storage",
  ".bundle",
  "vendor/bundle",
  "vendor/models",  # ONNX models for embedding inference (~1.1 GB Qwen3-Embedding fp16)
  "node_modules"

# -----------------------------------------------------------------------------
# rbenv (capistrano-rbenv)
# -----------------------------------------------------------------------------
# System-wide Ruby, root-owned, outside any home directory:
#   rbenv + ruby-build from Ubuntu packages (/usr/bin/rbenv), rubies in /usr/local/rbenv/versions.
#   Rubies newer than Ubuntu's ruby-build definitions: add a checksum-verified definition to
#   /usr/local/share/ruby-build-definitions/ and build as root with RBENV_ROOT=/usr/local/rbenv
#   (see /root/build-ruby-<version>.sh on the server). Keep in sync with .ruby-version and the
#   ExecStart path in /etc/systemd/system/puma_openscriptorium.service.
set :rbenv_type,        :system
set :rbenv_custom_path, "/usr/local/rbenv"
set :rbenv_ruby,        "3.4.9"
set :rbenv_prefix,      "RBENV_ROOT=#{fetch(:rbenv_custom_path)} RBENV_VERSION=#{fetch(:rbenv_ruby)} /usr/bin/rbenv exec"
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
# Puma runs as a SYSTEM service under the unprivileged 'openscriptorium' user
# (no shell, no sudo, sandboxed), not as the deploy user. Capistrano restarts it
# with `sudo systemctl`. The unit is hand-maintained on the server at
# /etc/systemd/system/puma_openscriptorium.service. Do NOT run `cap puma:install`:
# it would overwrite that unit with the gem's template (as the deploy user, unsandboxed).
set :puma_systemctl_user,    :system
set :puma_service_unit_name, "puma_openscriptorium"

# Wrap ExecStart in `/bin/bash -lc '...'` so the rbenv-style env-var
# prefix (RBENV_ROOT=... rbenv exec ...) gets interpreted by bash.
# Without this, systemd treats the prefix as part of the executable name
# and rejects the unit file with "bad unit file setting".
set :puma_use_login_shell, true

# Inject these as Environment= directives in the systemd unit.
# RAILS_ENV must be set in the shell environment (not just via `puma -e
# production`) so that config/puma.rb's branching on ENV["RAILS_ENV"]
# evaluates to production and binds to the Unix socket instead of TCP 3000.
set :puma_service_unit_env_vars, [
  "RAILS_ENV=production",
  "RACK_ENV=production"
]

# Bind to a Unix socket inside shared/tmp/sockets/. Apache and Anubis (both www-data)
# reverse-proxy to it. shared/tmp/sockets is openscriptorium:www-data 2750 (setgid), so the
# socket is created group www-data, mode 0660 via umask=0117.
set :puma_bind, "unix://#{shared_path}/tmp/sockets/puma.sock?umask=0117"

# Logs
set :puma_access_log, -> { File.join(shared_path, "log", "puma.access.log") }
set :puma_error_log,  -> { File.join(shared_path, "log", "puma.error.log") }

# Note: capistrano3-puma's systemd plugin already restarts puma after
# deploy:published, so there's no extra restart hook here (it used to restart twice).
