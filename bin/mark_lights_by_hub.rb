#!/usr/bin/env ruby
###############################################################################
# Early Initialization/Helpers
###############################################################################
lib = File.expand_path("../../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "flux_hue"
FluxHue.init!
FluxHue.use_hue!

###############################################################################
# Main Logic
###############################################################################
# TODO: Also mark accent lights!
in_groups(CONFIG["main_lights"]).map do |(bridge_name, lights)|
  config    = CONFIG["bridges"][bridge_name]
  requests  = lights
              .map do |(idx, lid)|
                LazyRequestConfig.new(LOGGER, config, hue_light_endpoint(config, lid)) do
                  target      = (254 * ((idx + 1) / lights.length.to_f)).round
                  data        = {}
                  data["on"]  = true
                  data["hue"] = config["debug_hue"]
                  # data["sat"] = ((200 * (idx / lights.length.to_f)) + 54).round
                  data["sat"] = target
                  data["bri"] = target
                  with_transition_time(data, 0)
                end
              end

  Curl::Multi.http(requests, MULTI_OPTIONS) do
  end
end
