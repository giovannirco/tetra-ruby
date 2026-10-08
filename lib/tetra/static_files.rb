# frozen_string_literal: true

module Tetra
  # Serves the UI from web/. Files are read once at startup, so a request
  # can never reach outside the directory and serving needs no disk I/O.
  class StaticFiles
    TYPES = {
      '.html' => 'text/html; charset=utf-8',
      '.js' => 'text/javascript; charset=utf-8',
      '.css' => 'text/css; charset=utf-8',
      '.svg' => 'image/svg+xml',
      '.json' => 'application/json',
      '.png' => 'image/png'
    }.freeze

    File = Struct.new(:body, :type, :cache_control)

    def initialize(root)
      @files = Dir.glob('**/*', base: root).each_with_object({}) do |rel, files|
        full = ::File.join(root, rel)
        ext = ::File.extname(rel)
        next unless ::File.file?(full) && (TYPES.key?(ext) || %w[LICENSE VERSION].include?(::File.basename(rel)))

        # Vendored libraries are immutable per release; the app's files are revalidated.
        cache = rel.start_with?('vendor/') ? [:public, { max_age: 86_400 }] : [:no_cache]
        files["/#{rel}"] = File.new(::File.binread(full), TYPES.fetch(ext, 'text/plain; charset=utf-8'), cache).freeze
      end.freeze
    end

    def lookup(path)
      @files[path == '/' ? '/index.html' : path]
    end
  end
end
