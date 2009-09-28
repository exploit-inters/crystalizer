require 'rubygems'
require 'ruby2ruby'
require 'parse_tree'
require 'thread'
# LTODO singleton methods, class methods, [procs?]

module Ruby2CExtension

	class Concretize
	  @@count = 0
	  @@mutex = Mutex.new
	  def Concretize.c_ify! klass, method_name, want_just_rb = false, want_just_c = false
	    count = @@mutex.synchronize { @@count += 1 }
	    rb = "temp_#{count}.rb"
	    code = Ruby2Ruby.new.process( ParseTree.new.parse_tree_for_method(klass, method_name) ) rescue nil
	    return nil unless code
	    code = "# temp file: autogenerated: #{ Time.now } for class #{klass} \nclass #{klass}\n" +
	           code + 
	           "\nend\n"
  	  if(want_just_rb)
  	      return code
  	  end
	    File.open(rb, 'w')  do |out|
  	   out.write( code )
  	  end
  	  return Concretize.compile(rb, want_just_c)
  	end
  	 
  	def Concretize.compile(rb, want_just_c)
      Compiler.compile_file(rb, {:optimizations => :all}, [], false, Logger.new( STDOUT ) )
      c_file = rb[0..-4] + '.c'
      so_file = rb[0..-4] + '.so'

      if(want_just_c)
        return File.read(c_file)
      end
      # LTODO make it multi process friendly, too :)
      require so_file
	  end
	  
	  # pass in a class name instnace
	  # like c_ify_class! ClassName
	  # currently only cifys the singleton methods...
	  def Concretize.c_ify_class! klass, add_to_string = nil
       Ruby2CExtension::Plugins::DirectSelfCall.allow_public_methods # we're concretizing, so public methods are ok
       # TODO test that this actually does something to the C code :)
       success = false
       # LTODO class methods, singleton methods...sure! :)
	    for method_name in klass.instance_methods
	         if(!add_to_string)
  	        success ||= Concretize.c_ify! klass, method_name
  	       else
  	        string = Concretize.c_ify!(klass, method_name, true)
  	        if(string)
    	        add_to_string << " " << string
    	        success = true
    	      end
  	       end
  	   end
	    if(!success)
	      puts klass.to_s + " is totally c"
	    end
	    return success
	  end
	  
	  # turn all classes' ruby methods into their C equivalents
	  # deemed unstable as of yet :(
	  def Concretize.concretize_all!
    	  all = []
    	  ruby = ''
  	    ObjectSpace.each_object(Class) {|c| 
  	      worked = Concretize.c_ify_class!(c, ruby)
  	      all << c if worked 
	      }
  	    puts "BEGIN ALL.RB", ruby, "END"
  	    File.write 'all.rb', ruby
  	    require '_dbg'
        Concretize.compile('all.rb', false)
  	    all
	  end
	end
	
end

class Class
 def concretize!
   Concretize.c_ify_class! self
 end
end