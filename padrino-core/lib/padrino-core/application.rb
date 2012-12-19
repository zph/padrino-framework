require 'padrino-core/caller'
require 'padrino-core/request'
require 'padrino-core/response'
require 'padrino-core/helpers'
require 'padrino-core/settings'
require 'padrino-core/templates'
require 'padrino-core/exceptions'
require 'padrino-core/routes'

module Padrino
  class Application
    include Rack::Utils
    include Helpers
    include Settings
    include Templates
    include Routes

    class NotFound < NameError #:nodoc:
      def http_status; 404; end
    end

    attr_accessor :app

    def initialize(app=nil)
      @app = app
      super()
    end

    # Rack call interface.
    def call(env)
      dup.call!(env)
    end

    attr_accessor :env, :request, :response, :params

    def call!(env) # :nodoc:
      @env      = env
      @request  = Request.new(env)
      @response = Response.new
      @params   = indifferent_params(@request.params)
      template_cache.clear if settings.reload_templates
      force_encoding(@params)

      @response['Content-Type'] = nil
      invoke { dispatch! }
      invoke { error_block!(response.status) }

      unless @response['Content-Type']
        if Array === body and body[0].respond_to? :content_type
          content_type body[0].content_type
        else
          content_type :html
        end
      end

      @response.finish
    end

    # Exit the current block, halts any further processing
    # of the request, and returns the specified response.
    def halt(*response)
      response = response.first if response.length == 1
      throw :halt, response
    end

    # Pass control to the next matching route.
    # If there are no more matching routes, Padrino will
    # return a 404 response.
    def pass(&block)
      throw :pass, block
    end

    # Forward the request to the downstream app -- middleware only.
    def forward
      fail "downstream app not set" unless @app.respond_to? :call
      status, headers, body = @app.call env
      @response.status = status
      @response.body = body
      @response.headers.merge! headers
      nil
    end

    private
    # Run filters defined on the class and all superclasses.
    def filter!(type, base = settings)
      filter! type, base.superclass if base.superclass.respond_to?(:filters)
      base.filters[type].each { |args| process_route(*args) }
    end

    # Run routes defined on the class and all superclasses.
    def route!(base=settings, pass_block=nil)
      if routes = base.routes[@request.request_method]
        routes.each do |pattern, keys, conditions, block|
          pass_block = process_route(pattern, keys, conditions) do |*args|
            route_eval { block[*args] }
          end
        end
      end

      # Run routes defined in superclass.
      if base.superclass.respond_to?(:routes)
        return route!(base.superclass, pass_block)
      end

      route_eval(&pass_block) if pass_block
      route_missing
    end

    # Run a route block and throw :halt with the result.
    def route_eval
      throw :halt, yield
    end

    # If the current request matches pattern and conditions, fill params
    # with keys and call the given block.
    # Revert params afterwards.
    #
    # Returns pass block.
    def process_route(pattern, keys, conditions, block = nil, values = [])
      route = @request.path_info
      route = '/' if route.empty?
      return unless match = pattern.match(route)
      values += match.captures.to_a.map { |v| force_encoding URI.decode_www_form_component(v) if v }

      if values.any?
        original, @params = params, params.merge('splat' => [], 'captures' => values)
        keys.zip(values) { |k,v| Array === @params[k] ? @params[k] << v : @params[k] = v if v }
      end

      catch(:pass) do
        conditions.each { |c| throw :pass if c.bind(self).call == false }
        block ? block[self, values] : yield(self, values)
      end
    ensure
      @params = original if original
    end

    # No matching route was found or all routes passed. The default
    # implementation is to forward the request downstream when running
    # as middleware (@app is non-nil); when no downstream app is set, raise
    # a NotFound exception. Subclasses can override this method to perform
    # custom route miss logic.
    def route_missing
      if @app
        forward
      else
        raise NotFound
      end
    end

    # Attempt to serve static files from public directory. Throws :halt when
    # a matching file is found, returns nil otherwise.
    def static!
      return if (public_dir = settings.public_folder).nil?
      public_dir = File.expand_path(public_dir)

      path = File.expand_path(public_dir + unescape(request.path_info))
      return unless path.start_with?(public_dir) and File.file?(path)

      env['padrino.static_file'] = path
      cache_control(*settings.static_cache_control) if settings.static_cache_control?
      send_file path, :disposition => nil
    end

    # Dispatch a request with error handling.
    def dispatch!
      invoke do
        static! if settings.static? && (request.get? || request.head?)
        filter! :before
        route!
      end
    rescue ::Exception => boom
      invoke { handle_exception!(boom) }
    ensure
      filter! :after unless env['padrino.static_file']
    end

    # Enable string or symbol key access to the nested params hash.
    def indifferent_params(object)
      case object
      when Hash
        new_hash = indifferent_hash
        object.each { |key, value| new_hash[key] = indifferent_params(value) }
        new_hash
      when Array
        object.map { |item| indifferent_params(item) }
      else
        object
      end
    end

    # Creates a Hash with indifferent access.
    def indifferent_hash
      Hash.new {|hash,key| hash[key.to_s] if Symbol === key }
    end

    # Run the block with 'throw :halt' support and apply result to the response.
    def invoke
      res = catch(:halt) { yield }
      res = [res] if Fixnum === res or String === res
      if Array === res and Fixnum === res.first
        status(res.shift)
        body(res.pop)
        headers(*res)
      elsif res.respond_to? :each
        body res
      end
      nil
    end

    # Error handling during requests.
    def handle_exception!(boom)
      @env['padrino.error'] = boom

      if boom.respond_to? :http_status
        status(boom.http_status)
      else
        status(500)
      end

      status(500) unless status.between? 400, 599

      if server_error?
        raise boom if settings.show_exceptions? and settings.show_exceptions != :after_handler
      end

      if not_found?
        headers['X-Cascade'] = 'pass'
        body '<h1>Not Found</h1>'
      end

      res = error_block!(boom.class, boom) || error_block!(status, boom)
      return res if res or not server_error?
      raise boom if settings.raise_errors? or settings.show_exceptions?
      error_block! Exception, boom
    end

    # Find an custom error block for the key(s) specified.
    def error_block!(key, *block_params)
      base = settings
      while base.respond_to?(:errors)
        next base = base.superclass unless args_array = base.errors[key]
        args_array.reverse_each do |args|
          first = args == args_array.first
          args += [block_params]
          resp = process_route(*args)
          return resp unless resp.nil? && !first
        end
      end
      return false unless key.respond_to? :superclass and key.superclass < Exception
      error_block!(key.superclass, *block_params)
    end

    class << self
      attr_reader :templates, :errors

      # Removes all routes, filters, middleware and extension hooks from the
      # current class (not routes/filters/... defined by its superclass).
      def reset!
        @errors     = {}
        @middleware = []
        @prototype  = nil
        @extensions = []
        @templates  =
          superclass.respond_to?(:templates) ? Hash.new { |h,k| superclass.templates[k] } : {}

        reset_routes!
      end

      # Extension modules registered on this class and all superclasses.
      def extensions
        if superclass.respond_to?(:extensions)
          (@extensions + superclass.extensions).uniq
        else
          @extensions
        end
      end

      # Middleware used in this class and all superclasses.
      def middleware
        if superclass.respond_to?(:middleware)
          superclass.middleware + @middleware
        else
          @middleware
        end
      end

      # Define a custom error handler. Optionally takes either an Exception
      # class, or an HTTP status code to specify which errors should be
      # handled.
      def error(*codes, &block)
        args  = compile! "ERROR", //, block
        codes = codes.map { |c| Array(c) }.flatten
        codes << Exception if codes.empty?
        codes.each { |c| (@errors[c] ||= []) << args }
      end

      # Sugar for `error(404) { ... }`
      def not_found(&block)
        error 404, &block
      end

      # Lookup or register a mime type in Rack's mime registry.
      def mime_type(type, value=nil)
        return type if type.nil? || type.to_s.include?('/')
        type = ".#{type}" unless type.to_s[0] == ?.
        return Rack::Mime.mime_type(type, nil) unless value
        Rack::Mime::MIME_TYPES[type] = value
      end

      # provides all mime types matching type, including deprecated types:
      #   mime_types :html # => ['text/html']
      #   mime_types :js   # => ['application/javascript', 'text/javascript']
      def mime_types(type)
        type = mime_type type
        type =~ /^application\/(xml|javascript)$/ ? [type, "text/#$1"] : [type]
      end

      # Makes the methods defined in the block and in the Modules given
      # in `extensions` available to the handlers and templates
      def helpers(*extensions, &block)
        class_eval(&block)   if block_given?
        include(*extensions) if extensions.any?
      end

      # Register an extension. Alternatively take a block from which an
      # extension will be created and registered on the fly.
      def register(*extensions, &block)
        extensions << Module.new(&block) if block_given?
        @extensions += extensions
        extensions.each do |extension|
          extension.respond_to?(:registered) ? extension.registered(self) : extend(extension)
        end
      end

      def development?; environment == :development end
      def production?;  environment == :production  end
      def test?;        environment == :test        end

      # Set configuration options for Padrino and/or the app.
      # Allows scoping of settings for certain environments.
      def configure(*envs, &block)
        yield self if envs.empty? || envs.include?(environment.to_sym)
      end

      # Use the specified Rack middleware
      def use(middleware, *args, &block)
        @prototype = nil
        @middleware << [middleware, args, block]
      end

      # The prototype instance used to process requests.
      def prototype
        @prototype ||= new
      end

      # Create a new instance without middleware in front of it.
      alias new! new unless method_defined?(:new!)

      # Create a new Padrino application. The block is evaluated in the new app's
      # class scope.
      def new(*args, &block)
        build(Rack::Builder.new, *args, &block).to_app
      end

      # Run a the webserver
      def run!(options={}, &block)
        base = block_given? ? Padrino.new(&block) : self
        Padrino::Server.start(base, options)
      end

      # Creates a Rack::Builder instance with all the middleware set up and
      # an instance of this class as end point.
      def build(builder, *args, &bk)
        setup_default_middleware builder
        setup_middleware builder
        builder.run new!(*args, &bk)
        builder
      end

      def call(env)
        synchronize { prototype.call(env) }
      end

      # Fixes encoding issues by
      # * defaulting to UTF-8
      # * casting params to Encoding.default_external
      #
      # The latter might not be necessary if Rack handles it one day.
      # Keep an eye on Rack's LH #100.
      def force_encoding(data, encoding = default_encoding)
        return if data == settings || data.is_a?(Tempfile)
        if data.respond_to? :force_encoding
          data.force_encoding(encoding).encode!
        elsif data.respond_to? :each_value
          data.each_value { |v| force_encoding(v, encoding) }
        elsif data.respond_to? :each
          data.each { |v| force_encoding(v, encoding) }
        end
        data
      end

      private
      def setup_default_middleware(builder)
        builder.use Padrino::Exceptions  if show_exceptions?
        builder.use Rack::MethodOverride if method_override?
        builder.use Rack::Head
        setup_sessions(builder)
      end

      def setup_middleware(builder)
        middleware.each { |c,a,b| builder.use(c, *a, &b) }
      end

      def setup_sessions(builder)
        return unless sessions?
        options = {}
        options[:secret] = session_secret if session_secret?
        options.merge! sessions.to_hash if sessions.respond_to? :to_hash
        builder.use Rack::Session::Cookie, options
      end

      def inherited(subclass)
        subclass.reset!
        subclass.set :app_file, Padrino.first_caller unless subclass.app_file?
        super
      end

      @@mutex = Mutex.new
      def synchronize(&block)
        if lock?
          @@mutex.synchronize(&block)
        else
          yield
        end
      end
    end

    def force_encoding(*args)
      settings.force_encoding(*args)
    end

    reset!

    set :environment, PADRINO_ENV.downcase.to_sym
    set :show_exceptions, Proc.new { development? }
    set :raise_errors, Proc.new { test? }
    set :sessions, false
    set :logging, Proc.new { development? }
    set :method_override, true
    set :default_encoding, 'utf-8'
    set :add_charset, %w[javascript xml xhtml+xml json].map { |t| "application/#{t}" } << /^text\//
    set :session_secret, SecureRandom.hex(64)
    set :app_file, nil
    set :root, Proc.new { app_file && File.expand_path(File.dirname(app_file)) }
    set :views, Proc.new { root && File.join(root, 'views') }
    set :reload_templates, Proc.new { development? }
    set :lock, false
    set :threaded, true
    set :public_folder, Proc.new { root && File.join(root, 'public') }
    set :static, Proc.new { public_folder && File.exist?(public_folder) }
    set :static_cache_control, false

    error ::Exception do
      response.status = 500
      content_type 'text/html'
      '<h1>Internal Server Error</h1>'
    end

    configure :development do
      get '/__padrino__/:image.png' do
        filename = File.expand_path("../images/#{params[:image]}.png", __FILE__)
        content_type :png
        send_file filename
      end

      error NotFound do
        content_type 'text/html'

        <<-HTML.undent
          <!DOCTYPE html>
          <html>
          <head>
            <style type="text/css">
            body { text-align:center;font-family:helvetica,arial;font-size:22px;
              color:#888;margin:20px}
            #c {margin:0 auto;width:500px;text-align:left}
            </style>
          </head>
          <body>
            <h2>Padrino doesn&rsquo;t know this ditty.</h2>
            <img src='/__padrino__/404.png'>
            <div id="c">
              Try this:
              <pre>#{request.request_method.downcase} '#{request.path_info}' do\n  "Hello World"\nend</pre>
            </div>
          </body>
          </html>
        HTML
      end
    end
  end # Application
end # Padrino
