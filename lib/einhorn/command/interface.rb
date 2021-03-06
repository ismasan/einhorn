require 'tmpdir'
require 'socket'

module Einhorn::Command
  module Interface
    @@commands = {}
    @@command_server = nil

    def self.command_server=(server)
      raise "Command server already set" if @@command_server && server
      @@command_server = server
    end

    def self.command_server
      @@command_server
    end

    def self.init
      install_handlers
      at_exit do
        if Einhorn::TransientState.whatami == :master
          to_remove = [pidfile]
          # Don't nuke socket_path if we never successfully acquired it
          to_remove << socket_path if @@command_server
          to_remove.each do |file|
            begin
              File.unlink(file)
            rescue Errno::ENOENT
            end
          end
        end
      end
    end

    def self.persistent_init
      socket = open_command_socket
      Einhorn::Event::CommandServer.open(socket)

      # Could also rewrite this on reload. Might be useful in case
      # someone goes and accidentally clobbers/deletes. Should make
      # sure that the clobber is atomic if we we were do do that.
      write_pidfile
    end

    def self.open_command_socket
      path = socket_path

      with_file_lock do
        # Need to avoid time-of-check to time-of-use bugs in blowing
        # away and recreating the old socketfile.
        destroy_old_command_socket(path)
        UNIXServer.new(path)
      end
    end

    # Lock against other Einhorn workers. Unfortunately, have to leave
    # this lockfile lying around forever.
    def self.with_file_lock(&blk)
      path = lockfile
      File.open(path, 'w', 0600) do |f|
        unless f.flock(File::LOCK_EX|File::LOCK_NB)
          raise "File lock already acquired by another Einhorn process. This likely indicates you tried to run Einhorn masters with the same cmd_name at the same time. This is a pretty rare race condition."
        end

        blk.call
      end
    end

    def self.destroy_old_command_socket(path)
      # Socket isn't actually owned by anyone
      begin
        sock = UNIXSocket.new(path)
      rescue Errno::ECONNREFUSED
        # This happens with non-socket files and when the listening
        # end of a socket has exited.
      rescue Errno::ENOENT
        # Socket doesn't exist
        return
      else
        # Rats, it's still active
        sock.close
        raise Errno::EADDRINUSE.new("Another process (probably another Einhorn) is listening on the Einhorn command socket at #{path}. If you'd like to run this Einhorn as well, pass a `-d PATH_TO_SOCKET` to change the command socket location.")
      end

      # Socket should still exist, so don't need to handle error.
      stat = File.stat(path)
      unless stat.socket?
        raise Errno::EADDRINUSE.new("Non-socket file present at Einhorn command socket path #{path}. Either remove that file and restart Einhorn, or pass a `-d PATH_TO_SOCKET` to change the command socket location.")
      end

      Einhorn.log_info("Blowing away old Einhorn command socket at #{path}. This likely indicates a previous Einhorn worker which exited uncleanly.")
      # Whee, blow it away.
      File.unlink(path)
    end

    def self.write_pidfile
      file = pidfile
      Einhorn.log_info("Writing PID to #{file}")
      File.open(file, 'w') {|f| f.write($$)}
    end

    def self.uninit
      remove_handlers
    end

    def self.socket_path
      Einhorn::State.socket_path || default_socket_path
    end

    def self.default_socket_path(cmd_name=nil)
      cmd_name ||= Einhorn::State.cmd_name
      if cmd_name
        filename = "einhorn-#{cmd_name}.sock"
      else
        filename = "einhorn.sock"
      end
      File.join(Dir.tmpdir, filename)
    end

    def self.lockfile
      Einhorn::State.lockfile || default_lockfile_path
    end

    def self.default_lockfile_path(cmd_name=nil)
      cmd_name ||= Einhorn::State.cmd_name
      if cmd_name
        filename = "einhorn-#{cmd_name}.lock"
      else
        filename = "einhorn.lock"
      end
      File.join(Dir.tmpdir, filename)
    end

    def self.pidfile
      Einhorn::State.pidfile || default_pidfile
    end

    def self.default_pidfile(cmd_name=nil)
      cmd_name ||= Einhorn::State.cmd_name
      if cmd_name
        filename = "einhorn-#{cmd_name}.pid"
      else
        filename = "einhorn.pid"
      end
      File.join(Dir.tmpdir, filename)
    end

    ## Signals
    def self.install_handlers
      Signal.trap("INT") do
        Einhorn::Command.signal_all("USR2", Einhorn::State.children.keys)
        Einhorn::State.respawn = false
      end
      Signal.trap("TERM") do
        Einhorn::Command.signal_all("TERM", Einhorn::State.children.keys)
        Einhorn::State.respawn = false
      end
      # Note that quit is a bit different, in that it will actually
      # make Einhorn quit without waiting for children to exit.
      Signal.trap("QUIT") do
        Einhorn::Command.signal_all("QUIT", Einhorn::State.children.keys)
        Einhorn::State.respawn = false
        exit(1)
      end
      Signal.trap("HUP") {Einhorn::Command.reload}
      Signal.trap("ALRM") {Einhorn::Command.full_upgrade}
      Signal.trap("CHLD") {Einhorn::Event.break_loop}
      Signal.trap("USR2") do
        Einhorn::Command.signal_all("USR2", Einhorn::State.children.keys)
        Einhorn::State.respawn = false
      end
      at_exit do
        if Einhorn::State.kill_children_on_exit && Einhorn::TransientState.whatami == :master
          Einhorn::Command.signal_all("USR2", Einhorn::State.children.keys)
          Einhorn::State.respawn = false
        end
      end
    end

    def self.remove_handlers
      %w{INT TERM QUIT HUP ALRM CHLD USR2}.each do |signal|
        Signal.trap(signal, "DEFAULT")
      end
    end

    ## Commands
    def self.command(name, description=nil, &code)
      @@commands[name] = {:description => description, :code => code}
    end

    def self.process_command(conn, command)
      response = generate_response(conn, command)
      if !response.nil?
        send_message(conn, response)
      else
        conn.log_debug("Got back nil response, so not responding to command.")
      end
    end

    def self.send_message(conn, response)
      if response.kind_of?(String)
        response = {'message' => response}
      end
      message = pack_message(response)
      conn.write(message)
    end

    def self.generate_response(conn, command)
      begin
        request = JSON.parse(command)
      rescue JSON::ParserError => e
        return {
          'message' => "Could not parse command: #{e}"
        }
      end

      unless command_name = request['command']
        return {
          'message' => 'No "command" parameter provided; not sure what you want me to do.'
        }
      end

      if command_spec = @@commands[command_name]
        conn.log_debug("Received command: #{command.inspect}")
        begin
          return command_spec[:code].call(conn, request)
        rescue StandardError => e
          msg = "Error while processing command #{command_name.inspect}: #{e} (#{e.class})\n  #{e.backtrace.join("\n  ")}"
          conn.log_error(msg)
          return msg
        end
      else
        conn.log_debug("Received unrecognized command: #{command.inspect}")
        return unrecognized_command(conn, request)
      end
    end

    def self.pack_message(message_struct)
      begin
        JSON.generate(message_struct) + "\n"
      rescue JSON::GeneratorError => e
        response = {
          'message' => "Error generating JSON message for #{message_struct.inspect} (this indicates a bug): #{e}"
        }
        JSON.generate(response) + "\n"
      end
    end

    def self.command_descriptions
      command_specs = @@commands.select do |_, spec|
        spec[:description]
      end.sort_by {|name, _| name}

      command_specs.map do |name, spec|
        "#{name}: #{spec[:description]}"
      end.join("\n")
    end

    def self.unrecognized_command(conn, request)
      <<EOF
Unrecognized command: #{request['command'].inspect}

#{command_descriptions}
EOF
    end

    # Used by workers
    command 'worker:ack' do |conn, request|
      if pid = request['pid']
        Einhorn::Command.register_manual_ack(pid)
      else
        conn.log_error("Invalid request (no pid): #{request.inspect}")
      end
      # Throw away this connection in case the application forgets to
      conn.close
      nil
    end

    # Used by einhornsh
    command 'ehlo' do |conn, request|
      <<EOF
Welcome #{request['user']}! You are speaking to Einhorn Master Process #{$$}#{Einhorn::State.cmd_name ? " (#{Einhorn::State.cmd_name})" : ''}
EOF
    end

    command 'help', 'Print out available commands' do
"You are speaking to the Einhorn command socket. You can run the following commands:

#{command_descriptions}
"
    end

    command 'state', "Get a dump of Einhorn's current state" do
      Einhorn::Command.dumpable_state.pretty_inspect
    end

    command 'reload', 'Reload Einhorn' do |conn, _|
      # TODO: make reload actually work (command socket reopening is
      # an issue). Would also be nice if user got a confirmation that
      # the reload completed, though that's not strictly necessary.

      # In the normal case, this will do a write
      # synchronously. Otherwise, the bytes will be stuck into the
      # buffer and lost upon reload.
      send_message(conn, 'Reloading, as commanded')
      Einhorn::Command.reload

      # Reload should not return
      raise "Not reachable"
    end

    command 'inc', 'Increment the number of Einhorn child processes' do
      Einhorn::Command.increment
    end

    command 'dec', 'Decrement the number of Einhorn child processes' do
      Einhorn::Command.decrement
    end

    command 'quieter', 'Decrease verbosity' do
      Einhorn::Command.quieter
    end

    command 'louder', 'Increase verbosity' do
      Einhorn::Command.louder
    end

    command 'upgrade', 'Upgrade all Einhorn workers. This may result in Einhorn reloading its own code as well.' do |conn, _|
      # TODO: send confirmation when this is done
      send_message(conn, 'Upgrading, as commanded')
      # This or may not return
      Einhorn::Command.full_upgrade
      nil
    end
  end
end
