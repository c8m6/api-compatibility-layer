# frozen_string_literal: true

module APICompatibilityLayer
  class Config
    METHODS = %w[GET POST PUT PATCH DELETE].freeze
    NAME = /\A[a-z][a-z0-9_]*\z/
    HEADER = /\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/
    RESERVED_HEADERS = %w[host content-length transfer-encoding connection keep-alive te trailer upgrade
                          proxy-authorization proxy-authenticate expect].freeze
    DEFAULT_LISTEN = { 'address' => '0.0.0.0', 'port' => 8080 }.freeze
    attr_reader :data

    def self.load(path)
      source = File.read(path)
      document = Psych.parse_stream(source)
      raise ConfigError, 'expected one YAML document' unless document.children.size == 1

      check_yaml(document)
      new(YAML.safe_load(source, permitted_classes: [], permitted_symbols: [], aliases: false))
    rescue Psych::Exception, SystemCallError => e
      raise ConfigError, "cannot load configuration: #{e.message}"
    end

    def self.check_yaml(node)
      if node.is_a?(Psych::Nodes::Mapping)
        keys = node.children.each_slice(2).map(&:first)
        unless keys.all?(Psych::Nodes::Scalar) && keys.map(&:value).uniq.size == keys.size
          raise ConfigError, 'YAML mapping keys must be unique scalars'
        end
      end
      node.children&.each { |child| check_yaml(child) }
    end

    def initialize(data)
      @data = data
      validate
      deep_freeze(data)
    end

    def listen
      DEFAULT_LISTEN.merge(data.fetch('listen', {}))
    end

    private

    def fail_config(message)
      raise ConfigError, message
    end

    def mapping(value, allowed, at)
      fail_config("#{at} must be a mapping") unless value.is_a?(Hash) && value.keys.all?(String)
      unknown = value.keys - allowed
      fail_config("#{at}: unknown keys #{unknown.join(', ')}") unless unknown.empty?
    end

    def validate
      mapping(data, %w[version listen backends routes], 'config')
      fail_config('version must be integer 1') unless data['version'].is_a?(Integer) && data['version'] == 1
      validate_listen
      validate_backends
      routes = data['routes']
      fail_config('routes must be a non-empty array') unless routes.is_a?(Array) && !routes.empty?
      routes.each_with_index do |route, index|
        validate_route(route)
      rescue ConfigError => e
        raise ConfigError, "routes[#{index}]: #{e.message}"
      end
      validate_unique_routes(routes)
    end

    def validate_unique_routes(routes)
      signatures = routes.map { |route| [route['method'], route['path'].gsub(/:[a-z][a-z0-9_]*/, ':param')] }
      fail_config('duplicate method/path pattern') unless signatures.uniq.size == signatures.size
    end

    def validate_listen
      value = data.fetch('listen', {})
      mapping(value, %w[address port], 'listen')
      if value.key?('address') && !nonempty_string?(value['address'])
        fail_config('listen.address must be a non-empty string')
      end
      return unless value.key?('port')
      return if value['port'].is_a?(Integer) && (1..65_535).cover?(value['port'])

      fail_config('listen.port must be an integer between 1 and 65535')
    end

    def validate_backends
      backends = data.fetch('backends', {})
      fail_config('backends must be a mapping') unless backends.is_a?(Hash)
      backends.each do |name, settings|
        fail_config('invalid backend name') unless name.is_a?(String) && NAME.match?(name)
        mapping(settings, %w[base_url], "backends.#{name}")
        url = settings['base_url']
        fail_config('base_url must be a static HTTP(S) origin') unless nonempty_string?(url) && !url.include?('{{')
        validate_origin(url)
      end
    end

    def validate_origin(url)
      uri = URI.parse(url)
      valid = uri.is_a?(URI::HTTP) && uri.host && !uri.userinfo && !uri.query && !uri.fragment &&
              ['', '/'].include?(uri.path) && (1..65_535).cover?(uri.port)
      fail_config('base_url must be an HTTP(S) origin without credentials, query, fragment or path') unless valid
    rescue URI::InvalidURIError
      fail_config('invalid backend base_url')
    end

    def validate_route(route)
      mapping(route, %w[method path extract backend response], 'route')
      validate_method(route['method'])
      parts = validate_route_path(route['path'])
      names = validate_extractions(route.fetch('extract', {}), parts)
      validate_request(route['backend'], names) if route.key?('backend')
      fail_config('route needs backend or response') unless route.key?('backend') || route.key?('response')
      validate_response(route.fetch('response', {}), names, route.key?('backend'))
    end

    def validate_route_path(path)
      fail_config('path must contain literal segments or :name parameters') unless
        path.is_a?(String) && path.match?(%r{\A/(?:[A-Za-z0-9._~-]+|:[a-z][a-z0-9_]*|/)*\z})
      parts = path.split('/').grep(/^:/).map { |part| part.delete_prefix(':') }
      fail_config('path parameters must be unique and occupy a whole segment') unless
        parts.uniq == parts && path.split('/').all? do |part|
          !part.include?(':') || NAME.match?(part.delete_prefix(':'))
        end
      parts
    end

    def validate_extractions(extract, parts)
      fail_config('extract must be a mapping') unless extract.is_a?(Hash)
      extract.each do |name, rule|
        fail_config('invalid extraction name') unless name.is_a?(String) && NAME.match?(name)
        mapping(rule, %w[from key pointer], "extract.#{name}")
        fail_config('from must be query, body, header or path') unless %w[query body header path].include?(rule['from'])
        if rule['from'] == 'body'
          fail_config('body extraction requires only a valid JSON pointer') unless
            rule.keys.sort == %w[from pointer] && Template.valid_pointer?(rule['pointer'])
        else
          validate_key_extraction(rule, parts)
        end
      end
      extract.keys
    end

    def validate_key_extraction(rule, parts)
      fail_config('extraction requires only from and key') unless
        rule.keys.sort == %w[from key] && nonempty_string?(rule['key'])
      fail_config('unknown path parameter') if rule['from'] == 'path' && !parts.include?(rule['key'])
      fail_config('invalid header name') if rule['from'] == 'header' && !HEADER.match?(rule['key'])
    end

    def validate_request(request, names)
      mapping(request, %w[name method path query headers body], 'backend')
      fail_config('unknown backend name') unless data.fetch('backends', {}).key?(request['name'])
      validate_method(request['method'])
      validate_backend_path(request['path'])
      validate_pairs(request.fetch('query', {}), 'query')
      validate_pairs(request.fetch('headers', {}), 'headers')
      Template.validate(request, names: names)
      validate_json(request['body']) if request.key?('body')
    end

    def validate_backend_path(path)
      fail_config('backend.path must be an absolute path, without query or fragment') unless
        nonempty_string?(path) && path.start_with?('/') && !path.start_with?('//') &&
        !path.gsub(Template::TOKEN, 'value').match?(/[\s?#\\]/) && path.ascii_only?
      URI.parse(path.gsub(Template::TOKEN, 'value'))
    rescue URI::InvalidURIError
      fail_config('invalid backend path')
    end

    def validate_pairs(pairs, kind)
      fail_config("#{kind} must be a mapping with static string keys") unless
        pairs.is_a?(Hash) && pairs.keys.all? do |key|
          nonempty_string?(key) && static_key?(key)
        end
      pairs.each do |key, value|
        validate_header(key, value) if kind == 'headers'
        fail_config("#{kind} values must be non-null scalars") unless scalar?(value)
      end
      fail_config('duplicate header names') if kind == 'headers' && pairs.keys.map(&:downcase).uniq.size != pairs.size
    end

    def validate_header(key, value)
      unless HEADER.match?(key) && !RESERVED_HEADERS.include?(key.downcase)
        fail_config("reserved or invalid header: #{key}")
      end
      return unless value.is_a?(String) && value.match?(/[\x00-\x1f\x7f]/)

      fail_config('header values must not contain control characters')
    end

    def validate_response(response, names, backend)
      mapping(response, %w[status body empty], 'response')
      status = response.fetch('status', backend ? '{{backend.status}}' : 200)
      fail_config('response.status must be 200..599 or {{backend.status}}') unless
        (status.is_a?(Integer) && (200..599).cover?(status)) || (backend && status == '{{backend.status}}')
      validate_response_body(response, status, backend)
      validate_json(response['body']) if response.key?('body')
      Template.validate(response, names: names, backend: backend)
    end

    def validate_response_body(response, status, backend)
      fail_config('response.empty must be true') if response.key?('empty') && response['empty'] != true
      fail_config('response.body and empty are mutually exclusive') if response.key?('body') && response.key?('empty')
      unless backend || response.key?('body') || response['empty']
        fail_config('static response needs body or empty: true')
      end
      fail_config('204, 205 and 304 require empty: true') if [204, 205, 304].include?(status) && !response['empty']
    end

    def validate_json(value)
      case value
      when Hash
        fail_config('JSON object keys must be static strings') unless value.keys.all? do |key|
          static_key?(key)
        end
        value.each_value { |child| validate_json(child) }
      when Array then value.each { |child| validate_json(child) }
      else fail_config('body must contain only JSON values') unless value.nil? || scalar?(value)
      end
    end

    def static_key?(key)
      key.is_a?(String) && !key.include?('{{') && !key.include?('}}')
    end

    def scalar?(value)
      value.is_a?(String) || value.is_a?(Integer) || value == true || value == false ||
        (value.is_a?(Float) && value.finite?)
    end

    def nonempty_string?(value)
      value.is_a?(String) && !value.empty?
    end

    def validate_method(value)
      fail_config("method must be one of #{METHODS.join(', ')}") unless METHODS.include?(value)
    end

    def deep_freeze(value)
      case value
      when Hash then value.each do |key, child|
        deep_freeze(key)
        deep_freeze(child)
      end
      when Array then value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end
  end
end
