
require "rubynode"
require "ruby2cext/parser"
require "ruby2cext/error"
require "ruby2cext/tools"
require "ruby2cext/c_function"

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

		def to_c_code
			plugins_global = @plugins.map { |plugin| plugin.global_c_code }
			plugins_init = @plugins.map { |plugin| plugin.init_c_code }
			res = [
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
				require "ruby2cext/plugins/warnings"
				add_plugin(Plugins::Warnings)
			end
			if (opt = options[:optimizations])
				if opt == :all
					opt = {
						:const_cache=>true, :case_optimize=>true,
						:builtin_methods=>true, :inline_methods=>true
					}
				end
				if opt[:const_cache]
					require "ruby2cext/plugins/const_cache"
					add_plugin(Plugins::ConstCache)
				end
				if opt[:case_optimize]
					require "ruby2cext/plugins/case_optimize"
					add_plugin(Plugins::CaseOptimize)
				end
				if opt[:inline_methods]
					require "ruby2cext/plugins/inline_methods"
					add_plugin(Plugins::InlineMethods)
				end
				if (builtins = opt[:builtin_methods])
					require "ruby2cext/plugins/builtin_methods"
					if Array === builtins
						builtins = builtins.map { |b| b.to_s.to_sym } # allow symbols, strings and the actual classes to work
					else
						builtins = Plugins::BuiltinMethods::SUPPORTED_BUILTINS
					end
					add_plugin(Plugins::BuiltinMethods, builtins)
				end
			end
			if options[:require_include]
				require "ruby2cext/plugins/require_include"
				add_plugin(Plugins::RequireInclude, *options[:require_include])
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

		# compiles a C file using the compiler from rbconfig
		def self.compile_c_file_to_dllib(c_file_name, logger = nil)
			unless c_file_name =~ /\.c\z/
				raise Ruby2CExtError, "#{c_file_name} is no C file"
			end
			require "rbconfig"
			conf = ::Config::CONFIG
			ldshared = conf["LDSHARED"]
			cflags = [conf["CCDLFLAGS"], conf["CFLAGS"], conf["ARCH_FLAG"]].join(" ")
			hdrdir = conf["archdir"]
			dlext = conf["DLEXT"]
			dl_name = c_file_name.sub(/c\z/, dlext)
			cmd = "#{ldshared} #{cflags} -I. -I #{hdrdir} -o #{dl_name} #{c_file_name}"
			if RUBY_PLATFORM =~ /mswin32/
				cmd << " -link /INCREMENTAL:no /EXPORT:Init_#{File.basename(c_file_name, ".c")}"
			end
			logger.info(cmd) if logger
			unless system(cmd) # run it
				raise Ruby2CExtError, "error while executing '#{cmd}'"
			end
			dl_name
		end

	end

end
