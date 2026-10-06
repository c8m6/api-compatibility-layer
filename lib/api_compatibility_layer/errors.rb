# frozen_string_literal: true

module APICompatibilityLayer
  class ConfigError < StandardError; end
  class MappingError < StandardError; end
  class BackendError < StandardError; end
  class BackendTimeout < StandardError; end
  class PayloadTooLarge < StandardError; end
end
