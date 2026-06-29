# frozen_string_literal: true

require "bundler/gem_tasks"
require "rb_sys/extensiontask"

task build: :compile

GEMSPEC = Gem::Specification.load("pii_cipher.gemspec")

RbSys::ExtensionTask.new("pii_cipher", GEMSPEC) do |ext|
  ext.lib_dir = "lib/pii_cipher"
  ext.cross_compiling do |spec|
    # rb_sys is only needed to compile from source; pre-built gems don't need it.
    spec.dependencies.reject! { |dep| dep.name == "rb_sys" }
  end
end

# The dev/test tasks below need gems that are absent inside the cross-compile
# build container (rb-sys-dock installs only the runtime deps). Guard them so
# the Rakefile still loads there and `rake native` / `rake compile` work.
begin
  require "rspec/core/rake_task"
  RSpec::Core::RakeTask.new(:spec)

  require "rubocop/rake_task"
  RuboCop::RakeTask.new

  task default: %i[compile spec rubocop]
rescue LoadError
  task default: :compile
end
