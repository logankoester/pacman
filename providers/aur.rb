#
# Cookbook Name:: pacman
# Provider:: aur
#
# Copyright:: 2010, Opscode, Inc <legal@opscode.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/mixin/shell_out'
require 'chef/mixin/language'
require 'tsort'
require 'open-uri'
include Chef::Mixin::ShellOut

def aurfile_path target, build_dir
    target_build = ::File.join build_dir, target.name, target.name
    aurfiles = ::Dir["#{target_build}-*.pkg.tar.xz"]
    if aurfiles.length == 0
        "#{target_build}-#{target.version}-#{target.arch}.pkg.tar.xz"
    else
        aurfiles[0]
    end
end

def already_built? target, build_dir
    ::File.exists? aurfile_path(target, build_dir)
end

def build_aur target, opts
    pkgbuild = ::File.join opts.build_dir, target.name, "PKGBUILD"
    aurfile = aurfile_path target, opts.build_dir

    Chef::Log.debug("Creating build directory")
    directory "build_dir_#{target.name}" do
        path opts.build_dir
        owner opts.build_user
        group opts.build_group
        mode 0755
        action :create
    end

    Chef::Log.debug("Retrieving source for #{target.name}")
    remote_file ::File.join opts.build_dir, "#{target.name}.tar.gz" do
        source "https://aur.archlinux.org/cgit/aur.git/snapshot/#{target.name}.tar.gz"
        owner opts.build_user
        group opts.build_group
        mode 0644
        action :create_if_missing
    end

    Chef::Log.debug("Untarring source package for #{target.name}")
    execute "tar -xf #{target.name}.tar.gz" do
        cwd opts.build_dir
        user opts.build_user
        group opts.build_group
        action :run
    end

    if opts.pkgbuild_src
        Chef::Log.debug("Replacing PKGBUILD with custom version")
        cookbook_file pkgbuild do
            source "PKGBUILD"
            owner opts.build_user
            group opts.build_group
            mode 0644
            action :create
        end
    end

    if opts.patches.length > 0
        Chef::Log.debug("Adding new patches")
        opts.patches.each do |patch|
            cookbook_file ::File.join opts.build_dir, target.name, patch do
                source patch
                mode 0644
                action :create
            end
        end
    end

    if new_resource.options
        Chef::Log.debug("Appending #{opts.options} to configure command")
        opt = Chef::Util::FileEdit.new pkgbuild
        opt.search_file_replace(/(.\/configure.+$)/, "\\1 #{opts.options}")
        opt.write_file
    end

    skippgpcheck = opts.skippgpcheck ? " --skippgpcheck" : ""

    Chef::Log.debug("Building package #{target.name}")
    execute "makepkg #{target.name}" do
        command "makepkg -sf --noconfirm#{skippgpcheck}"
        cwd ::File.join opts.build_dir, target.name
        creates aurfile
        user opts.build_user
        group opts.build_group
        environment opts.environment
        action :run
    end
end

def install_aur target, opts
    execute "install AUR package #{target.name}" do
        command lazy {
            aurfile = aurfile_path target, opts.build_dir
            "pacman -U --noconfirm  --noprogressbar #{aurfile}"
        }
    end
end

def install_with_deps target, opts
    deps = target.all_dependencies.ordered
    deps.reject { |p| p.already_installed? }
    .each do |package|
        Chef::Log.debug("Installing #{package} as a dependency of #{target}")
        if package.is_aur?
            if not already_built? package, opts.build_dir
                build_aur package, opts
            end
            install_aur package, opts
        else
            pacman_package package.name
        end
    end
end

action :build do
    target = Package.aur new_resource.package_name
    opts = new_resource

    Chef::Log.debug("Checking for #{aurfile_path target, opts.build_dir}")
    if not already_built? target, build_dir
        build_aur target, opts
        new_resource.updated_by_last_action true
    end
end

action :install do
    target = Package.aur new_resource.package_name
    if not target.already_installed?
        install_aur target, new_resource
        new_resource.updated_by_last_action true
    end
end

action :sync do
    target = Package.aur new_resource.package_name
    if not target.already_installed?
        install_with_deps target, new_resource
        new_resource.updated_by_last_action true
    end
end

class Package
    attr_reader :name, :version, :arch, :dependents

    @@version_arch_re = /Version +: ([\w.-]+).+Architecture +: (\w+)/m
    @@default_arch = RUBY_PLATFORM.split("-")[0]

    def initialize name, is_aur
        info = Package.fetch_latest_info name, is_aur
        @name = name
        @is_aur = is_aur
        @version = info[:version]
        @arch = info[:arch]
        @dependents = info[:dependents]
        @installed = Package.installed_info name
    end

    def self.aur name
        Package.new name, true
    end

    def self.pacman name
        Package.new name, false
    end

    def to_s
        if @is_aur
            "Aur(#{@name}-#{@version})"
        else
            "Pacman(#{@name}-#{@version})"
        end
    end

    def eql? other
        @name == other.name
    end

    def hash
        @name.hash
    end

    def is_aur?
        @is_aur
    end

    def already_installed?
        @installed && @version == @installed[:version]
    end

    def all_dependencies
        AurDeps.new self
    end

    private

    def self.pkgbuild_url name
        "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=#{name}"
    end

    def self.shell command
        Mixlib::ShellOut.new(command,
            :user => "nobody",
            :group => "nobody",
            :cwd => "/tmp",
        ).run_command.stdout.strip
    end

    def self.fetch_latest_info name, is_aur
        if is_aur
            pkgbuild = open(Package.pkgbuild_url name).read
            command = <<-FIN
                #{pkgbuild}
                echo
                echo version ${pkgver}-${pkgrel}
                echo arch ${arch}
                echo depends ${depends[@]} ${makedepends[@]}
            FIN
            parser = Mixlib::ShellOut.new(command,
                :user => "nobody",
                :group => "nobody",
                :cwd => "/tmp",
                :timeout => 1)
            data = parser.run_command.stdout.strip.split("\n").last 3
            {
                :version => data[0].strip.split[1],
                :arch => data[1].include?("any") ? "any" : @@default_arch,
                :dependents => data[2].strip.split[1..-1].map do |dep|
                    # TODO: This removes version constraints like the
                    # apacman package does, in the future, try to follow
                    # these constraints instead.
                    dep.match(/[a-z0-9\-_.]+/)[0]
                end,
            }
        else
            parsed = Package.shell("pacman -Si '#{name}'")
                .match(@@version_arch_re)
            if parsed && parsed.length == 3
                {
                    :version => parsed[1],
                    :arch => parsed[2],
                    # pacman can handle its own dependencies!
                    :dependents => [],
                }
            end
        end
    end

    def self.installed_info name
        Chef::Log.debug("Checking pacman for #{name}")
        parsed = Package.shell("pacman -Qi '#{name}'").match(@@version_arch_re)
        if parsed && parsed.length == 3
            {
                :version => parsed[1],
                :arch => parsed[2],
            }
        else
            false
        end
    end
end

class AurDeps
    include TSort

    def initialize package
        @package = package
        @deps = build_dag @package
    end

    def tsort_each_node &block
        @deps.each_key(&block)
    end

    def tsort_each_child name, &block
        @deps[name].each(&block)
    end

    def build_dag source
        deps = {}
        queue = [source]
        while not queue.empty?
            package = queue.shift
            dependents = package.dependents.map do |dependent|
                found = Package.shell("pacman -Si #{dependent}").length != 0
                if !found
                    out = Package.shell("pacman -Ssq '^#{dependent}$'")
                    providers = out.split "\n"
                    if providers.length != 0
                        # TODO: Support muliple providers
                        dependent = providers[0]
                        found = true
                    end
                end
                Package.new dependent, !found
            end
            deps[package] = dependents
            queue += dependents
        end
        deps
    end

    def to_s
        printed = {}
        @deps.keys.each do |key|
            printed[key.to_s] = @deps[key].map { |p| p.to_s }
        end
        printed
    end

    def ordered
        tsort
    end
end
