# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'yaml'
require 'webrick'

require_relative 'api_compatibility_layer/errors'
require_relative 'api_compatibility_layer/template'
require_relative 'api_compatibility_layer/config'
require_relative 'api_compatibility_layer/backend'
require_relative 'api_compatibility_layer/engine'
require_relative 'api_compatibility_layer/server'
