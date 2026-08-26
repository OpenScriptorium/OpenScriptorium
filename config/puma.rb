# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.

# Threads / workers ----------------------------------------------------------
# 5 threads on a single Puma process. The ONNX embedding model is shared
# across threads (loaded once at boot), so extra threads cost only Ruby
# stack + GC overhead. Ruby releases the GVL during DB waits and inside
# the ONNX C extension, so semantic-search requests actually run in
# parallel. Raising further needs an RSS check on the 4GB VPS.
threads_count = ENV.fetch("RAILS_MAX_THREADS", 5).to_i
threads threads_count, threads_count

workers ENV.fetch("WEB_CONCURRENCY", 0).to_i

# Bind ----------------------------------------------------------------------
# In development, listen on a TCP port. In production, Capistrano sets
# BIND_TO to a unix:// socket inside shared/tmp/sockets/ which Apache
# reverse-proxies to.
if ENV["RAILS_ENV"] == "production"
  bind ENV.fetch("BIND_TO") {
    "unix:///var/www/openscriptorium/shared/tmp/sockets/puma.sock?umask=0117"
  }
else
  port ENV.fetch("PORT", 3000)
end

# Environment ---------------------------------------------------------------
environment ENV.fetch("RAILS_ENV", "development")

# Pidfile / state -----------------------------------------------------------
# Capistrano-puma writes these into shared/tmp/pids/ so they survive
# across releases.
if ENV["RAILS_ENV"] == "production"
  app_dir   = "/var/www/openscriptorium"
  pidfile   "#{app_dir}/shared/tmp/pids/puma.pid"
  state_path "#{app_dir}/shared/tmp/pids/puma.state"
  stdout_redirect "#{app_dir}/shared/log/puma.access.log",
                  "#{app_dir}/shared/log/puma.error.log",
                  true
else
  pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
end

# Restart support -----------------------------------------------------------
plugin :tmp_restart

# Run the Solid Queue supervisor inside of Puma for single-server deployments.
plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]
