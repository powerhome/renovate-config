#!/usr/bin/env ruby

require 'net/http'
require 'uri'
require 'json'
require 'optparse'
require 'cgi'

class PerconaDigestUpdater
  class Error < StandardError; end
  class ConfigUpdateError < Error; end
  class InvalidOptionsError < Error; end
  class ReleaseFetchError < Error; end
  class ReleaseParseError < Error; end

  DIGEST_PATTERN = /\A[a-f0-9]{64}\z/i

  OperatorConfig = Struct.new(:name, :github_repo, :docs_base_url, :docs_pattern, :config_file, :helm_charts, keyword_init: true) do
    def release_notes_url(version)
      "#{docs_base_url}/#{docs_pattern % version}"
    end

    def display_name
      name.upcase
    end

    def helm_chart_names
      helm_charts || []
    end
  end

  CertifiedImage = Struct.new(:package_name, :version, :digest, :architecture, keyword_init: true) do
    SUPPORTED_ARCHITECTURES = ['amd64', 'x86_64', 'x86-64'].freeze

    def supported_architecture?
      architecture.nil? ||
        architecture.strip.empty? ||
        SUPPORTED_ARCHITECTURES.include?(architecture.downcase.strip)
    end
  end

  CertifiedImageCatalog = Struct.new(:certified_images, keyword_init: true) do
    def self.from_release_notes(html_content, operator:, version:, url:)
      certified_images = []
      seen_images = {}

      html_content.scan(/<tr[^>]*>.*?<\/tr>/m) do |row|
        cells = row.scan(/<td[^>]*>(.*?)<\/td>/m).flatten

        next if cells.length < 2

        image_cell = text_from_html(cells[0])
        digest_cell = text_from_html(cells[1])

        next if image_cell.downcase.include?('image') ||
                digest_cell.downcase.include?('digest') ||
                !image_cell.start_with?('percona/') ||
                !digest_cell.match?(PerconaDigestUpdater::DIGEST_PATTERN)

        match = image_cell.match(/\A(?<image_name>percona\/[^:]+):(?<version>.+?)(?:\s+\((?<architecture>[^)]+)\))?\z/)
        next unless match

        certified_image = CertifiedImage.new(
          package_name: match[:image_name].strip,
          version: match[:version].strip,
          digest: digest_cell,
          architecture: match[:architecture]
        )
        next unless certified_image.supported_architecture?

        image_key = [certified_image.package_name, certified_image.version]
        next if seen_images[image_key]

        certified_images << certified_image
        seen_images[image_key] = true
      end

      unless certified_images.empty?
        return new(certified_images: certified_images)
      end

      raise ReleaseParseError,
            "No certified images found for #{operator} #{version} at #{url}. " \
            "Expected release notes table rows with a percona/image:version value and a 64-character digest."
    end

    def package_count
      grouped_images.length
    end

    def summary_lines
      grouped_images.map do |package_name, versions|
        "#{package_name}: #{versions.keys.join(', ')}"
      end
    end

    def image_version_sets
      grouped_images.map do |package_name, versions|
        ImageVersionSet.new(package_name: package_name, versions: versions.keys)
      end
    end

    def package_names
      image_version_sets.map(&:package_name).sort
    end

    def allowed_versions_pattern
      ImageVersionSet.new(
        package_name: 'aggregate',
        versions: image_version_sets.flat_map(&:versions)
      ).allowed_versions_pattern
    end

    def to_a
      certified_images.dup
    end

    private

    def grouped_images
      @grouped_images ||= certified_images.each_with_object({}) do |certified_image, images|
        images[certified_image.package_name] ||= {}
        images[certified_image.package_name][certified_image.version] = certified_image.digest
      end
    end

    def self.text_from_html(html)
      CGI.unescapeHTML(html.gsub(/<[^>]*>/, '')).strip
    end

    private_class_method :text_from_html
  end

  ImageVersionSet = Struct.new(:package_name, :versions, keyword_init: true) do
    def allowed_versions_pattern
      version_list = versions.uniq.sort_by { |version| PerconaDigestUpdater.version_sort_key(version) }
        .map { |version| Regexp.escape(version) }

      "/^(#{version_list.join('|')})$/"
    end

    def major_version_sets
      versions_by_major.sort_by { |major, _major_versions| PerconaDigestUpdater.version_sort_key(major) }
        .map do |major, major_versions|
          [
            major,
            ImageVersionSet.new(package_name: package_name, versions: major_versions)
          ]
        end
    end

    def postgres_major_version_sets
      versions_by_postgres_major.map do |postgres_major, postgres_major_versions|
        [
          postgres_major,
          ImageVersionSet.new(package_name: package_name, versions: postgres_major_versions)
        ]
      end
    end

    def without_postgres_major
      versions_without_postgres_major = versions.reject { |version| postgres_major(version) }

      ImageVersionSet.new(package_name: package_name, versions: versions_without_postgres_major)
    end

    def mysql_line_version_sets
      versions_by_mysql_line.map do |mysql_line, mysql_line_versions|
        [
          mysql_line,
          ImageVersionSet.new(package_name: package_name, versions: mysql_line_versions)
        ]
      end
    end

    private

    def versions_by_major
      versions.each_with_object({}) do |version, major_versions|
        major = version[/\A\d+/]
        next unless major

        major_versions[major] ||= []
        major_versions[major] << version
      end
    end

    def versions_by_postgres_major
      versions.each_with_object({}) do |version, postgres_major_versions|
        major = postgres_major(version)
        next unless major

        postgres_major_versions[major] ||= []
        postgres_major_versions[major] << version
      end.sort_by { |major, _major_versions| PerconaDigestUpdater.version_sort_key(major) }
    end

    def postgres_major(version)
      case package_name
      when 'percona/percona-postgresql-operator'
        version[/\bppg(\d+)(?:\D|$)/, 1]
      when 'percona/percona-distribution-postgresql'
        version[/\A(\d+)\./, 1]
      end
    end

    def versions_by_mysql_line
      versions.each_with_object({}) do |version, mysql_line_versions|
        line = mysql_line(version)
        next unless line

        mysql_line_versions[line] ||= []
        mysql_line_versions[line] << version
      end.sort_by { |line, _line_versions| PerconaDigestUpdater.version_sort_key(line) }
    end

    def mysql_line(version)
      version[/\A(\d+\.\d+)\./, 1]
    end
  end

  RenovatePackageRule = Struct.new(:image_version_set, keyword_init: true) do
    def self.for_current_major(major, image_version_set, versioning: nil)
      new(image_version_set: image_version_set).to_h(
        match_current_version: "/^#{Regexp.escape(major)}\\./",
        versioning: versioning
      )
    end

    def self.for_current_postgres_major(postgres_major, image_version_set, versioning: nil)
      new(image_version_set: image_version_set).to_h(
        match_current_version: postgres_major_matcher(postgres_major, image_version_set.package_name),
        versioning: versioning
      )
    end

    def self.for_current_mysql_line(mysql_line, image_version_set)
      new(image_version_set: image_version_set).to_h(
        match_current_version: "/^#{Regexp.escape(mysql_line)}\\./",
        versioning: 'semver'
      )
    end

    def to_h(match_current_version: nil, versioning: nil)
      rule = {
        'matchDatasources' => ['docker'],
        'matchPackageNames' => [image_version_set.package_name],
      }

      if match_current_version
        rule['matchCurrentVersion'] = match_current_version
      end

      if versioning
        rule['versioning'] = versioning
      end

      rule.merge(
        'allowedVersions' => image_version_set.allowed_versions_pattern,
        'pinDigests' => true
      )
    end

    def self.postgres_major_matcher(postgres_major, package_name)
      escaped_major = Regexp.escape(postgres_major)

      case package_name
      when 'percona/percona-postgresql-operator'
        "/\\bppg#{escaped_major}(?:[.-]\\d+)?-postgres(?:-|$)/"
      when 'percona/percona-distribution-postgresql'
        "/^#{escaped_major}\\./"
      end
    end

    private_class_method :postgres_major_matcher
  end

  RenovateHelmChartRule = Struct.new(:chart_name, :version, keyword_init: true) do
    def to_h
      {
        'matchDatasources' => ['helm'],
        'matchPackageNames' => [chart_name],
        'allowedVersions' => ImageVersionSet.new(
          package_name: chart_name,
          versions: [version]
        ).allowed_versions_pattern
      }
    end
  end

  OPERATORS = {
    'pxc' => OperatorConfig.new(
      name: 'pxc',
      github_repo: 'percona/percona-xtradb-cluster-operator',
      docs_base_url: 'https://docs.percona.com/percona-operator-for-mysql/pxc/ReleaseNotes',
      docs_pattern: 'Kubernetes-Operator-for-PXC-RN%s.html',
      config_file: 'percona-pxc-versions.json',
      helm_charts: [
        'pxc-db',
        'pxc-operator'
      ]
    ),
    'postgresql' => OperatorConfig.new(
      name: 'postgresql',
      github_repo: 'percona/percona-postgresql-operator',
      docs_base_url: 'https://docs.percona.com/percona-operator-for-postgresql/latest/ReleaseNotes',
      docs_pattern: 'Kubernetes-Operator-for-PostgreSQL-RN%s.html',
      config_file: 'percona-postgresql-versions.json',
      helm_charts: [
        'pg-db',
        'pg-operator'
      ]
    )
  }.freeze

  def initialize(operator = 'pxc', version = nil)
    @operator = operator
    @config = OPERATORS[@operator]
    raise "Unsupported operator: #{@operator}. Supported: #{OPERATORS.keys.join(', ')}" unless @config
    
    @version = version || fetch_latest_version
    @release_notes_url = @config.release_notes_url(@version)
  end

  def run
    puts "Processing Percona #{@config.display_name} Operator v#{@version}"

    release_content = fetch_release_notes
    certified_image_catalog = parse_certified_image_catalog(release_content)

    puts "Found #{certified_image_catalog.package_count} certified images:"
    certified_image_catalog.summary_lines.each { |line| puts "  #{line}" }

    update_renovate_config(certified_image_catalog)
    puts "Successfully updated #{@config.config_file}"

    certified_image_catalog.to_a
  end

  private

  def fetch_latest_version
    github_api_url = "https://api.github.com/repos/#{@config.github_repo}/releases"
    uri = URI(github_api_url)
    
    puts "Fetching latest release from GitHub API for #{@config.github_repo}..."
    
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    
    request = Net::HTTP::Get.new(uri)
    request['Accept'] = 'application/vnd.github.v3+json'
    request['User-Agent'] = 'renovate-config-updater'
    
    # Use GitHub token if available for better rate limiting
    if ENV['GITHUB_TOKEN']
      request['Authorization'] = "token #{ENV['GITHUB_TOKEN']}"
    end
    
    response = http.request(request)

    if response.code != '200'
      raise ReleaseFetchError,
            "Failed to fetch GitHub releases for #{@config.name} from #{github_api_url} " \
            "(HTTP #{response.code}): #{response.body}"
    end

    releases = JSON.parse(response.body)
    
    if releases.empty?
      raise ReleaseFetchError, "No releases found for #{@config.name} at #{github_api_url}"
    end

    # Filter out prerelease/beta versions and find the latest stable release
    stable_releases = releases.reject { |release| release['prerelease'] || release['draft'] }
    
    if stable_releases.empty?
      raise ReleaseFetchError, "No stable releases found for #{@config.name} at #{github_api_url}"
    end

    # Extract version from tag_name (e.g., "v1.18.0" -> "1.18.0")
    latest_release = stable_releases.first
    tag_name = latest_release['tag_name']
    version = tag_name.gsub(/^v/, '') # Remove 'v' prefix if present
    
    puts "Latest stable Percona version from GitHub: #{version}"
    puts "Release date: #{latest_release['published_at']}"
    
    version
  rescue JSON::ParserError => e
    raise ReleaseFetchError,
          "Failed to parse GitHub releases response for #{@config.name} from #{github_api_url}: #{e.message}"
  end

  def fetch_release_notes
    uri = URI(@release_notes_url)
    puts "Fetching: #{@release_notes_url}"

    response = Net::HTTP.get_response(uri)

    if response.code != '200'
      raise ReleaseFetchError,
            "Failed to fetch release notes for #{@config.name} #{@version} from #{@release_notes_url} " \
            "(HTTP #{response.code})"
    end

    response.body
  end

  def parse_certified_image_catalog(html_content)
    CertifiedImageCatalog.from_release_notes(
      html_content,
      operator: @config.name,
      version: @version,
      url: @release_notes_url
    )
  end

  def update_renovate_config(certified_image_catalog)
    renovate_path = @config.config_file

    unless File.exist?(renovate_path)
      raise ConfigUpdateError, "#{renovate_path} not found"
    end

    renovate_config = JSON.parse(File.read(renovate_path))

    package_rules = renovate_config['packageRules'] || []

    package_rules.reject! do |rule|
      generated_image_rule?(rule) || generated_helm_chart_rule?(rule)
    end

    certified_image_catalog.image_version_sets.each do |image_version_set|
      package_rules.concat(package_rules_for(image_version_set))
    end

    @config.helm_chart_names.each do |chart_name|
      package_rules << RenovateHelmChartRule.new(
        chart_name: chart_name,
        version: @version
      ).to_h
    end

    # Update the general Percona rule with all allowed versions
    package_rules.each do |rule|
      next unless percona_aggregate_rule?(rule)

      rule['matchDatasources'] = aggregate_datasources
      rule['matchPackageNames'] = aggregate_package_names(certified_image_catalog)
      rule['allowedVersions'] = aggregate_allowed_versions_pattern(certified_image_catalog)
      rule['pinDigests'] = true
    end

    renovate_config['packageRules'] = package_rules

    # Write updated config with pretty formatting
    File.write(renovate_path, "#{JSON.pretty_generate(renovate_config)}\n")
  rescue JSON::ParserError => e
    raise ConfigUpdateError, "Failed to parse #{renovate_path}: #{e.message}"
  end

  def package_rules_for(image_version_set)
    if pxc_mysql_versioned_image?(image_version_set)
      return mysql_line_package_rules_for(image_version_set)
    end

    if postgresql_postgres_versioned_image?(image_version_set)
      return postgres_major_package_rules_for(image_version_set)
    end

    if postgresql_pmm_client?(image_version_set)
      return image_version_set.major_version_sets.map do |major, major_image_version_set|
        RenovatePackageRule.for_current_major(
          major,
          major_image_version_set,
          versioning: 'semver'
        )
      end
    end

    [RenovatePackageRule.new(image_version_set: image_version_set).to_h]
  end

  def mysql_line_package_rules_for(image_version_set)
    image_version_set.mysql_line_version_sets.map do |mysql_line, mysql_line_image_version_set|
      RenovatePackageRule.for_current_mysql_line(mysql_line, mysql_line_image_version_set)
    end
  end

  def postgres_major_package_rules_for(image_version_set)
    package_rules = []
    image_version_set_without_postgres_major = image_version_set.without_postgres_major

    unless image_version_set_without_postgres_major.versions.empty?
      package_rules << RenovatePackageRule.new(
        image_version_set: image_version_set_without_postgres_major
      ).to_h(versioning: versioning_for(image_version_set))
    end

    package_rules.concat(
      image_version_set.postgres_major_version_sets.map do |postgres_major, postgres_major_image_version_set|
        RenovatePackageRule.for_current_postgres_major(
          postgres_major,
          postgres_major_image_version_set,
          versioning: versioning_for(image_version_set)
        )
      end
    )
  end

  def versioning_for(image_version_set)
    return 'semver' if image_version_set.package_name == 'percona/percona-postgresql-operator'

    nil
  end

  def pxc_mysql_versioned_image?(image_version_set)
    @config.name == 'pxc' &&
      [
        'percona/percona-xtradb-cluster',
        'percona/percona-xtrabackup'
      ].include?(image_version_set.package_name)
  end

  def postgresql_postgres_versioned_image?(image_version_set)
    @config.name == 'postgresql' &&
      [
        'percona/percona-postgresql-operator',
        'percona/percona-distribution-postgresql'
      ].include?(image_version_set.package_name)
  end

  def postgresql_pmm_client?(image_version_set)
    @config.name == 'postgresql' &&
      image_version_set.package_name == 'percona/pmm-client'
  end

  def percona_aggregate_rule?(rule)
    package_names = rule['matchPackageNames']
    return false unless package_names
    return false unless rule.key?('groupName')

    package_names.any? { |name| name.include?('percona') }
  end

  def aggregate_datasources
    datasources = ['docker']
    datasources << 'helm' unless @config.helm_chart_names.empty?
    datasources
  end

  def aggregate_package_names(certified_image_catalog)
    (certified_image_catalog.package_names + @config.helm_chart_names).sort
  end

  def aggregate_allowed_versions_pattern(certified_image_catalog)
    ImageVersionSet.new(
      package_name: 'aggregate',
      versions: certified_image_catalog.image_version_sets.flat_map(&:versions) + [@version]
    ).allowed_versions_pattern
  end

  def generated_image_rule?(rule)
    package_names = rule['matchPackageNames']
    package_names &&
      package_names.one? &&
      package_names.first.start_with?('percona/') &&
      !rule.key?('groupName')
  end

  def generated_helm_chart_rule?(rule)
    package_names = rule['matchPackageNames']
    package_names &&
      package_names.one? &&
      @config.helm_chart_names.include?(package_names.first) &&
      !rule.key?('groupName')
  end

  def self.version_sort_key(version)
    parts = version.split(/[-.]/).map do |part|
      part.match?(/\A\d+\z/) ? part.to_i : part
    end

    parts << 0 while parts.length < 10
    parts.map { |part| part.is_a?(String) ? [1, part] : [0, part] }
  end
end

if __FILE__ == $0
  begin
    options = { operator: 'pxc' }
    OptionParser.new do |opts|
      opts.banner = "Usage: #{$0} [options]"

      opts.on("-o", "--operator OPERATOR", "Operator to process (pxc, postgresql, or all)",
              "Available: #{PerconaDigestUpdater::OPERATORS.keys.join(', ')}") do |o|
        options[:operator] = o
      end

      opts.on("-v", "--version VERSION", "Specific Percona version to process") do |v|
        options[:version] = v
      end

      opts.on("-h", "--help", "Show this help") do
        puts opts
        exit
      end
    end.parse!

    if options[:operator] == 'all'
      if options[:version]
        raise PerconaDigestUpdater::InvalidOptionsError,
              '--version can only be used with --operator pxc or --operator postgresql'
      end

      PerconaDigestUpdater::OPERATORS.keys.each do |operator|
        puts "\n" + "="*50
        updater = PerconaDigestUpdater.new(operator, options[:version])
        updater.run
      end
    else
      updater = PerconaDigestUpdater.new(options[:operator], options[:version])
      updater.run
    end
  rescue PerconaDigestUpdater::Error => e
    warn "ERROR: #{e.message}"
    exit 1
  end
end
