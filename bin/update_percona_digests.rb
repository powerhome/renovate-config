#!/usr/bin/env ruby

require 'net/http'
require 'uri'
require 'json'
require 'optparse'
require 'cgi'

class PerconaDigestUpdater
  DIGEST_PATTERN = /\A[a-f0-9]{64}\z/i

  OperatorConfig = Struct.new(:name, :github_repo, :docs_base_url, :docs_pattern, :config_file, keyword_init: true) do
    def release_notes_url(version)
      "#{docs_base_url}/#{docs_pattern % version}"
    end

    def display_name
      name.upcase
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

  ImageVersionSet = Struct.new(:package_name, :versions, keyword_init: true) do
    def allowed_versions_pattern
      version_list = versions.uniq.sort_by { |version| PerconaDigestUpdater.version_sort_key(version) }
        .map { |version| Regexp.escape(version) }

      "/^(#{version_list.join('|')})$/"
    end
  end

  RenovatePackageRule = Struct.new(:image_version_set, keyword_init: true) do
    def to_h
      {
        'matchDatasources' => ['docker'],
        'matchPackageNames' => [image_version_set.package_name],
        'allowedVersions' => image_version_set.allowed_versions_pattern,
        'pinDigests' => true
      }
    end
  end

  OPERATORS = {
    'pxc' => OperatorConfig.new(
      name: 'pxc',
      github_repo: 'percona/percona-xtradb-cluster-operator',
      docs_base_url: 'https://docs.percona.com/percona-operator-for-mysql/pxc/ReleaseNotes',
      docs_pattern: 'Kubernetes-Operator-for-PXC-RN%s.html',
      config_file: 'percona-pxc-versions.json'
    ),
    'postgresql' => OperatorConfig.new(
      name: 'postgresql',
      github_repo: 'percona/percona-postgresql-operator',
      docs_base_url: 'https://docs.percona.com/percona-operator-for-postgresql/latest/ReleaseNotes',
      docs_pattern: 'Kubernetes-Operator-for-PostgreSQL-RN%s.html',
      config_file: 'percona-postgresql-versions.json'
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
    certified_images = parse_certified_images(release_content)

    if certified_images.empty?
      puts "ERROR: No certified images found in release notes"
      exit 1
    end

    grouped_images = group_certified_images(certified_images)

    puts "Found #{grouped_images.length} certified images:"
    grouped_images.each { |name, versions| puts "  #{name}: #{versions.keys.join(', ')}" }

    update_renovate_config(certified_images)
    puts "Successfully updated #{@config.config_file}"

    certified_images
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
      puts "ERROR: Failed to fetch GitHub releases (HTTP #{response.code})"
      puts "Response: #{response.body}"
      exit 1
    end

    releases = JSON.parse(response.body)
    
    if releases.empty?
      puts "ERROR: No releases found on GitHub"
      exit 1
    end

    # Filter out prerelease/beta versions and find the latest stable release
    stable_releases = releases.reject { |release| release['prerelease'] || release['draft'] }
    
    if stable_releases.empty?
      puts "ERROR: No stable releases found on GitHub"
      exit 1
    end

    # Extract version from tag_name (e.g., "v1.18.0" -> "1.18.0")
    latest_release = stable_releases.first
    tag_name = latest_release['tag_name']
    version = tag_name.gsub(/^v/, '') # Remove 'v' prefix if present
    
    puts "Latest stable Percona version from GitHub: #{version}"
    puts "Release date: #{latest_release['published_at']}"
    
    version
  end

  def fetch_release_notes
    uri = URI(@release_notes_url)
    puts "Fetching: #{@release_notes_url}"

    response = Net::HTTP.get_response(uri)

    if response.code != '200'
      puts "ERROR: Failed to fetch release notes (HTTP #{response.code})"
      exit 1
    end

    response.body
  end

  def parse_certified_images(html_content)
    certified_images = []
    seen_images = {}

    # Parse HTML table rows for certified images
    # Look for pattern: <td>percona/image:version</td><td>digest</td>
    html_content.scan(/<tr[^>]*>.*?<\/tr>/m) do |row|
      cells = row.scan(/<td[^>]*>(.*?)<\/td>/m).flatten

      next if cells.length < 2

      image_cell = text_from_html(cells[0])
      digest_cell = text_from_html(cells[1])

      # Skip header rows and non-image rows
      next if image_cell.downcase.include?('image') ||
              digest_cell.downcase.include?('digest') ||
              !image_cell.start_with?('percona/') ||
              !digest_cell.match?(DIGEST_PATTERN)

      # Parse image name and version
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

    certified_images
  end

  def update_renovate_config(certified_images)
    renovate_path = @config.config_file

    unless File.exist?(renovate_path)
      puts "ERROR: #{renovate_path} not found"
      exit 1
    end

    renovate_config = JSON.parse(File.read(renovate_path))

    image_version_sets = build_image_version_sets(certified_images)

    package_rules = renovate_config['packageRules'] || []

    package_rules.reject! do |rule|
      generated_image_rule?(rule)
    end

    image_version_sets.each do |image_version_set|
      package_rules << RenovatePackageRule.new(image_version_set: image_version_set).to_h
    end

    # Update the general Percona rule with all allowed versions
    aggregate_allowed_versions = allowed_versions_pattern(image_version_sets.flat_map(&:versions))

    package_rules.each do |rule|
      next unless percona_aggregate_rule?(rule)

      rule['matchDatasources'] = ['docker']
      rule['matchPackageNames'] = image_version_sets.map(&:package_name).sort
      rule['allowedVersions'] = aggregate_allowed_versions
      rule['pinDigests'] = true
    end

    renovate_config['packageRules'] = package_rules

    # Write updated config with pretty formatting
    File.write(renovate_path, "#{JSON.pretty_generate(renovate_config)}\n")
  end

  def build_image_version_sets(certified_images)
    group_certified_images(certified_images).map do |image_name, versions|
      ImageVersionSet.new(package_name: image_name, versions: versions.keys)
    end
  end

  def group_certified_images(certified_images)
    certified_images.each_with_object({}) do |certified_image, images|
      images[certified_image.package_name] ||= {}
      images[certified_image.package_name][certified_image.version] = certified_image.digest
    end
  end

  def text_from_html(html)
    CGI.unescapeHTML(html.gsub(/<[^>]*>/, '')).strip
  end

  def allowed_versions_pattern(versions)
    ImageVersionSet.new(package_name: 'aggregate', versions: versions).allowed_versions_pattern
  end

  def percona_aggregate_rule?(rule)
    package_names = rule['matchPackageNames']
    return false unless package_names
    return false unless rule.key?('groupName')

    package_names.any? { |name| name.include?('percona') }
  end

  def generated_image_rule?(rule)
    package_names = rule['matchPackageNames']
    package_names &&
      package_names.one? &&
      package_names.first.start_with?('percona/') &&
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
      warn 'ERROR: --version can only be used with --operator pxc or --operator postgresql'
      exit 1
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
end
