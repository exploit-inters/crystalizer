
require "rubynode"
require "rbconfig"
require 'sane'
require 'logger'
require 'require_all'
require_rel '.' 
require "rubynode"
require "rbconfig"
require "ruby2cext/parser"
require "ruby2cext/error"
require "ruby2cext/tools"
require "ruby2cext/c_function"
require "ruby2cext/version"
require_rel 'plugins' 
require 'sane'

module Ruby2CExtension

  class Compiler

    attr_reader :name, :logger, :plugins

    def initialize(name, logger = nil)
      @name = name
      @logger = logger
      @funs = []
      @funs_reuseable = {}
      @toplevel_funs = []
      @sym_man = Tools::SymbolManager.new
      @global_man = Tools::GlobalManager.new
      @uniq_names = Tools::UniqueNames.new
      @helpers = {}
      @plugins = []
      @preprocessors = {}
    end

    # plugins is {:optimizations => :all || [:name1, :name2]}, also {:warnings => true} or something 
    # logger if require 'logger'; Logger.new
    # include_paths = [] # dirs
    # only_c -- pass true if you just want the source, not compiled
    def Compiler.compile_file(file_name, plugins, include_paths, only_c, logger)
      bn = File.basename(file_name)
      unless bn =~ /\A(.*)\.rb\w?\z/
        raise "#{file_name} is no ruby file"
      end
      name = $1;
      unless name =~ /\A\w+\z/
        raise "'#{name}' is not a valid extension name"
      end
      file_name = File.join(File.dirname(file_name), bn)

      logger.info("reading #{file_name}")
      source_str = IO.read(file_name)

      logger.info("translating #{file_name} to C")
      c = Compiler.new(name, logger)
      unless include_paths.empty?
        plugins = plugins.merge({:require_include => [include_paths, [file_name]]})
      end
      logger.debug("plugins = #{plugins.inspect}")
      c.add_plugins(plugins)
      logger.debug("plugins used: #{c.plugins.map { |pi| pi.class }.inspect}")
      c.add_rb_file(source_str, file_name)
      c_code = c.to_c_code

      c_file_name = File.join(File.dirname(file_name), "#{name}.c")
      logger.info("writing #{c_file_name}")
      File.open(c_file_name, "w") { |f| f.puts(c_code) }

      if only_c
         c_code
      else
        logger.info("compiling #{c_file_name}")
        Compiler.compile_c_file_to_dllib(c_file_name, logger)
      end
    end




    def to_c_code(time_stamp = Time.now)
      plugins_global = @plugins.map { |plugin| plugin.global_c_code }
      plugins_init = @plugins.map { |plugin| plugin.init_c_code }
      res = [
        "/* generated by #{FULL_VERSION_STRING} on #{time_stamp} */",
        "#include <ruby.h>",
        "#include <node.h>",
        "#include <env.h>",
        "#include <st.h>",
        "extern VALUE ruby_top_self;",
        "static VALUE org_ruby_top_self;",
        @sym_man.to_c_code,
        @global_man.to_c_code,
      ]
      res.concat(@helpers.keys.sort)
      res.concat(plugins_global)
      res.concat(@funs)
      res << "void Init_#{@name}() {"
      res << "org_ruby_top_self = ruby_top_self;"
      # just to be sure
      res << "rb_global_variable(&org_ruby_top_self);"
      res << "init_syms();"
      res << "init_globals();"
      res << "NODE *cref = rb_node_newnode(NODE_CREF, rb_cObject, 0, 0);"
      res.concat(plugins_init)
      @toplevel_funs.each { |f| res << "#{f}(ruby_top_self, cref);" }
      res << "}"
      res.join("\n").split("\n").map { |l| l.strip }.reject { |l| l.empty? }.join("\n")
    end

    def add_toplevel(function_name)
      @toplevel_funs << function_name
    end

    # non destructive: node_tree will not be changed
    def compile_toplevel_function(node_tree, private_vmode = true)
      CFunction::ToplevelScope.compile(self, node_tree, private_vmode)
    end

    NODE_TRANSFORM_OPTIONS = {:include_node => true, :keep_newline_nodes => true}

    def rb_file_to_toplevel_functions(source_str, file_name)
      res = []
      hash = Parser.parse_string(source_str, file_name)
      # add all BEGIN blocks, if available
      if (beg_tree = hash[:begin])
        beg_tree = beg_tree.transform(NODE_TRANSFORM_OPTIONS)
        if beg_tree.first == :block
          beg_tree.last.each { |s| res << compile_toplevel_function(s, false) }
        else
          res << compile_toplevel_function(beg_tree, false)
        end
      end
      # add toplevel scope
      if (tree = hash[:tree])
        res << compile_toplevel_function(tree.transform(NODE_TRANSFORM_OPTIONS))
      end
      res
    end

    def add_rb_file(source_str, file_name)
      rb_file_to_toplevel_functions(source_str, file_name).each { |fn|
        add_toplevel(fn)
      }
    end

    # uniq name
    def un(str)
      @uniq_names.get(str)
    end
    def sym(sym)
      @sym_man.get(sym)
    end
    def global_const(str, register_gc = true)
      @global_man.get(str, true, register_gc)
    end
    def global_var(str)
      @global_man.get(str, false, true)
    end

    def log(str, warning = false)
      if logger
        if warning
          logger.warn(str)
        else
          logger.info(str)
        end
      end
    end

    def add_helper(str)
      @helpers[str] ||= true
    end

    def add_fun(code, base_name)
      unless (name = @funs_reuseable[code])
        name = un(base_name)
        lines = code.split("\n")
        unless lines.shift =~ /^\s*static / # first line needs static
          raise Ruby2CExtError::Bug, "trying to add a non static function"
        end
        if lines.grep(/^\s*static /).empty? # only reuseably without static variables
          @funs_reuseable[code] = name
        end
        unless code.sub!("FUNNAME", name)
          raise Ruby2CExtError::Bug, "trying to add a function without FUNNAME"
        end
        @funs << code
      end
      name
    end

    def add_plugin(plugin_class, *args)
      @plugins << plugin_class.new(self, *args)
    end

    def add_plugins(options)
      if options[:warnings]
        add_plugin(Plugins::Warnings)
      end
      if (opt = options[:optimizations])
        if opt == :all
          opt = {
            :const_cache=>true,
            :case_optimize=>true,
           # :direct_self_call=>true, # also buggy...
           # :inline_builtin=>true, # causes a bug [just itself, too]
            :cache_call=>true,
            :builtin_methods=>true,
            :inline_methods=>true,
            :ivar_cache=>true
          }
        end
        if opt[:const_cache]
          add_plugin(Plugins::ConstCache)
        end
        if opt[:case_optimize]
          add_plugin(Plugins::CaseOptimize)
        end
        if opt[:direct_self_call]
          add_plugin(Plugins::DirectSelfCall)
        end
        if opt[:inline_builtin]
          add_plugin(Plugins::InlineBuiltin)
        end
        if opt[:inline_methods]
          add_plugin(Plugins::InlineMethods)
        end
        if opt[:cache_call]
          add_plugin(Plugins::CacheCall)
        end
        if (builtins = opt[:builtin_methods])
          if Array === builtins
            builtins = builtins.map { |b| b.to_s.to_sym } # allow symbols, strings and the actual classes to work
          else
            builtins = Plugins::BuiltinMethods::SUPPORTED_BUILTINS
          end
          add_plugin(Plugins::BuiltinMethods, builtins)
        end
        if opt[:ivar_cache]
          add_plugin(Plugins::IVarCache)
        end
      end
      if (ri_args = options[:require_include])
        unless Array === ri_args.first
          ri_args = [ri_args] # to allow just an array of include paths to also work
        end
        add_plugin(Plugins::RequireInclude, *ri_args)
      end
    end

    # preprocessors can be added by plugins. preprocessors are procs that
    # take two arguments: the current cfun and the node (tree) to
    # preprocess (which will have type node_type)
    #
    # The proc can either return a (modified) node (tree) or string. If a
    # node (tree) is returned then that will be translated as usual, if a
    # string is returned, that string will be the result
    #
    # Example, a preprocessor that replaces 23 with 42:
    # add_preprocessor(:lit) { |cfun, node|
    #   node.last[:lit] == 23 ? [:lit, {:lit=>42}] : node
    # }
    #
    # Another way to do the same:
    # add_preprocessor(:lit) { |cfun, node|
    #   node.last[:lit] == 23 ? cfun.comp_lit(:lit=>42) : node
    # }
    #
    # If multiple preprocessors are added for the same node type then they
    # will be called after each other with the result of the previous one
    # unless it is a string, then the following preprocessors are ignored
    def add_preprocessor(node_type, &pp_proc)
      (@preprocessors[node_type] ||= []) << pp_proc
    end

    def preprocessors_for(node_type)
      @preprocessors[node_type]
    end

    conf = ::Config::CONFIG
    cflags = [conf["CCDLFLAGS"], conf["CFLAGS"], conf["ARCH_FLAG"]].join(" ")
    COMPILE_COMMAND = "#{conf["LDSHARED"]} #{cflags} -I . -I #{conf["archdir"]} " # added -c
    DLEXT = conf["DLEXT"]

    # compiles a C file using the compiler from rbconfig
    def self.compile_c_file_to_dllib(c_file_name, logger = nil)
      conf = ::Config::CONFIG
      unless c_file_name =~ /\.c\z/
        raise Ruby2CExtError, "#{c_file_name} is no C file"
      end
      dl_name = c_file_name.sub(/c\z/, DLEXT)
      cmd = "#{COMPILE_COMMAND} -o #{dl_name} #{c_file_name}"
      if RUBY_PLATFORM =~ /mswin32/
        cmd << " -link /INCREMENTAL:no /EXPORT:Init_#{File.basename(c_file_name, ".c")}"
      end
      if RUBY_PLATFORM =~ /mingw/
        cmd << " #{ conf['DLDFLAGS'] } #{ conf['SOLIBS'] }  "
        cmd << " -L#{ conf['libdir'] } #{ conf["LIBRUBYARG_SHARED"] } "
      end
      logger.info(cmd) if logger

      unless system(cmd) # run it
        raise Ruby2CExtError, "error while executing '#{cmd}' #{`cmd`}"
      end
      dl_name
    end

  end

end
