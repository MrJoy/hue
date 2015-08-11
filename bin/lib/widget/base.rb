module Widget
  class Base
    # TODO: Way of enforcing color limits...
    BLACK = { r: 0,    g: 0,    b: 0    }.freeze
    WHITE = { r: 0x3F, g: 0x3F, b: 0x3F }.freeze

    attr_reader :value, :x, :y, :width, :height
    attr_accessor :on, :off, :down

    # TODO: Use `Vector2` for position/size...
    def initialize(launchpad:, x:, y:, width:, height:, on:, off:, down:, value:)
      @x          = x
      @y          = y
      @width      = width
      @height     = height
      @on         = BLACK.merge(on)
      @off        = BLACK.merge(off)
      @down       = BLACK.merge(down)
      @launchpad  = launchpad
      @value      = value
    end

    def update(value, render_now = true)
      @value = value
      @value = max_v if max_v && @value && @value > max_v
      render if render_now
    end

  protected

    # Has a built-in assumption that there's one value per button.  Feel free to override this.
    def max_v; @max_v ||= (height * width) - 1; end

    def change_grid(x:, y:, color:)
      xx = x + @x
      yy = y + @y
      return if (xx > max_x) || (xx < 0)
      return if (yy > max_y) || (yy < 0)
      launchpad.device.change_grid(xx, yy, color[:r], color[:g], color[:b])
    end

    attr_reader :launchpad

    def max_y; @max_y ||= (y + height) - 1; end
    def max_x; @max_x ||= (x + width) - 1; end
  end
end
