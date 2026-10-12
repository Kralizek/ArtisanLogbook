require "yaml"
require "json"

config = YAML.safe_load(File.read(".curseforge.yml"))
versions = config.fetch("gameVersions")
abort "gameVersions must be a nonempty array" unless versions.is_a?(Array) && !versions.empty?
release_version = ENV.fetch("VERSION")
abort "Invalid release version" unless /\A[0-9A-Za-z.-]+\z/.match?(release_version)
seen = []
rows = versions.map do |entry|
  abort "Each game version must contain name, version and id" unless entry.is_a?(Hash) && entry.keys.sort == %w[id name version]
  name, version, id = entry.values_at("name", "version", "id")
  abort "Invalid or duplicate flavor" unless name.is_a?(String) && /\A[a-z][a-z0-9-]*\z/.match?(name) && !seen.include?(name)
  seen << name
  abort "Invalid game version" unless version.is_a?(String) && /\A\d+\.\d+\.\d+\z/.match?(version)
  abort "Game version ID must be a positive integer" unless id.is_a?(Integer) && id.positive?
  # The legacy unqualified bundle is Retail only. Future flavors must provide
  # their own GitHub release asset; never fall back to the Retail bundle.
  asset = name == "retail" ? "ArtisanLogbook-Bundle-#{release_version}.zip" : "ArtisanLogbook-Bundle-#{name}-#{release_version}.zip"
  if name == "retail"
    parts = version.split(".").map(&:to_i)
    interface = parts[0] * 10000 + parts[1] * 100 + parts[2]
    %w[ArtisanLogbook ArtisanLogbook_Core].each do |addon|
      toc = File.read("src/addon/src/#{addon}/#{addon}.toc")
      abort "Retail version does not match #{addon} Interface" unless toc.lines.any? { |line| line.strip == "## Interface: #{interface}" }
    end
  end
  entry.merge("asset" => asset)
end
puts JSON.generate("include" => rows)
