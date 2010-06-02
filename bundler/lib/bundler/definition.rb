require "digest/sha1"

# TODO: In the 0.10 release, there shouldn't be a locked subclass of Definition
module Bundler
  class Definition
    attr_reader :dependencies, :sources, :platforms

    def self.build(gemfile, lockfile)
      gemfile = Pathname.new(gemfile).expand_path

      unless gemfile.file?
        raise GemfileNotFound, "#{gemfile} not found"
      end

      # TODO: move this back into DSL
      builder = Dsl.new
      builder.instance_eval(File.read(gemfile.to_s), gemfile.to_s, 1)
      builder.to_definition(lockfile)
    end

=begin
    How does the new system work?
    ===
    * Load information from Gemfile and Lockfile
    * Invalidate stale locked specs
      * All specs from stale source are stale
      * All specs that are reachable only through a stale
        dependency are stale.
    * If all fresh dependencies are satisfied by the locked
      specs, then we can try to resolve locally.
=end

    def initialize(lockfile, dependencies, sources)
      @dependencies, @sources, @unlock = dependencies, sources, []

      if lockfile && File.exists?(lockfile)
        locked = LockfileParser.new(File.read(lockfile))
        @platforms      = locked.platforms
        @locked_deps    = locked.dependencies
        @locked_specs   = SpecSet.new(locked.specs)
        @locked_sources = locked.sources
      else
        @platforms      = []
        @locked_deps    = []
        @locked_specs   = SpecSet.new([])
        @locked_sources = []
      end

      converge
    end

    def unlock!(what_to_unlock)
      raise "Specs already loaded" if @specs

      # Set the gems to unlock
      @unlock.concat(what_to_unlock[:gems])
      # Find the gems associated with specific sources and unlock them
      what_to_unlock[:sources].each do |source_name|
        source = sources.find { |s| s.name == source_name }
        source.unlock! if source.respond_to?(:unlock!)

        # Add all the spec names that are part of the source to unlock
        @unlock.concat @locked_specs.
          select { |s| s.source == source }.
          map    { |s| s.name }

        # Remove duplicate spec names
        @unlock.uniq!
      end
    end

    def resolve_remotely!
      raise "Specs already loaded" if @specs
      @specs = resolve_remote_specs
    end

    def specs
      @specs ||= resolve(:local_specs, index)
    end

    def index
      @index ||= Index.build do |idx|
        sources.each do |s|
          idx.use s.local_specs
        end
      end
    end

    def remote_index
      @remote_index ||= Index.build do |idx|
        sources.each { |source| idx.use source.specs }
      end
    end

    def no_sources?
      sources.length == 1 && sources.first.remotes.empty?
    end

    def groups
      dependencies.map { |d| d.groups }.flatten.uniq
    end

    def to_lock
      out = ""

      sorted_sources.each do |source|
        # Add the source header
        out << source.to_lock
        # Find all specs for this source
        specs.
          select  { |s| s.source == source }.
          sort_by { |s| s.name }.
          each do |spec|
            out << spec.to_lock
        end
        out << "\n"
      end

      out << "PLATFORMS\n"

      # Add the current platform
      platforms = @platforms.dup
      platforms << Gem::Platform.local unless @platforms.any? do |p|
        p == Gem::Platform.local
      end

      platforms.map { |p| p.to_s }.sort.each do |p|
        out << "  #{p}\n"
      end

      out << "\n"
      out << "DEPENDENCIES\n"

      dependencies.
        sort_by { |d| d.name }.
        each do |dep|
          out << dep.to_lock
      end

      out
    end

  private

    def converge
      common = @locked_sources & @sources
      fresh  = @sources - common
      # stale  = @locked_sources - common

      @sources = common + fresh

      @locked_specs.each do |s|
        if source = @sources.find { |source| s.source == source }
          s.source = source
        else
          @unlock << s.name
        end
      end

      @dependencies.each do |dep|
        if dep.source && source = @sources.find { |s| dep.source == s }
          dep.source == source
        end
      end
    end

    def sorted_sources
      sources.sort_by do |s|
        # Place GEM at the top
        [ s.is_a?(Source::Rubygems) ? 1 : 0, s.to_s ]
      end
    end

    # We have the dependencies from Gemfile.lock and the dependencies from the
    # Gemfile. Here, we are finding a list of all dependencies that were
    # originally present in the Gemfile that still satisfy the requirements
    # of the dependencies in the Gemfile.lock
    #
    # This allows us to add on the *new* requirements in the Gemfile and make
    # sure that the changes result in a conservative update to the Gemfile.lock.
    def locked_specs
      deps = []

      @dependencies.each do |dep|
        if in_locked_deps?(dep) || satisfies_locked_spec?(dep)
          deps << dep
        end
      end

      @locked_specs.for(deps, @unlock)
    end

    def in_locked_deps?(dep)
      @locked_deps.any? do |d|
        dep == d && dep.source == d.source
      end
    end

    def satisfies_locked_spec?(dep)
      @locked_specs.any? { |s| s.satisfies?(dep) }
    end

    def resolve(type, idx)
      source_requirements = {}
      dependencies.each do |dep|
        next unless dep.source
        source_requirements[dep.name] = dep.source.send(type)
      end

      # Run a resolve against the locally available gems
      specs = Resolver.resolve(dependencies, idx, source_requirements, locked_specs)
      specs.__materialize__ do |spec|
        spec.__materialize__(spec.source.send(type))
      end
      specs
    end

    # TODO: Improve this logic
    def resolve_remote_specs
      locked_specs.for(dependencies) # Will raise on fail
      specs
    rescue #InvalidSpecSet, GemNotFound, PathError
      resolve(:specs, remote_index)
    end

    def ambiguous?(dep)
      dep.requirement.requirements.any? { |op,_| op != '=' }
    end
  end
end
