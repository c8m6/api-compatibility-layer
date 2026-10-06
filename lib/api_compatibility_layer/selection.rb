# frozen_string_literal: true

module APICompatibilityLayer
  module Selection
    module_function

    def validate(selection, names:, backend:)
      unless selection.is_a?(Hash) && selection.keys.all?(String) && selection.keys.sort == %w[from project where]
        raise ConfigError, 'response.select requires exactly from, where and project'
      end

      validate_source(selection['from'], names: names, backend: backend)
      validate_where(selection['where'], names: names)
      JSONValue.validate(selection['project'])
      Template.validate(selection['project'], names: names, backend: backend, item: true)
    end

    def validate_source(source, names:, backend:)
      return JSONValue.validate(source, literal: true) if source.is_a?(Array)

      reference = Template.whole_reference(source)
      unless backend && reference&.start_with?('backend.body:')
        raise ConfigError, 'select.from must be a literal JSON array or a whole backend.body reference'
      end

      Template.validate(source, names: names, backend: backend)
    end

    def validate_where(conditions, names:)
      unless conditions.is_a?(Hash) && !conditions.empty? && conditions.keys.all? { |key| Template.valid_pointer?(key) }
        raise ConfigError, 'select.where must be a non-empty mapping of JSON pointers'
      end

      conditions.each_value do |value|
        raise ConfigError, 'select.where values must be JSON scalars or whole values references' unless
          value.nil? || JSONValue.scalar?(value)
        next unless value.is_a?(String)
        next if Template.references(value).empty?

        reference = Template.whole_reference(value)
        unless reference && Template::VALUE.match?(reference)
          raise ConfigError, 'select.where templates must be whole values references'
        end

        Template.validate(value, names: names)
      end
    end

    def render(selection, context)
      source = selection.fetch('from')
      source = Template.render(source, context) unless source.is_a?(Array)
      raise MappingError, 'select.from did not resolve to an array' unless source.is_a?(Array)

      conditions = selection.fetch('where').transform_values { |value| Template.render(value, context) }
      source.each do |item|
        next unless matches?(item, conditions)

        return [Template.render(selection.fetch('project'), context.merge('item' => item))]
      end
      []
    end

    def matches?(item, conditions)
      conditions.all? { |pointer, expected| Template.pointer(item, pointer) == expected }
    rescue MappingError
      # Only missing filter pointers mean no match. Projection errors must propagate.
      false
    end
  end
end
