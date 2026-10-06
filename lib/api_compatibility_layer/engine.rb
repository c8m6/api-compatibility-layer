# frozen_string_literal: true

module APICompatibilityLayer
  class Engine
    Request = Data.define(:http_method, :path, :query, :headers, :body)
    Response = Data.define(:status, :headers, :body)

    def initialize(config, backend: Backend.new)
      @config = config
      @backend = backend
      @routes = config.data.fetch('routes').map { |route| [route, compile(route.fetch('path'))] }
    end

    def call(request)
      route, params = match(request)
      return error(404, 'route_not_found') unless route
      return error(413, 'payload_too_large') if request.body.bytesize > Backend::MAX_BYTES

      json = request.body.empty? ? nil : JSON.parse(request.body)
      context = { 'values' => extract(route, request, params, json) }
      backend = send_request(route, context) if route.key?('backend')
      respond(route.fetch('response', {}), context, backend)
    rescue JSON::ParserError
      error(400, 'invalid_json')
    rescue ArgumentError
      error(400, 'invalid_request')
    rescue MappingError
      error(422, 'request_mapping_failed')
    rescue BackendTimeout
      error(504, 'backend_timeout')
    rescue BackendError
      error(502, 'backend_error')
    end

    def error(status, code)
      Response.new(status: status, headers: { 'Content-Type' => 'application/json' },
                   body: JSON.generate('error' => code))
    end

    private

    def compile(path)
      segments = path.split('/', -1).map do |segment|
        parameter = Config::PARAMETER.match(segment)
        parameter ? "(?<#{parameter[1]}>[^/]+)" : Regexp.escape(segment)
      end
      Regexp.new("\\A#{segments.join('/')}\\z")
    end

    def match(request)
      @routes.each do |route, pattern|
        next unless route['method'] == request.http_method

        match = pattern.match(request.path)
        next unless match

        params = match.named_captures.transform_values { |value| URI::DEFAULT_PARSER.unescape(value) }
        return [route, params]
      end
      nil
    end

    def extract(route, request, params, json)
      query = URI.decode_www_form(request.query, Encoding::UTF_8).to_h
      headers = request.headers.transform_keys(&:downcase)
      route.fetch('extract', {}).transform_values do |rule|
        case rule.fetch('from')
        when 'body' then Template.pointer(json, rule.fetch('pointer'))
        when 'path' then fetch(params, rule.fetch('key'))
        when 'query' then fetch(query, rule.fetch('key'))
        when 'header' then fetch(headers, rule.fetch('key').downcase)
        end
      end
    end

    def fetch(source, key)
      source.fetch(key) { raise MappingError, 'required extraction is missing' }
    end

    def send_request(route, context)
      mapping = route.fetch('backend')
      origin = @config.data.fetch('backends').fetch(mapping.fetch('name')).fetch('base_url')
      @backend.call(origin, mapping, context)
    end

    def respond(mapping, context, backend)
      if backend
        context['backend.status'] = backend.status
        context['backend.body'] = -> { backend.json }
      end
      status = Template.render(mapping.fetch('status', backend ? '{{backend.status}}' : 200), context)
      raise MappingError, 'invalid backend status' unless (200..599).cover?(status)

      body = response_body(mapping, context, backend, status)
      raise MappingError, 'client response too large' if body.bytesize > Backend::MAX_BYTES

      headers = body.empty? ? {} : { 'Content-Type' => 'application/json' }
      Response.new(status: status, headers: headers, body: body)
    rescue MappingError, JSON::GeneratorError
      error(502, 'response_mapping_failed')
    end

    def response_body(mapping, context, backend, status)
      return '' if mapping['empty'] || [204, 205, 304].include?(status)
      return JSON.generate(Template.render(mapping['body'], context)) if mapping.key?('body')
      return JSON.generate(Selection.render(mapping['select'], context)) if mapping.key?('select')
      return '' if backend.body.empty?

      JSON.generate(backend.json)
    end
  end
end
