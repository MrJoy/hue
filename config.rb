# - name: "Strand1Group1"
#   targets:
#   - [Bridge-01, AccentMain]
#   transition: <%= shared_sweep_transition %>
#   wait:       <%= shared_sweep_wait %>
#   values: *strand1_1_wedding
# - name: "Strand1Group2"
#   targets:
#   - [Bridge-02, AccentMain]
#   transition: <%= shared_sweep_transition %>
#   wait:       <%= shared_sweep_wait %>
#   values: *strand1_2_wedding
# - name: "Strand2Group1"
#   targets:
#   - [Bridge-03, Main]
#   transition: <%= shared_sweep_transition %>
#   wait:       <%= shared_sweep_wait %>
#   values: *strand2_1_wedding
# - name: "Strand2Group2"
#   targets:
#   - [Bridge-04, Main]
#   transition: <%= shared_sweep_transition %>
#   wait:       <%= shared_sweep_wait %>
#   values: *strand2_2_wedding
# - name: "Dance"
#   targets:
#   - [Bridge-01, Dance]
#   - [Bridge-02, Dance]
#   - [Bridge-03, Dance]
#   - [Bridge-04, Dance]
#   transition: 0.1
#   wait:       1.0
#   values: *dance_debug

STRAND_TRANSITION = 0.5
STRAND_WAIT       = 2.0
DANCE_TRANSITION  = 0.1
DANCE_WAIT        = 1.0

BASE_HUE  = 50_000
MIN_HUE   = BASE_HUE - 2_000
MAX_HUE   = BASE_HUE + 2_000
wedding_hues = [BASE_HUE, MIN_HUE, BASE_HUE, MAX_HUE]
WEDDING_HUES = [wedding_hues,
                wedding_hues[1..-1] + wedding_hues[0..0],
                wedding_hues[2..-1] + wedding_hues[0..1],
                wedding_hues[3..-1] + wedding_hues[0..2],
                [MIN_HUE, MAX_HUE]]
DEBUG_HUES = [(0..7).map { Random.rand(65_536) },
              (0..7).map { Random.rand(65_536) },
              (0..7).map { Random.rand(65_536) },
              (0..7).map { Random.rand(65_536) },
              (0..7).map { Random.rand(65_536) }]

hue_set = WEDDING_HUES
STRAND_HUES = { "strand1_group1" => hue_set[0],
                "strand1_group2" => hue_set[1],
                "strand2_group1" => hue_set[2],
                "strand2_group2" => hue_set[3],
                "dance_floor" => hue_set[4] }
sweepers do
  [{ name: "strand1_group1", bridge: "Bridge-01", group: "AccentMain" },
   { name: "strand1_group2", bridge: "Bridge-02", group: "AccentMain" },
   { name: "strand2_group1", bridge: "Bridge-03", group: "Main" },
   { name: "strand2_group2", bridge: "Bridge-04", group: "Main" }]
    .each do |cfg|
    sweeper(cfg[:name], targets:    [[cfg[:bridge], cfg[:group]]],
                        transition: STRAND_TRANSITION,
                        wait:       STRAND_WAIT,
                        hues:       STRAND_HUES[cfg[:name]])
  end
  sweeper("dance_floor", targets: [["Bridge-01", "Dance"],
                                   ["Bridge-02", "Dance"],
                                   ["Bridge-03", "Dance"],
                                   ["Bridge-04", "Dance"]],
                         transition: DANCE_TRANSITION,
                         wait:       DANCE_WAIT,
                         hues:       STRAND_HUES["dance_floor"])
end

screens do
  screen("simulation", "launchpad") do
    # The desaturation controller.
    #
    # Transition time is how quickly to transition the saturation.  I suggest
    # not going too quickly because while the saturation is updated en masse
    # via group update, the brightness is done per-bulb in the main rendering
    # loop -- and you probably don't want to blind everyone during the
    # transition time.
    # Values are [saturation, maximum brightness] -- and nil means "don't
    # clamp brightness"
    SATURATION_POINTS = [[0.2, 0.00],
                         [0.6, 0.30],
                         [0.8, 0.70],
                         [1.0, nil]]
    SATURATION_TRANSITION = 1.0
    # ORBIT_POS = [[0, 4],
    #              [1, 4],
    #              [2, 4],
    #              [3, 4]]
    SATURATION_COLORS = { on:   0x1C103F,
                          off:  0x03030C,
                          down: 0x10103F }
    sat_size = SATURATION_POINTS.length
    [{ position: [4, 4], group: ["Bridge-01", "AccentAndMain"] },
     { position: [5, 4], group: ["Bridge-02", "AccentAndMain"] },
     { position: [6, 4], group: ["Bridge-03", "AccentAndMain"] },
     { position: [7, 4], group: ["Bridge-04", "AccentAndMain"] }]
      .each_with_index do |cfg, idx|
        vertical_slider("sat#{idx}", cfg[:position], sat_size, colors: SATURATION_COLORS,
                                                               default: sat_size - 1) do |val|
          # TODO: Delay the saturation update until the brightness has taken effect.
          ival, bri_max = SATURATION_POINTS[val]
          logger.info { "Saturation[#{idx},#{val}]: #{ival}" }
          NODES["int#{idx}"].clamp_to(bri_max)
          SIM.update_group!(cfg[:group], SATURATION_TRANSITION, "sat" => (255 * ival).round)
        end
      end

    # [Mid-point, delta].  Minimum brightness is `mid-point - delta` and max
    # is `mid-point + delta`.
    INTENSITY_POINTS = [[0.150, 0.075],
                        [0.200, 0.100],
                        [0.400, 0.150],
                        [0.500, 0.175],
                        [0.500, 0.500]]
    INTENSITY_COLORS = { on:   0x22003F,
                         off:  0x05000A,
                         down: 0x27103F }
    int_size = INTENSITY_POINTS.length
    [{ position: [0, 3], group: ["Bridge-01", "AccentAndMain"] },
     { position: [1, 3], group: ["Bridge-02", "AccentAndMain"] },
     { position: [2, 3], group: ["Bridge-03", "AccentAndMain"] },
     { position: [3, 3], group: ["Bridge-04", "AccentAndMain"] }]
      .each_with_index do |cfg, idx|
        vertical_slider("int#{idx}", cfg[:position], int_size, colors: INTENSITY_COLORS,
                                                               default: int_size / 2) do |val|
          mid, spread = INTENSITY_POINTS[val]
          NODES["int#{idx}"].set_range(*mid, spread)
        end
      end

    # NOTE: Values are indexes into main_lights array.
    #
    # Excluding outermost lights because they extend beyond the seating area.
    # This configuration gives two rows, one corresponding to each of the two
    # light strands I'm putting up.
    #
    # TODO: Automatically suss out lights by using padding / widget size settings and spreading
    # TODO: across the simulations.
    SPOTLIGHT_POSITIONS = [[17, 18, 19, 20,   21, 22, 23, 24],
                           [ 3,  4,  5,  6,    7,  8,  9, 10]]
    w = SPOTLIGHT_POSITIONS[0].length
    h = SPOTLIGHT_POSITIONS.length
    radio_group("spotlighting", [0, 0], [w, h], colors:    { on:   0x032727,
                                                             off:  0x000202,
                                                             down: 0x103F3F },
                                                default:   nil,
                                                allow_off: true) do |val|
      val = SPOTLIGHT_POSITIONS.flatten[val] if val
      LOGGER.info { val ? "Spot ##{val}" : "Spot Off" }
      NODES["spotlighting"].spotlight!(val)
    end
  end

  screen("tuning", "launchpad") do
    # TODO: Controls for tuning white lights, accent lights, etc...
  end

  screen("tabset", "launchpad", default: true) do
    tab_set("screen_selector",
            colors: { off:  :dark_gray,
                      down: :white,
                      on:   :light_gray }) do
      tab(:up,    screens["simulation"])
      tab(:down,  screens["tuning"])
      # tab(:left) do
      #   puts "PING!"
      # end
    end

    # Sometimes the process(es) on Hue Bridge that a thread is connected to
    # (or possibly `libcurl` on our end) just seem to get... stuck.  It's
    # very rare but it does happen.  Also, you may find heap growth to be an
    # issue, and swapping might cause you some problems.  This allows a quick
    # (under 0.5s last I measured) restart of the process.  It preserves state
    # to disk as it goes, so it will come back quickly and gracefully with no
    # more than a tiny hiccup in the simulation.
    #
    # Alternatively,  you may just want to do a quick reload after making a
    # configuration change.
    #
    # Position is which of the control buttons to use for this
    # kick-in-the-head function.
    # TODO: Make this optional.
    button("exit", :mixer, colors: { color: :dark_gray,
                                     down:  :white }) { SIM.kick! }
  end
end

screen("tabset").start
