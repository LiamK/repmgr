require resolv
include_recipe 'repmgr'
package 'rsync'

link '/usr/local/bin/pg_ctl' do
  to File.join(%x{pg_config --bindir}.strip, 'pg_ctl')
  not_if do
    File.exists?('/usr/local/bin/pg_ctl')
  end
end

if(node[:repmgr][:replication][:role] == 'master')
  # TODO: If changed master is detected should we force registration or
  #       leave that to be hand tuned?
  ruby_block 'kill run if master already exists!' do
    block do
      raise 'Different node is already identified as PostgreSQL master!'
    end
    only_if do
      output = %x{sudo -u postgres repmgr -f #{node[:repmgr][:config_file_path]} cluster show}
      master = output.split("\n").detect{|s| s.include?('master')}
      !master.to_s.empty? && !master.to_s.include?(node[:repmgr][:addressing][:self])
    end
  end

  execute 'register master node' do
    command "#{node[:repmgr][:repmgr_bin]} -f #{node[:repmgr][:config_file_path]} master register"
    user 'postgres'
    not_if do
      output = %x{sudo -u postgres #{node[:repmgr][:repmgr_bin]} -f #{node[:repmgr][:config_file_path]} cluster show}
      master = output.split("\n").detect{|s| s.include?('master')}
      master.to_s.include?(node[:repmgr][:addressing][:self])
    end
  end
else
  if Chef::Config[:solo]
    master_node = search(:node, 'name:master').first
    if master_node.nil?
      raise "Master node not found!"
    end
    unless (defined? master_node[:repmgr][:addressing][:self] and not
     master_node[:repmgr][:addressing][:self].empty?)
      raise "Master host address definition required."
    end
    master_addr = master_node[:repmgr][:addressing][:self]
    # Make sure we have a valid ip address, or resolvable host name
    begin
        Resolv.getaddress master_addr
    rescue
        raise "Invalid master host address: #{master_addr}"
    end

    # if these values are not set, then use some sensible defaults
    unless master_node[:repmgr][:replication][:keep_segments]
      master_node[:repmgr][:replication][:keep_segments] = 
        node[:repmgr][:replication][:keep_segments]
    end
    unless master_node[:postgresql][:config][:port]
      master_node[:postgresql][:config][:port] = 5432
    end
  else
    master_node = discovery_search(
      'replication_role:master',
      :raw_search => true,
      :environment_aware => node[:repmgr][:replication][:common_environment],
      :minimum_response_time_sec => false,
      :empty_ok => false
    )
  end

  unless(File.exists?(File.join(node[:postgresql][:config][:data_directory], 'recovery.conf')))
    # build our command in a string because it's long
    node.default[:repmgr][:addressing][:master] = master_node[:repmgr][:addressing][:self]
    clone_cmd = "#{node[:repmgr][:repmgr_bin]} " << 
      "-D #{node[:postgresql][:config][:data_directory]} " <<
      "-p #{node[:postgresql][:config][:port]} -U #{node[:repmgr][:replication][:user]} " <<
      "-R #{node[:repmgr][:system_user]} -d #{node[:repmgr][:replication][:database]} " <<
      "-w #{master_node[:repmgr][:replication][:keep_segments]} " << 
      "standby clone #{node[:repmgr][:addressing][:master]}"

    service 'postgresql-repmgr-stopper' do
      service_name 'postgresql'
      action :stop
    end

    execute 'ensure-halted-postgresql' do
      command "pkill postgres"
      ignore_failure true
    end

    directory 'scrub postgresql data directory' do
      action :delete
      recursive true
      path node[:postgresql][:config][:data_directory]
      only_if do
        File.directory?(node[:postgresql][:config][:data_directory])
      end
    end

    execute 'clone standby' do
      user 'postgres'
      command clone_cmd
    end
    
    service 'postgresql-repmgr-starter' do
      service_name 'postgresql'
      action :start
      retries 2
    end

    service 'repmgrd-setup-start' do
      service_name 'repmgrd'
      action :start
    end
    
    ruby_block 'confirm slave status' do
      block do
        Chef::Log.fatal "Slaving failed. Unable to detect self as standby: #{node[:repmgr][:addressing][:self]}"
        Chef::Log.fatal "OUTPUT: #{%x{sudo -u postgres repmgr -f #{node[:repmgr][:config_file_path]} cluster show}}"
        recovery_file = File.join(node[:postgresql][:config][:data_directory], 'recovery.conf')
        if(File.exists?(recovery_file))
          FileUtils.rm recovery_file
        end
        raise 'Failed to properly setup slaving!'
      end
      not_if do
        output = %x{sudo -u postgres repmgr -f #{node[:repmgr][:config_file_path]} cluster show}
        output.split("\n").detect{|s| s.include?('standby') && s.include?(node[:repmgr][:addressing][:self])}
      end
      action :nothing
      subscribes :create, 'service[repmgrd-setup-start]', :immediately
      retries 20
      retry_delay 20
      # NOTE: We want to give lots of breathing room here for catchup
    end
    
  end

  # add recovery manage here

  template File.join(node[:postgresql][:config][:data_directory], 'recovery.conf') do
    source 'recovery.conf.erb'
    mode 0644
    owner 'postgres'
    group 'postgres'
    notifies :restart, 'service[postgresql]', :immediately
    variables(
      :master_info => {
        :host => node[:repmgr][:addressing][:master],
        :port => master_node[:postgresql][:config][:port],
        :user => node[:repmgr][:replication][:user],
        :application_name => node.name
      }
    )
  end

  link File.join(node[:postgresql][:config][:data_directory], 'repmgr.conf') do
    to node[:repmgr][:config_file_path]
    not_if do
      File.exists?(
        File.join(node[:postgresql][:config][:data_directory], 'repmgr.conf')
      )
    end
  end
  
  # ensure we are a witness
  # TODO: Need HA flag
=begin
  execute 'register as witness' do
    command 
  end
=end
end
