require 'ascii_press/version'

require 'rubypress'
require 'asciidoctor'
require 'logger'
require 'stringio'
require 'json'

require 'active_support/core_ext/enumerable'

require 'rest-client'
require 'base64'

module AsciiPress
  # For setting the default logger
  def self.logger=(new_logger)
    @logger = new_logger
  end

  # A default STDOUT logger
  def self.logger
    @logger || Logger.new(STDOUT)
  end

  class Renderer
    class Rendering
      # @return [String] The HTML resulting from the asciidoc
      attr_reader :html

      # @return [Asciidoctor::Document] The document from the +asciidoctor+ gem
      attr_reader :doc

      # @return [Hash] The adoc file's attributes standardized with symbol keys and string values
      attr_reader :data

      # @return [Array <String>] The tags which will be set in +WordPress+
      attr_accessor :tags

      # @return [String] The title that will be used
      attr_accessor :title

      # Create a new {Rendering} object (intended to be used by Syncers like {WordPressSyncer})
      def initialize(html, doc, data)
        @html = html
        @doc = doc
        @data = data
        @title = doc.doctitle
      end

      # @!visibility private
      def attribute_value(name, default = nil)
        doc.attributes[name.to_s] || default
      end

      # @!visibility private
      def list_attribute_value(name, default = [])
        value = attribute_value(name, :VALUE_DOES_NOT_EXIST)
        if value == :VALUE_DOES_NOT_EXIST
          default
        else
          value.split(/\s*,\s*/)
        end
      end

      # @!visibility private
      def attribute_exists?(name)
        doc.attributes.key?(name.to_s)
      end
    end

    # @param options [Hash]
    # @option options [Hash] :asciidoc_options Passed directly to the +Asciidoctor.load+ method.  See the {http://asciidoctor.org/rdoc/Asciidoctor.html AsciiDoctor documentation}
    # @option options [Proc] :before_convertion Proc which is given the asciidoctor text.  Whatever is returned is passed to +Asciidoctor.load+.  See the {http://asciidoctor.org/rdoc/Asciidoctor.html AsciiDoctor documentation}
    # @option options [Proc] :after_conversion Proc which is given the html text after the Asciidoctor conversion.  Whatever is returned will be uploaded to WordPress
    # @option options [Proc] :rendering_proc Proc which is given the {Rendering} object (see below).  Changes made be made to the rendering in-place
    #
    def initialize(options = {asciidoc_options: {}})
      @options = options
    end

    # @!visibility private
    def render(adoc_file_path)
      doc = nil
      errors = capture_stderr do
        document_text = File.read(adoc_file_path)
        base_dir = ::File.expand_path(File.dirname(adoc_file_path))
        if before_convertion = @options[:before_convertion]
          document_text = before_convertion.call(document_text)
        end
        doc = Asciidoctor.load(document_text, @options[:asciidoc_options].merge(base_dir: base_dir))
      end
      puts errors.split(/[\n\r]+/).reject {|line| line.match(/out of sequence/) }.join("\n")

      html = doc.convert

      if after_conversion = @options[:after_conversion]
        html = after_conversion.call(html)
      end

      data = doc.attributes.each_with_object({}) do |(key, value), result|
        result[key.to_sym] = value.to_s
      end

      data.reject! {|_, value| value.nil? }

      Rendering.new(html, doc, data).tap do |rendering|
        rendering.tags = rendering.list_attribute_value('tags')
        rendering.tags << 'public' if rendering.attribute_exists?(:public)
        rendering.tags << 'private' if rendering.attribute_exists?(:private)

        if @options[:rendering_proc]
          rendering.tags = @options[:rendering_proc].call(rendering)
        end
      end
    end

    private
    def capture_stderr
      real_stderr, $stderr = $stderr, StringIO.new
      yield
      $stderr.string
    ensure
      $stderr = real_stderr
    end
  end

  class WordPressHttpSyncer
    def initialize(hostname, username, password, post_type, renderer, options = {})
      @username = username
      @password = password
      @hostname = hostname
      @post_type = post_type
      @logger = options[:logger] || AsciiPress.logger
      @renderer = renderer || Renderer.new
      @filter_proc = options[:filter_proc] || Proc.new { true }
      @delete_not_found = options[:delete_not_found]
      @generate_tags = options[:generate_tags]
      @options = options

      all_pages = find_all(@post_type)
      @all_pages_by_slug = all_pages.index_by { |post| post["slug"] }
      log :info, "Got #{@all_pages_by_slug.size} pages from the database"

      if @generate_tags
        all_tags = find_all("tags")
        @all_tags_by_name = all_tags.index_by { |tag| tag["name"].downcase }
        log :info, "Got #{@all_tags_by_name.size} tags from the database"
      end

    end

    def sync(adoc_file_paths, custom_fields = {})
      synced_post_names = []

      adoc_file_paths.each do |adoc_file_path|
        synced_post_names << sync_file_path(adoc_file_path, custom_fields)
      end

      if @delete_not_found
        (@all_pages_by_slug.keys - synced_post_names).each do |post_name_to_delete|
          post_id = @all_pages_by_slug[post_name_to_delete]['post_id']

          log :info, "Deleting missing post_name: #{post_name_to_delete} (post ##{post_id})"

          # send_message(:deletePost, blog_id: @hostname, post_id: post_id)
        end
      end

    end

    private

    def sync_file_path(adoc_file_path, custom_fields = {})
      rendering = @renderer.render(adoc_file_path)

      return if !@filter_proc.call(rendering.doc)

      if !(slug = rendering.attribute_value(:slug))
        log :warn, "WARNING: COULD NOT POST DUE TO NO SLUG FOR: #{adoc_file_path}"
        return
      end

      title = rendering.title
      html = rendering.html

      log :info, "Syncing to WordPress: #{title} (slug: #{slug})"

      user_password = "#{@username}:#{@password}"
      headers = {:Authorization => "Basic #{Base64.encode64(user_password)}"}

      if @generate_tags
        missing_tags = rendering.tags.select { |tag| @all_tags_by_name[tag.downcase].nil? }
        puts "Found missing tags: #{missing_tags.inspect}" if !missing_tags.empty?
        missing_tags.each do |tag|
          content = {
            name: tag,
            slug: tag.downcase
          }
          response = RestClient.post "#{@hostname}/wp-json/wp/v2/tags", content, headers
          @all_tags_by_name[tag.downcase] = response
        end
      end

      content = {
                  date: Time.now.strftime("%Y-%m-%dT%H:%M:%S%:z"),
                  slug: slug,
                  title: title,
                  content: html,
                  status:   @options[:post_status] || 'draft',
                  adoc_attributes: rendering.doc.attributes.to_json
                }

      puts "Adding tags to post body: #{rendering.tags.inspect}"
      content[:tags] = rendering.tags.map { |slug| @all_tags_by_name[slug.downcase]["id"] } if @generate_tags

      if page = @all_pages_by_slug[slug]
        if page['custom_fields']
          content[:custom_fields].each do |f|
            found = page['custom_fields'].find { |field| field['key'] == f[:key] }
            f['id'] = found['id'] if found
          end
        end

        post_id = page['id'].to_i

        log :info, "Editing Post ##{post_id} on _#{@hostname}_ custom-field #{rendering.doc.attributes.to_json}"

        uri = "#{@hostname}/wp-json/wp/v2/#{@post_type}/#{post_id}"
        begin
          RestClient.post uri, content, headers
        rescue RestClient::InternalServerError => e
          puts e.inspect
        end
      else
        log :info, "Making a new post for '#{title}' on _#{@hostname}_"

        RestClient.post "#{@hostname}/wp-json/wp/v2/#{@post_type}", content, headers
      end

      slug
    end

    def log(level, message)
        @logger.send(level, "WORDPRESS: #{message}")
    end

    def find_all(resource)
      all_pages = []

      page = 1
      per_page = 100
      while true
        response =  RestClient.get "#{@hostname}/wp-json/wp/v2/#{resource}?per_page=#{per_page}&page=#{page}"
        total_pages = response.headers[:x_wp_totalpages].to_i
        all_pages = all_pages + JSON.parse(response.body)

        if total_pages <= page
          return all_pages
        else
          page+=1
        end
      end
    end

  end

  class WordPressSyncer
    # Creates a synchronizer object which can be used to synchronize a set of asciidoc files to WordPress posts
    # @param hostname [String] Hostname for WordPress blog
    # @param username [String] Wordpress username
    # @param password [String] Wordpress password
    # @param post_type [String] Wordpress post type to synchronize posts with
    # @param renderer [Renderer] Renderer object which will be used to process asciidoctor files
    # @param options [Hash]
    # @option options [Logger] :logger Logger to be used for informational output.  Defaults to {AsciiPress.logger}
    # @option options [Proc] :filter_proc Proc which is given an +AsciiDoctor::Document+ object and returns +true+ or +false+ to decide if a document should be synchronized
    # @option options [Boolean] :delete_not_found Should posts on the WordPress server which don't match any documents locally get deleted?
    # @option options [Boolean] :generate_tags Should asciidoctor tags be synchronized to WordPress? (defaults to +false+)
    # @option options [String] :post_status The status to assign to posts when they are synchronized.  Defaults to +'draft'+.  See the {https://github.com/zachfeldman/rubypress rubypress} documentation
    def initialize(hostname, username, password, post_type, renderer, options = {})
      @hostname = hostname
      @wp_client = Rubypress::Client.new(host: @hostname, username: username, password: password)
      @post_type = post_type
      @logger = options[:logger] || AsciiPress.logger
      @renderer = renderer || Renderer.new
      @filter_proc = options[:filter_proc] || Proc.new { true }
      @delete_not_found = options[:delete_not_found]
      @generate_tags = options[:generate_tags]
      @options = options

      all_pages = @wp_client.getPosts(filter: {post_type: @post_type, number: 1000})
      @all_pages_by_post_name = all_pages.index_by {|post| post['post_name'] }
      log :info, "Got #{@all_pages_by_post_name.size} pages from the database"
    end

    # @param adoc_file_path [Array <String>] Paths of the asciidoctor files to synchronize
    # @param custom_fields [Hash] Custom fields for WordPress.
    def sync(adoc_file_paths, custom_fields = {})
      synced_post_names = []

      adoc_file_paths.each do |adoc_file_path|
        synced_post_names << sync_file_path(adoc_file_path, custom_fields)
      end

      if @delete_not_found
        (@all_pages_by_post_name.keys - synced_post_names).each do |post_name_to_delete|
          post_id = @all_pages_by_post_name[post_name_to_delete]['post_id']

          log :info, "Deleting missing post_name: #{post_name_to_delete} (post ##{post_id})"

          send_message(:deletePost, blog_id: @hostname, post_id: post_id)
        end
      end

    end

    private

    def sync_file_path(adoc_file_path, custom_fields = {})
      rendering = @renderer.render(adoc_file_path)

      return if !@filter_proc.call(rendering.doc)

      if !(slug = rendering.attribute_value(:slug))
        log :warn, "WARNING: COULD NOT POST DUE TO NO SLUG FOR: #{adoc_file_path}"
        return
      end

      title = rendering.title
      html = rendering.html

      log :info, "Syncing to WordPress: #{title} (slug: #{slug})"

      # log :info, "data: #{rendering.data.inspect}"

      custom_fields_array = custom_fields.merge('adoc_attributes' => rendering.doc.attributes.to_json).map {|k, v| {key: k, value: v} }
      content = {
                  post_type:     @post_type,
                  post_date:     Time.now - 60*60*24,
                  post_content:  html,
                  post_title:    title,
                  post_name:     slug,
                  post_status:   @options[:post_status] || 'draft',
                  custom_fields: custom_fields_array
                }

      content[:terms_names] = {post_tag: rendering.tags} if @generate_tags

      if page = @all_pages_by_post_name[slug]
        if page['custom_fields']
          content[:custom_fields].each do |f|
            found = page['custom_fields'].find { |field| field['key'] == f[:key] }
            f['id'] = found['id'] if found
          end
        end

        post_id = page['post_id'].to_i

        log :info, "Editing Post ##{post_id} on _#{@hostname}_ custom-field #{content[:custom_fields].inspect}"

        send_message(:editPost, blog_id: @hostname, post_id: post_id, content: content)
      else
        log :info, "Making a new post for '#{title}' on _#{@hostname}_"

        send_message(:newPost, blog_id: @hostname, content: content)
      end

      slug
    end

    def new_content_same_as_page?(content, page)
      main_keys_different = %i(post_content post_title post_name post_status).any? do |key|
        content[key] != page[key.to_s]
      end

      page_fields = page['custom_fields'].each_with_object({}) {|field, h| h[field['key']] = field['value'] }
      content_fields = content[:custom_fields].each_with_object({}) {|field, h| h[field[:key].to_s] = field[:value] }

      !main_keys_different && oyyyy
    end

    def log(level, message)
      @logger.send(level, "WORDPRESS: #{message}")
    end

    def send_message(message, *args)
      @wp_client.send(message, *args).tap do |result|
        raise "WordPress #{message} failed!" if !result
      end
    end
  end

  DEFAULT_SLUG_RULES = {
    'Cannot start with `-` or `_`' => -> (slug) { !%w(- _).include?(slug[0]) },
    'Cannot end with `-` or `_`' => -> (slug) { !%w(- _).include?(slug[-1]) },
    'Cannot have multiple `-` in a row' => -> (slug) { !slug.match(/--/) },
    'Must only contain lowercase letters, numbers, hyphens, and underscores' => -> (slug) { !!slug.match(/^[a-z0-9\-\_]+$/) },
  }

  def self.slug_valid?(slug, rules = DEFAULT_SLUG_RULES)
    slug && rules.values.all? {|rule| rule.call(slug) }
  end

  def self.violated_slug_rules(slug, rules = DEFAULT_SLUG_RULES)
    return ['No slug'] if slug.nil?

    rules.reject do |desc, rule|
      rule.call(slug)
    end.map(&:first)
  end

  def self.verify_adoc_slugs!(adoc_paths, rules = DEFAULT_SLUG_RULES)
    data = adoc_paths.map do |path|
      doc = Asciidoctor.load(File.read(path))

      slug = doc.attributes['slug']
      if !slug_valid?(slug, rules)
        violations = violated_slug_rules(slug, rules)
        [path, slug, violations]
      end
    end.compact

    if data.size > 0
      require 'colorize'
      data.each do |path, slug, violations|
        puts 'WARNING!!'.red
        puts "The document #{path.light_blue} has the slug #{slug.inspect.light_blue} which in invalid because:"
        violations.each do |violation|
          puts "  - #{violation.yellow}"
        end
      end
      raise 'Invalid slugs.  Cannot continue'
    end
  end
end
