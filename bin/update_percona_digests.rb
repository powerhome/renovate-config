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

  # A tag is the PostGIS flavour if it carries a -postgres-gis segment; anything
  # else carrying -postgres is the plain distribution flavour.
  POSTGIS_FLAVOUR = 'gis'
  PLAIN_POSTGRES_FLAVOUR = 'plain'

  def self.postgres_flavour(version)
    version.include?('-postgres-gis') ? POSTGIS_FLAVOUR : PLAIN_POSTGRES_FLAVOUR
  end

  OperatorConfig = Struct.new(:name, :github_repo, :docs_base_url, :docs_pattern, :config_file, :helm_charts, :pmm_file_patterns, :image_repository_splits, keyword_init: true) do
    def release_notes_url(version)
      "#{docs_base_url}/#{docs_pattern % version}"
    end

    def display_name
      name.upcase
    end

    def helm_chart_names
      helm_charts || []
    end

    def pmm_match_file_names
      pmm_file_patterns || []
    end

    def image_repository_split_list
      image_repository_splits || []
    end
  end

  # Percona has repeatedly moved a component out of the operator's own image
  # repository, where it lived as a compatibility-suffixed tag, and into a
  # repository of its own. Renovate keys rules on package name, so it cannot see
  # such a move as an upgrade: the old tags simply stop being published. Left
  # alone, a deployment is either frozen on the last suffixed tag or -- worse --
  # matched to the bare operator tag and handed the operator image in place of
  # the component. Declare each move so we can emit a Renovate replacement.
  #
  # These are facts about Percona's packaging history, not something derivable
  # from one release's certified image table: a component missing from that
  # table is far more likely to be a documentation omission than a migration.
  # The target version is still read from the table, so it stays current.
  ImageRepositorySplit = Struct.new(
    :source_package_name,
    :match_current_version,
    :package_name,
    :postgres_major_scoped,
    keyword_init: true
  ) do
    def postgres_major_scoped?
      !!postgres_major_scoped
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

    # PostGIS is a different image flavour, not a newer version of the plain
    # one, so the two must never be offered to each other. Splitting the sets
    # by flavour lets each get a matchCurrentVersion that only its own flavour
    # can satisfy.
    def postgres_major_flavour_version_sets
      versions_by_postgres_major.flat_map do |postgres_major, postgres_major_versions|
        postgres_major_versions.group_by { |version| PerconaDigestUpdater.postgres_flavour(version) }
          .map do |flavour, flavour_versions|
            [
              postgres_major,
              flavour,
              ImageVersionSet.new(package_name: package_name, versions: flavour_versions)
            ]
          end
      end
    end

    def highest_version
      versions.max_by { |version| PerconaDigestUpdater.version_sort_key(version) }
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
    BARE_VERSION_MATCHER = '/^\\d+\\.\\d+\\.\\d+$/'

    def self.for_current_major(major, image_version_set, versioning: nil, match_file_names: nil)
      new(image_version_set: image_version_set).to_h(
        match_current_version: "/^#{Regexp.escape(major)}\\./",
        versioning: versioning,
        match_file_names: match_file_names
      )
    end

    def self.for_current_postgres_major(postgres_major, image_version_set, flavour: nil, versioning: nil)
      new(image_version_set: image_version_set).to_h(
        match_current_version: postgres_major_matcher(
          postgres_major,
          image_version_set.package_name,
          flavour
        ),
        versioning: versioning
      )
    end

    # The operator repository hosts several components, told apart only by tag
    # suffix. A rule generated from the bare operator version must therefore say
    # so, or it matches every suffixed tag too and offers the operator image as
    # an upgrade for whatever that tag actually is.
    def self.for_bare_version(image_version_set, versioning: nil)
      new(image_version_set: image_version_set).to_h(
        match_current_version: BARE_VERSION_MATCHER,
        versioning: versioning
      )
    end

    def self.for_current_mysql_line(mysql_line, image_version_set)
      new(image_version_set: image_version_set).to_h(
        match_current_version: "/^#{Regexp.escape(mysql_line)}\\./",
        versioning: 'semver'
      )
    end

    def to_h(match_current_version: nil, versioning: nil, match_file_names: nil)
      rule = {
        'matchDatasources' => ['docker'],
        'matchPackageNames' => [image_version_set.package_name],
      }

      if match_file_names
        rule['matchFileNames'] = match_file_names
      end

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

    def self.postgres_major_matcher(postgres_major, package_name, flavour = nil)
      escaped_major = Regexp.escape(postgres_major)

      case package_name
      when 'percona/percona-postgresql-operator'
        "/\\bppg#{escaped_major}(?:[.-]\\d+)?#{postgres_flavour_suffix(flavour)}/"
      when 'percona/percona-distribution-postgresql'
        "/^#{escaped_major}\\./"
      end
    end

    def self.postgres_flavour_suffix(flavour)
      case flavour
      when PerconaDigestUpdater::POSTGIS_FLAVOUR then '-postgres-gis'
      when PerconaDigestUpdater::PLAIN_POSTGRES_FLAVOUR then '-postgres$'
      else '-postgres(?:-|$)'
      end
    end

    private_class_method :postgres_major_matcher, :postgres_flavour_suffix
  end

  # Renovate models a package moving repositories as a "replacement" rather than
  # a version bump. Naming the target explicitly turns what would otherwise be a
  # frozen or mis-resolved dependency into one clean migration PR per consumer.
  RenovateReplacementRule = Struct.new(
    :source_package_name,
    :match_current_version,
    :replacement_package_name,
    :replacement_version,
    keyword_init: true
  ) do
    def to_h
      {
        'matchDatasources' => ['docker'],
        'matchPackageNames' => [source_package_name],
        'matchCurrentVersion' => match_current_version,
        'replacementName' => replacement_package_name,
        'replacementVersion' => replacement_version
      }
    end
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
      ],
      pmm_file_patterns: [
        '**/mysql.yaml.erb'
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
      ],
      pmm_file_patterns: [
        '**/postgresql.yaml.erb',
        '**/percona_pgcluster.yaml.erb'
      ],
      # pgBackRest and pgBouncer left the operator repository in 2.7.0; the plain
      # PostgreSQL image followed in 2.8.0. The last operator tags carrying them
      # are 2.6.x and 2.7.x respectively. PostGIS images are still published in
      # the operator repository, so -postgres-gis tags are deliberately absent
      # here.
      image_repository_splits: [
        ImageRepositorySplit.new(
          source_package_name: 'percona/percona-postgresql-operator',
          match_current_version: '/-pgbackrest[\\d.-]*$/',
          package_name: 'percona/percona-pgbackrest'
        ),
        ImageRepositorySplit.new(
          source_package_name: 'percona/percona-postgresql-operator',
          match_current_version: '/-pgbouncer[\\d.-]*$/',
          package_name: 'percona/percona-pgbouncer'
        ),
        ImageRepositorySplit.new(
          source_package_name: 'percona/percona-postgresql-operator',
          package_name: 'percona/percona-distribution-postgresql',
          postgres_major_scoped: true
        )
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

    package_rules.concat(image_repository_split_rules(certified_image_catalog))

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

    if pmm_client?(image_version_set)
      return pmm_client_package_rules_for(image_version_set)
    end

    [RenovatePackageRule.new(image_version_set: image_version_set).to_h]
  end

  def pmm_client_package_rules_for(image_version_set)
    # PMM client is certified with multiple Percona operators, but a docker image
    # reference to percona/pmm-client does not identify which operator owns it.
    # Scope PMM rules to the operator-specific krane template filename convention.
    if postgresql_pmm_client?(image_version_set)
      return image_version_set.major_version_sets.map do |major, major_image_version_set|
        RenovatePackageRule.for_current_major(
          major,
          major_image_version_set,
          versioning: 'semver',
          match_file_names: @config.pmm_match_file_names
        )
      end
    end

    [
      RenovatePackageRule.new(image_version_set: image_version_set).to_h(
        match_file_names: @config.pmm_match_file_names
      )
    ]
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
      package_rules << RenovatePackageRule.for_bare_version(
        image_version_set_without_postgres_major,
        versioning: versioning_for(image_version_set)
      )
    end

    package_rules.concat(
      image_version_set.postgres_major_flavour_version_sets.map do |postgres_major, flavour, flavour_image_version_set|
        RenovatePackageRule.for_current_postgres_major(
          postgres_major,
          flavour_image_version_set,
          flavour: flavour,
          versioning: versioning_for(image_version_set)
        )
      end
    )
  end

  # Emitted after every version rule, so that for a tag whose component has
  # moved the replacement wins over anything a broader rule may have matched.
  def image_repository_split_rules(certified_image_catalog)
    image_version_sets_by_package_name = certified_image_catalog.image_version_sets
      .each_with_object({}) { |set, sets| sets[set.package_name] = set }

    @config.image_repository_split_list.flat_map do |split|
      target_image_version_set = image_version_sets_by_package_name[split.package_name]

      unless target_image_version_set
        raise ConfigUpdateError,
              "#{split.package_name} is declared as the new home of #{split.source_package_name} " \
              "tags matching #{split.match_current_version || 'a PostgreSQL major'}, but it is absent " \
              "from the certified images for #{@config.name} #{@version}. Refusing to generate a " \
              "replacement rule without a version to point it at."
      end

      replacement_rules_for(split, target_image_version_set)
    end
  end

  def replacement_rules_for(split, target_image_version_set)
    unless split.postgres_major_scoped?
      return [
        RenovateReplacementRule.new(
          source_package_name: split.source_package_name,
          match_current_version: split.match_current_version,
          replacement_package_name: split.package_name,
          replacement_version: target_image_version_set.highest_version
        ).to_h
      ]
    end

    # replacementVersion takes a single value, so scope one rule per PostgreSQL
    # major. Without that, a 16.x deployment could be handed a 17.x image.
    target_image_version_set.postgres_major_version_sets.map do |postgres_major, major_image_version_set|
      RenovateReplacementRule.new(
        source_package_name: split.source_package_name,
        match_current_version: "/\\bppg#{Regexp.escape(postgres_major)}(?:[.-]\\d+)?-postgres$/",
        replacement_package_name: split.package_name,
        replacement_version: major_image_version_set.highest_version
      ).to_h
    end
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

  def pmm_client?(image_version_set)
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
    (aggregate_image_version_sets(certified_image_catalog).map(&:package_name) + @config.helm_chart_names).sort
  end

  def aggregate_allowed_versions_pattern(certified_image_catalog)
    ImageVersionSet.new(
      package_name: 'aggregate',
      versions: aggregate_image_version_sets(certified_image_catalog).flat_map(&:versions) + [@version]
    ).allowed_versions_pattern
  end

  def aggregate_image_version_sets(certified_image_catalog)
    certified_image_catalog.image_version_sets.reject do |image_version_set|
      pmm_client?(image_version_set)
    end
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
