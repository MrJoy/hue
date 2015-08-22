# Flux Hue

Dynamic effects system using multiple Philips Hue bridges and Novation Launchpad for control.


## Installation

1. Clone this repo.
2. Run:
    ```bash
    brew install gssdp portmidi
    bundle install
    ```
3. Edit `config.yml`, to match your lighting setup.
4. Register the username in `config.yml` with all your hubs.

__TODO: Document how to register user with hub(s).__


## Usage

* `bin/discover_all.sh`: Discover all Philips Hue bridges on your network.
* `bin/mark_lights_by_hub.rb`: Mark the lights to help ensure they're physically ordered properly.
* `bin/off.rb`: Turn all configured lights off.
* `bin/on.rb`: Turn all configured lights on.
* `bin/flux_hue.rb`: Run the effect system.

## Debugging

* `bin/watch_memory.sh`: External monitor to keep an eye on the process size of `flux_hue.rb`.


## Configuration

__ TODO: Write me.__
