# Load DSL and set up stages
require "capistrano/setup"

# Include default deployment tasks
require "capistrano/deploy"

# Git SCM
require "capistrano/scm/git"
install_plugin Capistrano::SCM::Git

# Use the rbenv-managed Ruby on the server
require "capistrano/rbenv"

# Bundle install on every release
require "capistrano/bundler"

# Rails: precompile assets, run db:migrate
require "capistrano/rails/assets"
require "capistrano/rails/migrations"

# Puma: systemd user-service install + start/stop/restart
require "capistrano/puma"
install_plugin Capistrano::Puma            # core puma tasks
install_plugin Capistrano::Puma::Systemd   # systemd unit management

# Load custom tasks from `lib/capistrano/tasks` if you have any defined
Dir.glob("lib/capistrano/tasks/*.rake").each { |r| import r }
