# frozen_string_literal: true

module APICompatibilityLayer
  module Template
    TOKEN = /\{\{([^{}]*)\}\}/
    VALUE = /\Avalues\.([a-z][a-z0-9_]*)\z/
    BODY = 'backend.body'

    module_function

    def references(value)
      case value
      when Hash then value.values.flat_map { |child| references(child) }
      when Array then value.flat_map { |child| references(child) }
      when String
        remainder = value.gsub(TOKEN, '')
        raise ConfigError, 'malformed template delimiter' if remainder.include?('{{') || remainder.include?('}}')

        value.scan(TOKEN).flatten
      else []
      end
    end

    def validate(value, names:, backend: false, item: false)
      references(value).each do |reference|
        next if VALUE.match?(reference) && names.include?(VALUE.match(reference)[1])
        next if item && reference.start_with?('item:') && valid_pointer?(reference.delete_prefix('item:'))
        next if backend && reference == 'backend.status'
        next if backend && reference.start_with?("#{BODY}:") && valid_pointer?(reference.delete_prefix("#{BODY}:"))

        raise ConfigError, "unknown template reference: #{reference}"
      end
    end

    def whole_reference(value)
      return unless value.is_a?(String)

      match = TOKEN.match(value)
      match[1] if match && match[0] == value
    end

    def valid_pointer?(pointer)
      pointer.is_a?(String) && (pointer.empty? || pointer.start_with?('/')) && !pointer.match?(/~(?![01])/)
    end

    def pointer(value, path)
      return value if path.empty?

      path.split('/', -1).drop(1).reduce(value) do |current, part|
        key = part.gsub('~1', '/').gsub('~0', '~')
        if current.is_a?(Hash) && current.key?(key)
          current.fetch(key)
        elsif current.is_a?(Array) && key.match?(/\A(?:0|[1-9][0-9]*)\z/) && key.to_i < current.length
          current.fetch(key.to_i)
        else
          raise MappingError, 'JSON pointer does not resolve'
        end
      end
    end

    def render(value, context, path: false)
      case value
      when Hash then value.transform_values { |child| render(child, context) }
      when Array then value.map { |child| render(child, context) }
      when String then render_string(value, context, path: path)
      else value
      end
    end

    def render_string(value, context, path:)
      match = TOKEN.match(value)
      return value unless match
      return resolve(match[1], context) if match[0] == value && !path

      value.gsub(TOKEN) do
        replacement = scalar(resolve(Regexp.last_match(1), context))
        path ? encode_segment(replacement) : replacement
      end
    end

    def scalar(value)
      scalar = [String, Integer, Float, TrueClass, FalseClass].any? { |type| value.is_a?(type) }
      raise MappingError, 'expected a non-null scalar value' unless scalar

      value.to_s
    end

    def encode_segment(value)
      # Encode dots too: a substituted value must never become a dot segment.
      URI.encode_www_form_component(value).gsub('+', '%20').gsub('.', '%2E')
    end

    def resolve(reference, context)
      if reference.start_with?("#{BODY}:")
        pointer(context.fetch('backend.body').call, reference.delete_prefix("#{BODY}:"))
      elsif reference.start_with?('item:')
        pointer(context.fetch('item'), reference.delete_prefix('item:'))
      elsif reference == 'backend.status'
        context.fetch(reference)
      else
        context.fetch('values').fetch(VALUE.match(reference)[1])
      end
    end
  end
end
