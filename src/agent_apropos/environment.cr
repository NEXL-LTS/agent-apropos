module AgentApropos
  abstract class Environment
    abstract def which(command : String) : String?

    abstract def run_capture(command : String, args : Array(String)) : String?

    class Real < Environment
      def which(command : String) : String?
        Process.find_executable(command)
      end

      def run_capture(command : String, args : Array(String)) : String?
        stdout = IO::Memory.new
        status = Process.run(command, args, output: stdout, error: Process::Redirect::Close)
        status.success? ? stdout.to_s : nil
      rescue
        nil
      end
    end
  end
end
