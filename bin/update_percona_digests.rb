#!/usr/bin/env ruby

require 'net/http'
require 'uri'
require 'json'
require 'optparse'

class PerconaDigestUpdater
  OPERATORS = {
    'pxc' => {
      github_repo: 'percona/percona-xtradb-cluster-operator',
      docs_base_url: 'https://docs.percona.com/percona-operator-for-mysql/pxc/ReleaseNotes',
      docs_pattern: 'Kubernetes-Operator-for-PXC-RN%s.html',
      config_file: 'percona-pxc-versions.json'
    },
    'postgresql' => {
      github_repo: 'percona/percona-postgresql-operator',
      docs_base_url: 'https://docs.percona.com/percona-operator-for-postgresql/2.0/ReleaseNotes',
      docs_pattern: 'Kubernetes-Operator-for-PostgreSQL-RN%s.html',
      config_file: 'percona-postgresql-versions.json'
    }
  }.freeze

  def initialize(operator = 'pxc', version = nil)
    @operator = operator
    @config = OPERATORS[@operator]
    raise "Unsupported operator: #{@operator}. Supported: #{OPERATORS.keys.join(', ')}" unless @config
    
    @version = version || fetch_latest_version
    @release_notes_url = "#{@config[:docs_base_url]}/#{@config[:docs_pattern] % @version}"
  end

  def run
    puts "Processing Percona #{@operator.upcase} Operator v#{@version}"

    release_content = fetch_release_notes
    images = parse_certified_images(release_content)

    if images.empty?
      puts "ERROR: No certified images found in release notes"
      exit 1
    end

    puts "Found #{images.length} certified images:"
    images.each { |name, versions| puts "  #{name}: #{versions.keys.join(', ')}" }

    update_renovate_config(images)
    puts "Successfully updated #{@config[:config_file]}"

    images
  end

  private

  def fetch_latest_version
    github_api_url = "https://api.github.com/repos/#{@config[:github_repo]}/releases"
    uri = URI(github_api_url)
    
    puts "Fetching latest release from GitHub API for #{@config[:github_repo]}..."
    
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
    images = {}

    # Parse HTML table rows for certified images
    # Look for pattern: <td>percona/image:version</td><td>digest</td>
    html_content.scan(/<tr[^>]*>.*?<\/tr>/m) do |row|
      cells = row.scan(/<td[^>]*>(.*?)<\/td>/m).flatten

      next if cells.length < 2

      image_cell = cells[0].strip.gsub(/<[^>]*>/, '') # Remove HTML tags
      digest_cell = cells[1].strip.gsub(/<[^>]*>/, '') # Remove HTML tags

      # Skip header rows and non-image rows
      next if image_cell.downcase.include?('image') ||
              digest_cell.downcase.include?('digest') ||
              !image_cell.start_with?('percona/') ||
              !digest_cell.match?(/^[a-f0-9]{64}$/i)

      # Parse image name and version
      if image_cell.match(/^(percona\/[^:]+):(.+?)(?:\s+\([^)]+\))?$/)
        image_name = $1.strip
        version = $2.strip

        images[image_name] ||= {}
        images[image_name][version] = digest_cell
      end
    end

    images
  end

  def update_renovate_config(images)
    renovate_path = @config[:config_file]

    unless File.exist?(renovate_path)
      puts "ERROR: #{renovate_path} not found"
      exit 1
    end

    renovate_config = JSON.parse(File.read(renovate_path))

    image_configs = build_image_configs(images)

    package_rules = renovate_config['packageRules'] || []

    package_rules.reject! do |rule|
      rule['matchPackageNames'] &&
      rule['matchPackageNames'].any? { |name|
        name.start_with?('percona/') && !name.include?('/^percona//')
      }
    end

    image_configs.each do |image_name, config|
      package_rules << {
        'matchPackageNames' => [image_name],
        'allowedVersions' => config[:allowed_versions],
        'replacementName' => image_name,
        'replacementVersion' => config[:latest_version],
        'replacementDigest' => config[:latest_digest]
      }
    end

    # Update the general Percona rule with all allowed versions
    general_rule = package_rules.find { |rule|
      rule['matchPackageNames'] && rule['matchPackageNames'].include?('/^percona//')
    }

            if general_rule
      all_versions = image_configs.values.flat_map { |config|
        pattern_content = config[:allowed_versions].gsub(/^\/\^\(|\)\$$/, '')
        pattern_content.split('|').map { |v| v.gsub(/\\/, '') } # Remove escaping
      }.uniq.sort

      escaped_versions = all_versions.map { |v| Regexp.escape(v) }
      general_rule['allowedVersions'] = "/^(#{escaped_versions.join('|')})$/"
    end

    renovate_config['packageRules'] = package_rules

    # Write updated config with pretty formatting
    File.write(renovate_path, JSON.pretty_generate(renovate_config))
  end

  def build_image_configs(images)
    configs = {}

    images.each do |image_name, versions|
      # Create regex pattern for allowed versions (escape special chars)
      version_list = versions.keys.map { |v| Regexp.escape(v) }
      version_pattern = "/^(#{version_list.join('|')})$/"

      # Determine latest version using version comparison
      latest_version = versions.keys.sort_by { |v|
        # Handle version formats like "8.0.42-33.1", "2.8.15", "3.3.1", "2.7.0-ppg17.5.2-postgres-gis3.3.8"
        # Split on non-alphanumeric characters and convert numbers to integers for proper sorting
        parts = v.split(/[-.]/).map do |part|
          if part.match(/^\d+$/)
            part.to_i
          else
            # For non-numeric parts, use original string but sort numerically if possible
            part
          end
        end

        # Pad with zeros to ensure consistent comparison length
        while parts.length < 10
          parts << 0
        end

        # Convert non-numeric strings to sortable format
        parts.map { |p| p.is_a?(String) ? [1, p] : [0, p] }
      }.last

      configs[image_name] = {
        allowed_versions: version_pattern,
        latest_version: latest_version,
        latest_digest: "sha256:#{versions[latest_version]}"
      }
    end

    configs
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
