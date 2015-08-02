#!/usr/bin/env ruby
# https://github.com/taf2/curb/tree/master/bench

# TODO: Play with fibers using the more involved `Curl::Multi` interface that
# TODO: gives us an idle callback.
#   f = Fiber.new do
#     meth(1) do
#       Fiber.yield
#     end
#   end
#   meth(2) do
#     f.resume
#   end
#   f.resume
#   p Thread.current[:name]

###############################################################################
# Early Initialization/Helpers
###############################################################################
require "rubygems"
require "bundler/setup"
Bundler.setup
require "yaml"
require "perlin_noise"
require "curb"
require "oj"

def env_int(name, allow_zero = false)
  return nil unless ENV.key?(name)
  tmp = ENV[name].to_i
  tmp = nil if tmp == 0 && !allow_zero
  tmp
end

def env_float(name)
  return nil unless ENV.key?(name)
  ENV[name].to_f
end

###############################################################################
# Janky Logging
###############################################################################
def prefixed(msg)
  msg = "#{CONFIG}: #{msg}" if msg && msg != ""
  puts msg
end

def error(msg); prefixed(msg); end
def debug(msg); prefixed(msg) if VERBOSE; end
def important(msg); prefixed(msg); end

###############################################################################
# Timing Configuration
#
# Play with this to see how error rates are affected.
###############################################################################

# TODO: Try to figure out how to set Curl::CURLOPT_TCP_NODELAY => true
# TODO: Disable Curl from sending keepalives by trying HTTP/1.0.

MULTI_OPTIONS   = { pipeline:         false,
                    max_connects:     (env_int("MAX_CONNECTS") || 3) }
EASY_OPTIONS    = { timeout:          5,
                    connect_timeout:  5,
                    follow_location:  false,
                    max_redirects:    0 }
ITERATIONS      = env_int("ITERATIONS", true) || 0

SPREAD_SLEEP    = env_float("SPREAD_SLEEP") || 0.0
BETWEEN_SLEEP   = env_float("BETWEEN_SLEEP") || 0.0

VERBOSE         = env_int("VERBOSE")

###############################################################################
# Effect
#
# Tweak this to change the visual effect.
###############################################################################
# TODO: Move all of these into the config...
USE_SWEEP     = (env_int("USE_SWEEP", true) || 1) != 0
TRANSITION    = env_float("TRANSITION") || 0.4 # In seconds, 1/10th sec. prec!
SWEEP_LENGTH  = 2.0

# Ballpark estimation of Jen's palette:
MIN_HUE       = env_int("MIN_HUE", true) || 48_000
MAX_HUE       = env_int("MAX_HUE", true) || 51_000
MIN_SAT       = env_int("MIN_SAT", true) || 212
MAX_SAT       = env_int("MAX_SAT", true) || 254
MIN_BRI       = env_int("MIN_BRI", true) || 63
MAX_BRI       = env_int("MAX_BRI", true) || 191

INIT_HUE      = env_int("INIT_HUE", true) || 49_500
INIT_SAT      = env_int("INIT_SAT", true) || 254
INIT_BRI      = env_int("INIT_BRI", true) || 127

TIMESCALE_H   = env_float("TIMESCALE_H") || 0.2
TIMESCALE_S   = env_float("TIMESCALE_S") || 1.0
TIMESCALE_B   = env_float("TIMESCALE_B") || 2.0

HUE_FUNC      = ENV.key?("HUE_FUNC") ? ENV["HUE_FUNC"] : "none"
SAT_FUNC      = ENV.key?("SAT_FUNC") ? ENV["SAT_FUNC"] : "none"
BRI_FUNC      = ENV.key?("BRI_FUNC") ? ENV["BRI_FUNC"] : "perlin"

# TODO: Build out a variety of noise configurations.  Parameterize them, and
# TODO: allow meta-parameterization as well.
PERSISTENCE   = 1
OCTAVES       = 1
# TODO: Dump [BASIS_TIME, Time.now.to_f] on termination and read on start to
# TODO: allow resuming at correct time offset.
BASIS_TIME    = Time.now.to_f # Large Y values frighten and confuse our
                              # Perlin generator...
# TODO: Do we need to modulate this?  Also, we should dump our seed with the
# TODO: state above as well.
SEED          = BASIS_TIME.to_i % 1000 # Large seeds frighten and confuse our
                                       # Perlin generator...
PERLIN        = Perlin::Noise.new 2
# contrast = Perlin::Curve.contrast(Perlin::Curve::CUBIC, 3)

def perlin(x, s, min, max)
  # Ugly hack because the Perlin lib we're using doesn't like extreme Y values,
  # apparently.  It starts spitting zeroes back at us.
  elapsed = Time.now.to_f - BASIS_TIME
  tmp = (((PERLIN[x, elapsed * s] + 1) * 0.5 * (max - min)) + min).to_i
  tmp
end

def wave(_x, s, min, max)
  elapsed = Time.now.to_f - BASIS_TIME
  (((Math.sin(elapsed * s) + 1) * 0.5 * (max - min)) + min).to_i
end

HUE_GEN = {
  "perlin"  => proc { |idx| perlin(idx, TIMESCALE_H, MIN_HUE, MAX_HUE) },
  "wave"    => proc { |idx| wave(idx, TIMESCALE_H, MIN_HUE, MAX_HUE) },
}

SAT_GEN = {
  "perlin"  => proc { |idx| perlin(idx, TIMESCALE_S, MIN_SAT, MAX_SAT) },
  "wave"    => proc { |idx| wave(idx, TIMESCALE_S, MIN_SAT, MAX_SAT) },
}

BRI_GEN = {
  "perlin"  => proc { |idx| perlin(idx, TIMESCALE_B, MIN_BRI, MAX_BRI) },
  "wave"    => proc { |idx| wave(idx, TIMESCALE_B, MIN_BRI, MAX_BRI) },
}

###############################################################################
# Other Configuration
###############################################################################
SKIP_GC           = !!env_int("SKIP_GC")

###############################################################################
# Bring together defaults and env vars, initialize things, etc...
###############################################################################
CONFIG            = YAML.load(File.read("config.yml"))

###############################################################################
# Helper Functions
###############################################################################
def validate_func_for!(component, value, functions)
  return if functions.key?(value)
  return if value == "none"
  error "Unknown value for #{component.upcase}_FUNC: `#{value}`!"
end

def hue_server(config); "http://#{config['ip']}"; end
def hue_base(config); "#{hue_server(config)}/api/#{config['username']}"; end
def hue_light_endpoint(config, light_id); "#{hue_base(config)}/lights/#{light_id}/state"; end
# TODO: Generalize this to configurable group ID per bridge so we can differentiate
# TODO: accent lighting from normal lighting.
def hue_all_endpoint; "#{hue_base}/groups/0/action"; end

def with_transition_time(data, transition)
  data.merge("transitiontime" => (transition * 10.0).round(0))
end

def make_req_struct(config, light_id, transition, data)
  tmp = { method:   :put,
          url:      hue_light_endpoint(config, light_id),
          put_data: Oj.dump(with_transition_time(data, transition)) }
  tmp.merge(EASY_OPTIONS)
end

# def hue_init(light_id)
#   make_req_struct(light_id, 0,  "on"  => true,
#                                 "bri" => INIT_BRI,
#                                 "sat" => INIT_SAT,
#                                 "hue" => INIT_HUE)
# end

def hue_request(config, index, light_id, transition)
  data = {}
  data["hue"] = HUE_GEN[HUE_FUNC].call(index) if HUE_GEN[HUE_FUNC]
  data["sat"] = SAT_GEN[SAT_FUNC].call(index) if SAT_GEN[SAT_FUNC]
  data["bri"] = BRI_GEN[BRI_FUNC].call(index) if BRI_GEN[BRI_FUNC]

  make_req_struct(config, light_id, transition, data)
end

# rubocop:disable Lint/RescueException
def guard_call(bridge_name, &block)
  block.call
rescue Exception => e
  error("Exception for thread ##{bridge_name}, got:")
  error("\t#{e.message}")
  error("\t#{e.backtrace.join("\n\t")}")
end
# rubocop:enable Lint/RescueException

def in_groups(entities)
  groups = {}
  entities.each do |(bridge_name, light_id)|
    groups[bridge_name] ||= []
    groups[bridge_name] << light_id
  end

  groups
end

###############################################################################
# Main
###############################################################################
validate_func_for!("hue", HUE_FUNC, HUE_GEN)
validate_func_for!("sat", SAT_FUNC, SAT_GEN)
validate_func_for!("bri", BRI_FUNC, BRI_GEN)

if ITERATIONS > 0
  debug "Running for #{ITERATIONS} iterations."
else
  debug "Running until we're killed.  Send SIGHUP to terminate with stats."
end

lights_for_threads  = in_groups(CONFIG["main_lights"])
mutex               = Mutex.new
@hard_timeouts      = 0
@soft_timeouts      = 0
@failures           = 0
@successes          = 0

# TODO: Hoist this into a separate script.
# debug "Initializing lights..."
# init_reqs = LIGHTS.sort.uniq.map { |lid| hue_init(lid) }
# Curl::Multi.http(init_reqs, MULTI_OPTIONS) do |easy|
#   if easy.response_code != 200
#     error "Failed to initialize light (will try again): #{easy.url}"
#     add(easy)
#   end
# end
# sleep(0.5)

Thread.abort_on_exception = false
if USE_SWEEP
  sweep_thread = Thread.new do
    # l_hto   = 0
    # l_sto   = 0
    # l_fail  = 0
    # l_succ  = 0
    hue_target = MAX_HUE

    guard_call(0) do
      loop do
        # l_hto       = 0
        # l_sto       = 0
        # l_fail      = 0
        # l_succ      = 0

        before_time = Time.now.to_f
        # tmp         = HUE_GEN["wave"].call(0)
        hue_target = (hue_target == MAX_HUE) ? MIN_HUE : MAX_HUE
        data        = with_transition_time({ "hue" => hue_target }, SWEEP_LENGTH)
        # http        =
        Curl.put(hue_all_endpoint, Oj.dump(data))
        # TODO: Handle response here, a la main thread...
        # puts "#{http.response_code} / #{http.body_str}"

        # mutex.synchronize do
        #   @hard_timeouts += l_hto
        #   @soft_timeouts += l_sto
        #   @failures      += l_fail
        #   @successes     += l_succ
        # end

        sleep 0.05 while (Time.now.to_f - before_time) <= SWEEP_LENGTH
      end
    end
  end
end

threads = lights_for_threads.map do |(bridge_name, lights)|
  Thread.new do
    indexed_lights = []
    lights.each_with_index do |light_id, index|
      indexed_lights << [index, light_id]
    end

    config  = CONFIG["bridges"][bridge_name]
    l_hto   = 0
    l_sto   = 0
    l_fail  = 0
    l_succ  = 0
    debug("Thread #{bridge_name}, handling #{lights.count} lights.")

    # TODO: Get timing stats, figure out if timeouts are in ms or sec, capture
    # TODO: info about failure causes, etc.
    handlers  = { on_failure: lambda do |easy, _|
                                case easy.response_code
                                when 404
                                  # Hit Bridge hardware limit.
                                  l_fail += 1
                                  printf "*"
                                when 0
                                  # Hit timeout.
                                  l_hto += 1
                                  printf "-"
                                else
                                  error("WAT: #{easy.response_code}")
                                end
                              end,
                  on_success: lambda do |easy|
                                if easy.body =~ /error/
                                  # Hit bridge rate limit / possibly ZigBee
                                  # limit?.
                                  l_sto += 1
                                  printf "~"
                                else
                                  l_succ += 1
                                  printf "." if VERBOSE
                                end
                              end }

    Thread.stop
    sleep SPREAD_SLEEP unless SPREAD_SLEEP == 0
    guard_call(bridge_name) do
      counter = 0
      while (ITERATIONS > 0) ? (counter < ITERATIONS) : true
        l_hto     = 0
        l_sto     = 0
        l_fail    = 0
        l_succ    = 0
        requests  = indexed_lights
                    .map { |(idx, lid)| hue_request(config, idx, lid, TRANSITION) }
                    .map { |req| req.merge(handlers) }

        Curl::Multi.http(requests.dup, MULTI_OPTIONS) do # |easy|
          # Apparently performed for each request?  Or when idle?  Or...

          # dns_cache_timeout head header_size header_str headers
          # http_connect_code last_effective_url last_result low_speed_limit
          # low_speed_time num_connects on_header os_errno redirect_count
          # request_size

          # app_connect_time connect_time name_lookup_time pre_transfer_time
          # start_transfer_time total_time

          # Bytes/sec, I think:
          # download_speed upload_speed

          # The following are all Float, and downloaded_content_length can be
          # -1.0 when a transfer times out(?).
          # downloaded_bytes downloaded_content_length uploaded_bytes
          # uploaded_content_length
        end

        mutex.synchronize do
          @hard_timeouts += l_hto
          @soft_timeouts += l_sto
          @failures      += l_fail
          @successes     += l_succ
        end

        counter += 1
        sleep(BETWEEN_SLEEP) unless BETWEEN_SLEEP == 0
      end
    end
  end
end

sleep 0.01 while threads.find { |thread| thread.status != "sleep" }
if SKIP_GC
  debug("Disabling garbage collection!  BE CAREFUL!")
  GC.disable
end
debug("Threads are ready to go, waking them up!")
@start_time = Time.now.to_f
threads.each(&:wakeup)

def compute_results(start_time, end_time, successes, failures, hard_timeouts, soft_timeouts)
  elapsed   = end_time - start_time
  requests  = successes + failures + hard_timeouts + soft_timeouts
  [elapsed, requests]
end

def ratio(num, denom); (num / denom.to_f).round(3); end

def print_results(elapsed, requests, successes, failures, hard_timeouts, soft_timeouts)
  important("")
  important("* #{requests} requests (#{ratio(requests, elapsed)}/sec)")
  important("* #{successes} successful (#{ratio(successes, elapsed)}/sec)")
  important("* #{failures} failed (#{ratio(failures, elapsed)}/sec)")
  important("* #{hard_timeouts} hard timeouts (#{ratio(hard_timeouts, elapsed)}/sec)")
  important("* #{soft_timeouts} soft timeouts (#{ratio(soft_timeouts, elapsed)}/sec)")
  all_failures = failures + hard_timeouts + soft_timeouts
  important("* #{ratio(all_failures * 100, requests)}% failure rate")
  suffix = " (#{ratio(elapsed, ITERATIONS)}/iteration)" if ITERATIONS > 0
  important("* #{elapsed.round(3)} seconds elapsed#{suffix}")
end

def show_results
  elapsed, requests = compute_results(@start_time,
                                      Time.now.to_f,
                                      @successes,
                                      @failures,
                                      @hard_timeouts,
                                      @soft_timeouts)
  print_results(elapsed, requests, @successes, @failures, @hard_timeouts, @soft_timeouts)
  exit 0
end

trap("HUP") { show_results }

threads.each(&:join)
sweep_thread.terminate if USE_SWEEP
show_results
