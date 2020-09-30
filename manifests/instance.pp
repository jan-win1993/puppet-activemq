# @summary Create an instance of ActiveMQ Artemis broker
#
# @param address_settings
#   A hash containing global address settings. This is especially useful
#   for wildcard/catch all matches.
#
# @param addresses
#   A hash containing configuration for addresses (messaging endpoints),
#   queues and routing types.
#
# @param bind
#   Configure which IP address to listen on. Should be either a FQDN
#   or an IP address.
#
# @param broker_plugins
#   A Hash containing a list of broker plugins and their configuration.
#   Each plugin can be enabled by setting `enable` to `true`.
#
# @param log_level
#   The log levels to use for the various configured loggers.
#
# @param service_enable
#   Specifies whether the service should be enabled for this instance.
#
# @param service_ensure
#   Specifies the desired service state for this instance.
#
# @param target_host
#   Specifies the target host where this instance should be installed.
#   The value will be matched against `$facts['networking']['fqdn']`.
#   This is especially useful for cluster configurations.
#
# @param web_bind
#   The host name to use for embedded web server.
#
# @param web_port
#   The port to use for embedded web server.
#
define activemq::instance (
  Hash[String[1], Hash] $acceptors,
  Array $acceptor_settings,
  Array $address_settings,
  Hash[String[1], Hash] $addresses,
  Boolean $allow_failback,
  String $bind,
  Array $broadcast_groups,
  Hash[String[1], Hash] $broker_plugins,
  Boolean $check_for_live_server,
  Hash[String[1], Hash] $connectors,
  Array $discovery_groups,
  Boolean $failover_on_shutdown,
  Enum['live-only','replication','shared-storage'] $ha_policy,
  Integer $initial_replication_sync_timeout,
  Integer $journal_buffer_timeout,
  Boolean $journal_datasync,
  Integer $journal_max_io,
  Enum['asyncio','mapped','nio'] $journal_type,
  Hash $log_level,
  Integer $max_disk_usage,
  Integer $max_hops,
  Enum['off','strict','on_demand'] $message_load_balancing,
  Boolean $persistence,
  Integer $port,
  Enum['master','slave'] $role,
  Boolean $vote_on_replication_failure,
  String $web_bind,
  Integer $web_port,
  # Optional parameters
  Optional[Integer] $global_max_size_mb = undef,
  Optional[String] $group = undef,
  Optional[Boolean] $service_enable = undef,
  Optional[Enum['running','stopped']] $service_ensure = undef,
  Optional[String] $target_host = undef,
  # TODO: broker-plugins (nothing set by default, but it should be supported)
) {
  File {
    owner => $activemq::user,
    group => $activemq::group,
  }

  # Check if this instance should be installed on this host.
  if (empty($target_host) or ($target_host == $facts['networking']['fqdn'])) {

    # Construct paths and filenames for this insance.
    $instance_dir = "${activemq::instances_base}/${name}"
    $bootstrap_xml = "${instance_dir}/etc/bootstrap.xml"
    $broker_xml = "${instance_dir}/etc/broker.xml"
    $logging_properties = "${instance_dir}/etc/logging.properties"
    $instance_service = "${activemq::service_name}@${name}"
    $installer_cmd = "${activemq::install_base}/${activemq::symlink_name}/bin/artemis"

    # Command to create new instances.
    # NOTE: We pass all parameters, although we will replace the configuration
    # in a later step anways. We do this to validate whether or not these options
    # are still supported in the selected release of ActiveMQ Artemis. The
    # installer will fail on unsupported options.
    $create_command = join([
      $installer_cmd,
      'create',
      $instance_dir,
      '--aio',
      '--autocreate',
      '--clustered',
      '--replicated',
      "--cluster-user \'${activemq::cluster_user}\'",
      "--cluster-password \'${activemq::cluster_password}\'",
      "--name ${name}",
      "--host ${bind}",
      '--require-login',
      "--user \'${activemq::admin_user}\'",
      "--password \'${activemq::admin_password}\'",
    ], ' ')

    # Run installer to create a new instance
    exec { "create instance ${name}" :
      user    => $activemq::user,
      group   => $activemq::group,
      path    => '/usr/bin:/bin:/usr/local/bin:/usr/sbin:/sbin:/usr/local/sbin',
      cwd     => $activemq::instances_base,
      # Run this exec only if no old instance can be found.
      unless  => "test -d \'${instance_dir}\'",
      command => $create_command,
      # Run this exec only if installer can be found.
      onlyif  => "test -f \'${installer_cmd}\'",
      require => [
        Class['activemq::install'],
      ],
      notify  => [
        Service[$instance_service],
      ],
    }

    # Iterate over all acceptors to validate and update their configuration.
    # This keeps this complexity away from the templates.
    $_acceptors = $acceptors.reduce({}) |$memo, $x| {
      # A nested hash contains the configuration.
      if ($x[1] =~ Hash) {
        # Fail if basic information is missing.
        if ( !('port' in $x[1]) or !('protocols' in $x[1]) ) {
          fail("Invalid \$acceptors configuration, no value for \$port or \$protocols in acceptor ${x[0]} for instance ${name}.")
        }

        # Ensure that all protocol names use uppercase letters.
        $_protocols = $x[1]['protocols'].reduce([]) |$m, $y| {
          $m + [upcase($y)]
        }

        # Generate a comma separated list of acceptor protocols.
        $_protocols_list = join($_protocols, ',')

        # Check if general "acceptor_settings" option can be found.
        if ( 'acceptor_settings' in $x[1] ) {
          # Merge more specific 'settings' with general 'acceptor_settings'.
          if ( 'settings' in $x[1] ) {
            $_settings = $x[1]['settings'] + $x[1]['acceptor_settings']
          } else {
            $_settings = $x[1]['acceptor_settings']
          }
        } else {
          # No "acceptor_settings", only use 'settings' if available.
          if ( 'settings' in $x[1] ) {
            $_settings = $x[1]['settings']
          } else {
            $_settings = []
          }
        }

        # Generate a semicolon separated list of acceptor settings.
        $_settings_list = join($_settings, ';')

        # Finally merge with all other options.
        $_values = $x[1].deep_merge(
          {
            'protocols_list' => $_protocols_list,
            'settings' => $_settings,
            'settings_list' => $_settings_list,
          }
        )
      } else {
        fail("Invalid \$acceptors configuration, expected a Hash but got something else in acceptor ${x[0]} for instance ${name}.")
      }
      $memo + {$x[0] => $_values}
    }

    # Iterate over all broker plugins. Only enabled plugins will be passed
    # to the template.
    $_broker_plugins = $broker_plugins.reduce({}) |$memo, $x| {
      # A nested hash contains the configuration.
      if ($x[1] =~ Hash) {
        # Fail if basic information is missing.
        if (!('enable' in $x[1]) or !($x[1]['enable'] =~ Boolean)) {
          fail("Invalid \$broker_plugins configuration, invalid or missing value for \$enable in plugin ${x[0]} for instance ${name}.")
        }
        if ($x[1]['enable'] == true) {
          $memo + {$x[0] => $x[1]}
        }
      } else {
        fail("Invalid \$broker_plugins configuration, expected a Hash but got something else in plugin ${x[0]} for instance ${name}.")
      }
    }

    # Create broker.xml configuration file.
    file { "instance ${name} broker.xml":
      ensure  => 'present',
      path    => $broker_xml,
      mode    => '0640',
      content => epp($activemq::broker_template,{
        'acceptors'                        => $_acceptors,
        'address_settings'                 => $address_settings,
        'addresses'                        => $addresses,
        'allow_failback'                   => $allow_failback,
        'bind'                             => $bind,
        'broadcast_groups'                 => $broadcast_groups,
        'broker_plugins'                   => $_broker_plugins,
        'check_for_live_server'            => $check_for_live_server,
        'connectors'                       => $connectors,
        'discovery_groups'                 => $discovery_groups,
        'failover_on_shutdown'             => $failover_on_shutdown,
        'global_max_size_mb'               => $global_max_size_mb,
        'group'                            => $group,
        'ha_policy'                        => $ha_policy,
        'initial_replication_sync_timeout' => $initial_replication_sync_timeout,
        'journal_buffer_timeout'           => $journal_buffer_timeout,
        'journal_datasync'                 => $journal_datasync,
        'journal_max_io'                   => $journal_max_io,
        'journal_type'                     => upcase($journal_type),
        'name'                             => $name,
        'max_disk_usage'                   => $max_disk_usage,
        'max_hops'                         => $max_hops,
        'message_load_balancing'           => upcase($message_load_balancing),
        'persistence'                      => $persistence,
        'port'                             => $port,
        'role'                             => $role,
        'vote_on_replication_failure'      => $vote_on_replication_failure,
        }
      ),
      require => [
        Exec["create instance ${name}"]
      ],
    }

    # Create bootstrap.xml configuration file.
    file { "instance ${name} bootstrap.xml":
      ensure  => 'present',
      path    => $bootstrap_xml,
      mode    => '0644',
      content => epp($activemq::bootstrap_template,{
        'broker_xml' => $broker_xml,
        'web_bind'   => $web_bind,
        'web_port'   => $web_port,
        }
      ),
      require => [
        Exec["create instance ${name}"]
      ],
    }

    # Create logging.properties configuration file.
    file { "instance ${name} logging.properties":
      ensure  => 'present',
      path    => $logging_properties,
      mode    => '0644',
      content => epp($activemq::logging_template,{
        'log_level' => $log_level,
        }
      ),
      require => [
        Exec["create instance ${name}"]
      ],
    }

    # Check if service should be enabled.
    $_service_enable = $service_enable ? {
      undef   => $activemq::service_enable,
      default => $service_enable,
    }
    $_service_ensure = $service_ensure ? {
      undef   => $activemq::service_ensure,
      default => $service_ensure,
    }

    # Configure service for this instance.
    service { $instance_service:
      ensure    => $_service_ensure,
      enable    => $_service_enable,
      subscribe => [
        Class['activemq::install'],
        File["instance ${name} broker.xml"],
      ],
      require   => [
        File["instance ${name} broker.xml"],
      ],
    }

    # TODO: Upgrade an instance
  }
}
