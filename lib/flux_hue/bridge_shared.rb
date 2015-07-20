module FluxHue
  # Functionality common to all bridge interfaces.
  module BridgeShared
    include TranslateKeys

    def unpack(hash)
      unpack_hash(hash, self.class::KEYS_MAP)
      @id = @mac_address.gsub(/:/, "") if !@id && @mac_address
    end

    def fetch_configuration; agent.get("#{url}/config"); end

    def handle_error!(error)
      fail FluxHue.get_error(error) if error
    end
  end
end
