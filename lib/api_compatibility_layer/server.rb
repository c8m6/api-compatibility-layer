# frozen_string_literal: true

module APICompatibilityLayer
  class Server
    class Servlet < WEBrick::HTTPServlet::AbstractServlet
      def initialize(server, engine, output)
        super(server)
        @engine = engine
        @output = output
      end

      def service(request, response)
        write(response, @engine.call(read_request(request)))
      rescue PayloadTooLarge
        response.keep_alive = false
        write(response, @engine.error(413, 'payload_too_large'))
      rescue StandardError => e
        # Transport parsing errors keep WEBrick's status; never log request data or exception messages.
        raise if e.is_a?(WEBrick::HTTPStatus::Status)

        @output.puts(JSON.generate('event' => 'internal_error', 'type' => e.class.name))
        write(response, @engine.error(500, 'internal_error'))
      end

      private

      def read_request(request)
        body = +''
        request.body do |chunk|
          raise PayloadTooLarge if body.bytesize + chunk.bytesize > Backend::MAX_BYTES

          body << chunk
        end
        Engine::Request.new(
          http_method: request.request_method, path: request.unparsed_uri.split('?', 2).first,
          query: request.query_string.to_s, headers: request.header.transform_values { |value| value.join(', ') },
          body: body
        )
      end

      def write(response, result)
        response.status = result.status
        result.headers.each { |key, value| response[key] = value }
        response.body = result.body
        @output.puts(JSON.generate('event' => 'request', 'status' => result.status))
      end
    end

    def initialize(config, output: $stdout)
      output.sync = true
      @http = WEBrick::HTTPServer.new(BindAddress: config.listen.fetch('address'), Port: config.listen.fetch('port'),
                                      MaxClients: 32, RequestTimeout: 15, AccessLog: [],
                                      Logger: WEBrick::Log.new($stderr, WEBrick::Log::FATAL),
                                      ServerSoftware: 'APICompatibilityLayer')
      @http.mount('/', Servlet, Engine.new(config), output)
    end

    def start
      %w[INT TERM].each { |signal| Signal.trap(signal) { @http.shutdown } }
      @http.start
    end
  end
end
