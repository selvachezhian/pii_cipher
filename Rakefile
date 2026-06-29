# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "rubocop/rake_task"

RuboCop::RakeTask.new

require "rb_sys/extensiontask"

task build: :compile

GEMSPEC = Gem::Specification.load("pii_cipher.gemspec")

RbSys::ExtensionTask.new("pii_cipher", GEMSPEC) do |ext|
  ext.lib_dir = "lib/pii_cipher"
  ext.cross_compile = true
  ext.cross_platform = %w[
    x86_64-linux
    aarch64-linux
    x86_64-darwin
    arm64-darwin
    x64-mingw-ucrt
  ]
  ext.cross_compiling do |spec|
    # rb_sys is only needed to compile from source; pre-built gems don't need it
    spec.dependencies.reject! { |dep| dep.name == "rb_sys" }
  end
end

task default: %i[compile spec rubocop]
