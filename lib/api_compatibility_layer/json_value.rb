# frozen_string_literal: true

module APICompatibilityLayer
  module JSONValue
    module_function

    def validate(value, literal: false)
      case value
      when Hash
        unless value.keys.all? { |key| key.is_a?(String) && (literal || (!key.include?('{{') && !key.include?('}}'))) }
          raise ConfigError, 'JSON object keys must be static strings'
        end

        value.each_value { |child| validate(child, literal: literal) }
      when Array then value.each { |child| validate(child, literal: literal) }
      else raise ConfigError, 'body must contain only JSON values' unless value.nil? || scalar?(value)
      end
    end

    def scalar?(value)
      value.is_a?(String) || value.is_a?(Integer) || value == true || value == false ||
        (value.is_a?(Float) && value.finite?)
    end
  end
end
