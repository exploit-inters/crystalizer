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
      code = Ruby2Ruby.new.process( ParseTree.new.process( ParseTree.new.parse_tree_for_method(klass, method_name)) ) rescue nil
      return nil unless code
      File.open(rb, 'w') do |file|
        file.write code
      end
      output = `ruby -c #{rb} 2>&1`
      File.delete rb
      if($?.exitstatus != 0)
        # unparsable ruby was generated
        puts "got bad code generation", klass, method_name, code
        return nil
      end
      assert klass.class.in? [Class, Module]
      code = "# temp file: autogenerated: #{ Time.now } for class #{klass} \n#{klass.class.to_s.downcase} #{klass}\n" +
      code +
      "\nend\n"
      if(want_just_rb)
        return code
      end
      File.open(rb, 'w')  do |out|
        out.write( code )
      end
      return Concretize.compile(rb, want_just_c) rescue nil # might not be compatible here
    end

    private
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
    public
    @@all_c = {}
    # pass in a class name instnace
    # like c_ify_class! ClassName
    # currently only cifys the singleton methods...
    def Concretize.c_ify_class! klass, add_to_string = nil
      Ruby2CExtension::Plugins::DirectSelfCall.allow_public_methods # we're concretizing, so public methods are ok
      # TODO test that this actually does something to the C code :)
      # LTODO class methods, singleton methods...sure! :)
      anything = false
      for ancestor in klass.ancestors
        if @@all_c[ancestor] # TODO test: if two descend from c_klass normal c_klass they both get all of normal's
          puts 'ignoring cached', ancestor
          next
        end
        success = false
        # TODO I think we might get the inheritance wrong if two ancestors define the same method
        # TODO take out private checks [but make things the right way in our C code ?]
        for method_name in ancestor.instance_methods(false)
          if(!add_to_string)
            success ||= Concretize.c_ify! ancestor, method_name
          else
            string = Concretize.c_ify!(ancestor, method_name, true)
            if(string)
              add_to_string << " " << string
              success = true
            end
          end
        end

        print klass.to_s + " has "
        if(!success)
          print "no "
          @@all_c[klass] = true
        end
        puts "ruby methods"
        anything ||= success

      end
      # ltodo if they share an ancestor with ruby, somehow cache that [huh? can we actually just skip it in that case, anyway? I guess not?]

      anything

    end

    # turn all classes' ruby methods into their C equivalents
    # deemed unstable as of yet :(
    def Concretize.concretize_all!
      all = []
      ObjectSpace.each_object(Class) {|c|
        worked = Concretize.c_ify_class!(c)
        all << c if worked
      }
      all
    end
  end

end

class Class
  def concretize!
    Concretize.c_ify_class! self
  end
end
