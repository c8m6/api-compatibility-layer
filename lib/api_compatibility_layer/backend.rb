# frozen_string_literal: true

require 'timeout'

module APICompatibilityLayer
  class Backend
    MAX_BYTES = 1_048_576
    TIMEOUT = 10
    Result = Data.define(:status, :body) do
      def json
        JSON.parse(body)
      rescue JSON::ParserError
        raise MappingError, 'backend returned invalid JSON'
      end
    end

    def call(origin, mapping, context)
      uri = build_uri(origin, mapping, context)
      headers = build_headers(mapping, context)
      body = JSON.generate(Template.render(mapping['body'], context)) if mapping.key?('body')
      raise MappingError, 'backend request body too large' if body && body.bytesize > MAX_BYTES

      headers['content-type'] ||= 'application/json' if body
      has_body = !body.nil? || mapping.fetch('method') != 'GET'
      request = Net::HTTPGenericRequest.new(mapping.fetch('method'), has_body, true, uri.request_uri, headers)
      request.body = body
      perform(uri, request)
    rescue JSON::GeneratorError
      raise MappingError, 'invalid JSON request mapping'
    end

    private

    def build_uri(origin, mapping, context)
      uri = URI.parse(origin)
      uri.path = Template.render(mapping.fetch('path'), context, path: true)
      query = mapping.fetch('query', {}).transform_values { |value| Template.scalar(Template.render(value, context)) }
      uri.query = URI.encode_www_form(query) unless query.empty?
      uri
    rescue URI::InvalidComponentError, URI::InvalidURIError
      raise MappingError, 'invalid backend URI mapping'
    end

    def build_headers(mapping, context)
      mapping.fetch('headers', {}).to_h do |name, template|
        value = Template.scalar(Template.render(template, context))
        raise MappingError, 'invalid header value' if value.match?(/[\x00-\x1f\x7f]/)

        [name.downcase, value]
      end
    end

    def perform(uri, request)
      # Explicitly disable environment proxies: configuration alone selects the destination.
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 3
      http.read_timeout = 5
      http.write_timeout = 5
      http.max_retries = 0
      Timeout.timeout(TIMEOUT, BackendTimeout) do
        http.start { |connection| read_response(connection, request) }
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout
      raise BackendTimeout, 'backend timeout'
    rescue IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
      raise BackendError, 'backend transport failure'
    end

    def read_response(connection, request)
      result = nil
      connection.request(request) do |response|
        body = +''
        response.read_body do |chunk|
          raise BackendError, 'backend response too large' if body.bytesize + chunk.bytesize > MAX_BYTES

          body << chunk
        end
        result = Result.new(status: response.code.to_i, body: body)
      end
      result
    end
  end
end
