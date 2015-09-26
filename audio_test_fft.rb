#!/usr/bin/env ruby
require "rubygems"
require "bundler/setup"
Bundler.setup
require "thread"
require "coreaudio"
require "fftw3"

# For 300Hz..3kHz:
#    512 == bins 4..36 (33)
#   1024 == bins 8..71 (64)
#   2048 == bins 15..140 (126)
#   4096 == bins 29..280 (252)
WINDOW = 1024

Thread.abort_on_exception = true

# def bin_freq(idx, sample_rate); (idx * sample_rate) / WINDOW; end
def freq_bin(hz, sample_rate); ((hz * WINDOW) / sample_rate).round + 1; end

queues = []
input_ths = []
pitch_shift_ths = []
reports = []
inbufs = ARGV.map(&:to_i).map do |device_id|
  device = CoreAudio.devices.find { |dev| dev.devid == device_id }
  fail "No such device ID!" unless device
  inbuf       = device.input_buffer(WINDOW)
  sample_rate = device.actual_rate
  report      = { name: device.name, min: Float::INFINITY, max: 0.0, current: 0.0, count: 0 }
  reports << report

  puts "#{device.name}: Sampling at #{sample_rate}hz..."

  # Only care about frequencies from 300hz to 3khz...
  # Do we need to go around the mid-point a la the pitch-shifting code did?
  #     half = w.shape[1] / 2
  #     f = FFTW3.fft(w, 1)
  #     shift = 12
  #     f.shape[0].times do |ch|
  #       f[ch, (shift+1)...half] = f[ch, 1...(half-shift)]
  #       f[ch, 1..shift] = 0
  #       f[ch, (half+1)...(w.shape[1]-shift)] = f[ch, (half+shift+1)..-1]
  #       f[ch, -shift..-1] = 0

  bin_start = freq_bin(300, sample_rate)
  bin_end   = freq_bin(3_000, sample_rate)
  num_bins  = bin_end - bin_start + 1
  puts "#{device.name}: Getting bins #{bin_start}..#{bin_end} (#{num_bins} bins)."

  # Internal Microphone, Noise Reduction:
  #   No Offset:
  #      512 Samples: Min=1069.6, Max=1331759.8
  #     1024 Samples: Min=1477.9, Max=1874171.2
  #     2048 Samples: Min=1984.8, Max=2620696.1
  #     4096 Samples: Min=2638.2, Max=3489267.6
  #   1 offset:
  #      512 Samples: Min= 986.8, Max=1378807.9
  #     1024 Samples: Min=1552.5, Max=1930567.0
  #     2048 Samples: Min=1329.5, Max=2763622.3
  #     4096 Samples: Min=2697.6, Max=3851381.3

  # TODO: Look into this to allow routing AudioHijack output into processor? http://www.ambrosiasw.com/utilities/wta/
  # http://www.abstractnew.com/2014/04/the-fast-fourier-transform-fft-without.html

  queue = Queue.new
  queues << queue
  pitch_shift_ths << Thread.start do
    loop do
      w = queue.pop
      break unless w
      report[:count] += 1

      # TODO: We get back a 2D matrix.  We're blithely ignoring one dimension.
      # TODO: Is that about stereo channels, or something else?
      f = FFTW3.fft(w, 1)

      # Because of NArray, the `map` eaves magnitude of each `Complex` in the
      # real component of a new Complex. >.<
      amplitudes        = f[0, bin_start..bin_end].map(&:magnitude)
      avg_amplitude     = amplitudes.sum.real / num_bins
      report[:min]      = avg_amplitude if avg_amplitude < report[:min]
      report[:max]      = avg_amplitude if avg_amplitude > report[:max]
      report[:current]  = avg_amplitude
      # puts "#{device.name}: %0.1f, %0.1f, %0.1f" % [min, max, avg_amplitude]
    end
  end

  input_ths << Thread.start do
    loop do
      queue.push(inbuf.read(WINDOW))
    end
  end
  inbuf
end

reporting_thread = Thread.start do
  loop do
    sleep 0.5
    reports.each do |report|
      title = "%s[%05d]:" % [report[:name], report[:count]]
      puts "%30s %10.1f, %10.1f, %10.1f" % [title,
                                            report[:min],
                                            report[:max],
                                            report[:current]]
    end
    puts
  end
end

inbufs.map(&:start)
$stdout.puts "Press enter to terminate..."
$stdout.flush
$stdin.gets
queues.each { |q| q.push(nil) }
inbufs.map(&:stop)
reporting_thread.kill.join
input_ths.map(&:kill).map(&:join)
pitch_shift_ths.map(&:kill).map(&:join)

inbufs.each do |inbuf|
  # TODO: Specify *which* input buffer!
  puts "#{inbuf.dropped_frame} frame dropped at input buffer."
end