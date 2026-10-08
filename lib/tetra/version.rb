# frozen_string_literal: true

require 'socket'

# Tetra: a four-operation arithmetic API with live request telemetry.
module Tetra
  VERSION = '0.1.0'

  # What build is running, and where. VERSION, COMMIT and BUILD_DATE are
  # baked into the image as environment variables at build time.
  def self.version_info(env = ENV, started_at = Time.now)
    {
      service: 'tetra',
      implementation: 'ruby',
      version: env['VERSION'].to_s.empty? ? "v#{VERSION}" : env['VERSION'],
      commit: env['COMMIT'].to_s.empty? ? 'unknown' : env['COMMIT'],
      build_date: env['BUILD_DATE'].to_s,
      runtime: "ruby#{RUBY_VERSION}",
      hostname: Socket.gethostname,
      started_at: started_at.utc.iso8601
    }
  end
end
