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
require "curb"
require "oj"

def env_int(name)
  tmp = ENV[name].to_i
  (tmp == 0) ? nil : tmp
end

def env_float(name)
  tmp = ENV[name].to_f
  (tmp == 0.0) ? nil : tmp
end

###############################################################################
# Timing Configuration
#
# Play with this to see how error rates are affected.
###############################################################################

MULTI_OPTIONS   = { pipeline:         true,
                    max_connects:     (env_int("MAX_CONNECTS") || 6) }
EASY_OPTIONS    = { timeout:          5,
                    connect_timeout:  5,
                    follow_location:  false,
                    max_redirects:    0 }
THREAD_COUNT    = env_int("THREADS") || 1

env_iters       = ENV["ITERATIONS"].to_i
env_iters       = nil if env_iters == 0
ITERATIONS      = env_iters || 20

SPREAD_SLEEP    = 0 # 0.007
TOTAL_SLEEP     = 0 # 0.1
FIXED_SLEEP     = 0 # 0.03
VARIABLE_SLEEP  = TOTAL_SLEEP - FIXED_SLEEP

VERBOSE         = env_int("VERBOSE")

###############################################################################
# Effect
#
# Tweak this to change the visual effect.
###############################################################################
TRANSITION = env_float("TRANSITION") || 0.0 # In seconds, 1/10th second prec.!
def random_hue(light_id)
  ::HUE_ACCRUAL         ||= []
  # TODO: Make step size / granularity and offset configurable!
  tmp                     = (HUE_ACCRUAL[light_id] ||= 0)
  tmp                    += ((rand(16) * 128) + 256)
  tmp                    -= 65_535 if tmp >= 65_535
  HUE_ACCRUAL[light_id]   = tmp
end

HUE_POSITIONS = env_int("HUE_POSITIONS") || 16
BRI_POSITIONS = env_int("HUE_POSITIONS") || 8
def random_hue(_light_id); rand(HUE_POSITIONS) * (65536/HUE_POSITIONS); end
def random_bri(_light_id); rand(BRI_POSITIONS) * (256/BRI_POSITIONS); end

# def random_hue(_light_id)
#   @hue_accrual ||= 0
#   tmp           = (@hue_accrual ||= 0)
#   tmp          += ((rand(16) * 32) + 128)
#   tmp          -= 65_535 if tmp >= 65_535
#   @hue_accrual  = tmp
# end

###############################################################################
# System Configuration
#
# Set these according to the lights you have.
###############################################################################
DEFAULT_USERNAME  = "1234567890" # Default for lib.
DEFAULT_LIGHTS    = %w(1 2 3 4 5 6 7 8 9 10)

###############################################################################
# Other Configuration
###############################################################################
SKIP_GC = !!env_int("SKIP_GC")

###############################################################################
# Bring together defaults and env vars, initialize things, etc...
###############################################################################
BRIDGE_IP         = ENV["HUE_BRIDGE_IP"]
USERNAME          = ENV["HUE_BRIDGE_USERNAME"] || DEFAULT_USERNAME
# env_lights        = (ENV["LIGHTS"] || "").split(/[\s,]+/)
# env_lights        = nil if env_lights.length == 0
# LIGHTS            = (env_lights || DEFAULT_LIGHTS).map(&:to_i)

COLOR_LIGHTS      = %w(15 18 19 27).map(&:to_i)
DIMMABLE_LIGHTS   = %w(32).map(&:to_i)
LIGHTS            = COLOR_LIGHTS + DIMMABLE_LIGHTS
IS_COLOR          = Hash[COLOR_LIGHTS.map { |n| [n.to_i, true] }]

###############################################################################
# Helper Functions
###############################################################################
def validate_counts!(lights, threads)
  return if threads <= lights

  fail "Must have at least one light for every thread you want!"
end

def validate_max_sockets!(max_connects, threads)
  total_conns = max_connects * threads
  return if total_conns <= 6
  fail "No more than 6 connections are allowed by the hub at once!  You asked"\
    " for #{total_conns}!"
end

def hue_server; "http://#{BRIDGE_IP}"; end
def hue_base; "#{hue_server}/api/#{USERNAME}"; end
def hue_endpoint(light_id); "#{hue_base}/lights/#{light_id}/state"; end

def hue_request(light_id, hue, transition)
  if IS_COLOR.key?(light_id)
    data  = { "hue"            => random_hue(light_id) }
  else
    data  = { "bri"            => random_bri(light_id) }
  end
  data    = data.merge("transitiontime" => (transition * 10.0).round(0))
  req     = { method:           :put,
              url:              hue_endpoint(light_id),
              put_data:         Oj.dump(data) }
  req.merge(EASY_OPTIONS)
end

# rubocop:disable Lint/RescueException
def guard_call(thread_idx, &block)
  block.call
rescue Exception => e
  puts "Exception for thread ##{thread_idx}, got:"
  puts "\t#{e.message}"
  puts "\t#{e.backtrace.join("\n\t")}"
end
# rubocop:enable Lint/RescueException

def in_groups(entities, num_groups)
  groups = (1..num_groups).map { [] }
  idx                = 0
  entities.each do |entity|
    groups[idx] << entity
    idx  += 1
    idx   = 0 if idx >= num_groups
  end

  groups
end

###############################################################################
# Main
###############################################################################
validate_max_sockets!(MULTI_OPTIONS[:max_connects], THREAD_COUNT)
validate_counts!(LIGHTS.length, THREAD_COUNT)

puts "Mucking with #{LIGHTS.length} lights, across #{THREAD_COUNT} threads for"\
  " #{ITERATIONS} iterations (requests == #{LIGHTS.length * ITERATIONS})."

lights_for_threads  = in_groups(LIGHTS, THREAD_COUNT)
mutex               = Mutex.new
failures            = 0
successes           = 0

Thread.abort_on_exception = false
threads   = (0..(THREAD_COUNT - 1)).map do |thread_idx|
  sleep SPREAD_SLEEP unless SPREAD_SLEEP == 0
  Thread.new do
    l_fail = 0
    l_succ = 0
    lights = lights_for_threads[thread_idx]
    puts "Thread ##{thread_idx}, handling #{lights.count} lights."

    # TODO: Get timing stats, figure out if timeouts are in ms or sec, capture
    # TODO: info about failure causes, etc.
    # rubocop:disable Style/Semicolon
    handlers  = { on_failure: ->(*_) { l_fail += 1; printf "*" },
                  on_success: ->(*_) { l_succ += 1; printf "." if VERBOSE } }
    # rubocop:enable Style/Semicolon

    Thread.stop
    guard_call(thread_idx) do
      counter = 0
      while counter < ITERATIONS
        l_fail    = 0
        l_succ    = 0
        requests  = lights
                    .map { |lid| hue_request(lid, random_hue(lid), TRANSITION) }
                    .map { |req| req.merge(handlers) }

        Curl::Multi.http(requests.dup, MULTI_OPTIONS) do
          # Apparently performed for each request!
        end

        mutex.synchronize do
          failures  += l_fail
          successes += l_succ
        end

        counter += 1
        sleep(FIXED_SLEEP + rand(VARIABLE_SLEEP)) unless TOTAL_SLEEP == 0
      end
    end
  end
end

sleep 0.01 while threads.find { |thread| thread.status != "sleep" }
if SKIP_GC
  puts "Disabling garbage collection!  BE CAREFUL!"
  GC.disable
end
puts "Threads are ready to go, waking them up!"
threads.each(&:wakeup).each(&:join)

requests  = successes + failures

puts
puts "Done."
puts "* #{requests} requests"
puts "* #{successes} successful"
puts "* #{failures} failed"
puts "* #{'%0.2f' % ((failures / requests.to_f) * 100)}% failure rate"
