# frozen_string_literal: true

require_relative '../support/transport_relay'
require 'open3'
require 'rbconfig'

RSpec.describe TransportRelay do
  let(:settings) { { 'ACL_RELAY_UPSTREAM_HOST' => 'upstream.example.test' } }

  it 'requires an explicit upstream' do
    expect { described_class.new({}) }.to raise_error(KeyError)
  end

  it 'accepts hostnames and IPv4 loopback addresses' do
    expect(described_class.new(settings)).to be_privileged_port
    expect(described_class.new(settings.merge('ACL_RELAY_UPSTREAM_HOST' => '127.0.0.1'))).to be_privileged_port
  end

  it 'does not request a privileged interpreter for a high listen port' do
    expect(described_class.new(settings.merge('ACL_RELAY_LISTEN_PORT' => '1053'))).not_to be_privileged_port
  end

  ['', '-upstream', 'http://upstream.example.test', 'upstream,option', "upstream\n"].each do |host|
    it "rejects invalid upstream #{host.inspect}" do
      expect { described_class.new(settings.merge('ACL_RELAY_UPSTREAM_HOST' => host)) }.to raise_error(ArgumentError)
    end
  end

  %w[ACL_RELAY_LISTEN_PORT ACL_RELAY_UPSTREAM_PORT].each do |key|
    %w[0 65536 -1 invalid 53,option].each do |value|
      it "rejects #{key}=#{value}" do
        expect { described_class.new(settings.merge(key => value)) }.to raise_error(ArgumentError)
      end
    end
  end

  it 'fails the companion before HTTP startup if its configuration is incomplete' do
    output, status = Open3.capture2e({ 'ACL_RELAY_UPSTREAM_HOST' => nil, 'RUBYOPT' => nil },
                                     RbConfig.ruby, 'bin/acl-with-relay')
    expect(status.exitstatus).to eq(1)
    expect(output).to include('Companion configuration/startup error')
  end

  it 'relays HTTP writes and DNS reads over UDP/TCP and shuts down both children' do
    port = TCPServer.open('127.0.0.1', 0) { |server| server.local_address.ip_port }
    output, status = Open3.capture2e({ 'ACL_RELAY_SMOKE_PORT' => port.to_s }, RbConfig.ruby, 'script/relay_smoke.rb')
    expect(status.success?).to be(true), output
    expect(output).to include('Relay smoke passed')
  end

  it 'stops HTTP if the UDP listener cannot start' do
    occupied = UDPSocket.new
    occupied.bind('0.0.0.0', 0)
    relay_port = occupied.local_address.ip_port
    http_port = TCPServer.open('127.0.0.1', 0) { |server| server.local_address.ip_port }
    data = configuration.merge('listen' => { 'address' => '127.0.0.1', 'port' => http_port })
    Tempfile.create(['relay-failure', '.yaml']) do |file|
      file.write(YAML.dump(data))
      file.flush
      environment = { 'ACL_CONFIG' => file.path, 'ACL_RELAY_UPSTREAM_HOST' => '127.0.0.1', 'RUBYOPT' => nil,
                      'ACL_RELAY_LISTEN_PORT' => relay_port.to_s }
      output, status = Timeout.timeout(10) { Open3.capture2e(environment, RbConfig.ruby, 'bin/acl-with-relay') }
      expect(status.success?).to be(false)
      expect(output).to include('Relay configuration/startup error')
      expect { TCPSocket.new('127.0.0.1', http_port) }.to raise_error(Errno::ECONNREFUSED)
    end
  ensure
    occupied&.close
  end
end
