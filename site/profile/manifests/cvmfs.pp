class profile::cvmfs::install {
  package { 'cvmfs-repo':
    ensure   => 'installed',
    provider => 'rpm',
    name     => 'cvmfs-release-3-2.noarch',
    source   => 'https://ecsft.cern.ch/dist/cvmfs/cvmfs-release/cvmfs-release-3-2.noarch.rpm',
  }

  package { 'cvmfs':
    ensure  => 'installed',
    require => [Package['cvmfs-repo']],
  }

  file { '/cvmfs':
    ensure  => directory,
    seltype => 'root_t',
  }
}

type PublisherConfiguration = Struct[
  {
    'repository_name' => String,
    'repository_user' => String,
    'stratum0_url' => String,
    'gateway_url' => String,
    'certificate' => String,
    'public_key' => String,
    'api_key' => String,
    'server_conf' => Optional[Array[Tuple[String, String]]]
  }
]

class profile::cvmfs::publisher (
  Hash[String, PublisherConfiguration] $repositories,
) {
  require profile::cvmfs::install
  include profile::cvmfs::local_user
  package { 'cvmfs-server':
    ensure  => 'installed',
    require => [Package['cvmfs']],
  }

  file { '/etc/cvmfs/keys':
    ensure  => directory,
    seltype => 'root_t',
  }

  ensure_resources(profile::cvmfs::publisher::repository, $repositories)
}

define profile::cvmfs::publisher::repository (
  String $repository_name,
  String $repository_user,
  String $stratum0_url,
  String $gateway_url,
  String $certificate,
  String $public_key,
  String $api_key,
  Optional[Array[Tuple[String, String]]] $server_conf = undef,
) {
  file { "/etc/cvmfs/keys/${repository_name}.crt":
    content => $certificate,
    mode    => '0444',
    owner   => $repository_user,
    group   => 'root',
  }
  file { "/etc/cvmfs/keys/${repository_name}.pub":
    content => $public_key,
    mode    => '0444',
    owner   => $repository_user,
    group   => 'root',
  }
  file { "/etc/cvmfs/keys/${repository_name}.gw":
    content => "${api_key}\n",
    mode    => '0400',
    owner   => $repository_user,
    group   => 'root',
  }
  exec { "mkfs_${repository_name}":
    command => "cvmfs_server mkfs -w ${stratum0_url} -u gw,/srv/cvmfs/${repository_name}/data/txn,${gateway_url} -k /etc/cvmfs/keys -o ${repository_user} -a shake128 ${repository_name}",
    require => [File["/etc/cvmfs/keys/${repository_name}.crt"], File["/etc/cvmfs/keys/${repository_name}.pub"], File["/etc/cvmfs/keys/${repository_name}.gw"]],
    path    => ['/usr/bin'],
    returns => [0],
    # create only if it does not already exist
    creates => ["/var/spool/cvmfs/${repository_name}"]
  }

  if ($server_conf) {
    $server_conf.each | Integer $index, Tuple[String, String] $kv | {
      file_line { "server.conf_${repository_name}_${kv[0]}":
        ensure  => 'present',
        path    => "/etc/cvmfs/repositories.d/${repository_name}/server.conf",
        line    => "${kv[0]}=${kv[1]}",
        match   => "^${kv[0]}=.*",
        require => Exec["mkfs_${repository_name}"]
      }
    }
  }
}


class profile::cvmfs::client (
  Integer $quota_limit,
  Array[String] $repositories,
  Boolean $strict_mount = false,
  Array[String] $alien_cache_repositories = [],
  String $cvmfs_root = '/cvmfs',
) {
  include profile::consul
  require profile::cvmfs::install
  include profile::cvmfs::local_user
  $alien_fs_root_raw = lookup('profile::cvmfs::alien_cache::alien_fs_root', undef, undef, 'scratch')
  $alien_fs_root = regsubst($alien_fs_root_raw, '^/|/$', '', 'G')
  $alien_folder_name_raw = lookup('profile::cvmfs::alien_cache::alien_folder_name', undef, undef, 'cvmfs_alien_cache')
  $alien_folder_name = regsubst($alien_folder_name_raw, '^/|/$', '', 'G')

  file { $cvmfs_root:
    ensure  => directory,
    seltype => 'root_t',
  }

  file { '/etc/auto.master.d/cvmfs.autofs':
    notify  => Service['autofs'],
    require => [
      Package['cvmfs'],
      File[$cvmfs_root],
    ],
    content => @("EOF")
      # generated by Puppet for CernVM-FS
      ${cvmfs_root} /etc/auto.cvmfs
      |EOF
  }

  file_line { 'cvmfs_mount_dir':
    ensure => present,
    path   => '/etc/cvmfs/default.conf',
    line   => "  readonly CVMFS_MOUNT_DIR=${cvmfs_root}",
    match  => '^  readonly CVMFS_MOUNT_DIR=/cvmfs$',
  }

  file { '/etc/cvmfs/default.local.ctmpl':
    content => epp('profile/cvmfs/default.local', {
        'strict_mount' => $strict_mount ? { true => 'yes', false => 'no' }, # lint:ignore:selector_inside_resource
        'quota_limit'  => $quota_limit,
        'repositories' => $repositories + $alien_cache_repositories,
    }),
    notify  => Service['consul-template'],
    require => Package['cvmfs'], # 'cvmfs' packages provides /etc/cvmfs
  }

  $alien_cache_repositories.each |$repo| {
    file { "/etc/cvmfs/config.d/${repo}.conf":
      content => epp('profile/cvmfs/alien_cache.conf.epp', {
          'alien_fs_root'     => $alien_fs_root,
          'alien_folder_name' => $alien_folder_name,
      }),
      require => Package['cvmfs'], # 'cvmfs' packages provides /etc/cvmfs/config.d
    }
  }

  consul_template::watch { '/etc/cvmfs/default.local':
    require     => File['/etc/cvmfs/default.local.ctmpl'],
    config_hash => {
      perms       => '0644',
      source      => '/etc/cvmfs/default.local.ctmpl',
      destination => '/etc/cvmfs/default.local',
      command     => '/usr/bin/cvmfs_config reload',
    },
  }

  service { 'autofs':
    ensure => running,
    enable => true,
  }

  # Make sure CVMFS repos are mounted when requiring this class
  exec { 'init_default.local':
    command     => 'consul-template -template="/etc/cvmfs/default.local.ctmpl:/etc/cvmfs/default.local" -once',
    environment => ["CONSUL_TOKEN=${lookup('profile::consul::acl_api_token')}"],
    path        => ['/bin', '/usr/bin', $consul_template::bin_dir],
    unless      => 'test -f /etc/cvmfs/default.local',
    require     => [
      File['/etc/cvmfs/default.local.ctmpl'],
      Service['consul'],
      Service['autofs'],
    ],
  }

  # Fix issue with BASH_ENV, SSH and lmod where
  # ssh client would get a "Permission denied" when
  # trying to connect to a server. The errors
  # results from the SELinux context type of
  # /cvmfs/soft.computecanada.ca/nix/var/nix/profiles/16.09/lmod/lmod/init/bash
  # To be authorized in the ssh context, it would need
  # to be a bin_t type, but it is a fusefs_t and since
  # CVMFS is a read-only filesystem, the context cannot be changed.
  # 'use_fusefs_home_dirs' policy fix that issue.
  selinux::boolean { 'use_fusefs_home_dirs': }
}

# Create an alien source that refers to the uid and gid of cvmfs user
class profile::cvmfs::alien_cache (
  String $alien_fs_root_raw = 'scratch',
  String $alien_folder_name_raw = 'cvmfs_alien_cache',
) {
  $uid = lookup('profile::cvmfs::local_user::uid', undef, undef, 13000004)
  $gid = lookup('profile::cvmfs::local_user::gid', undef, undef, 8000131)
  $alien_fs_root = regsubst($alien_fs_root_raw, '^/|/$', '', 'G')
  $alien_folder_name = regsubst($alien_folder_name_raw, '^/|/$', '', 'G')

  # Ensure the alien cache parent folder exists
  ensure_resource('file', "/mnt/${alien_fs_root}", { 'ensure' => 'directory', 'seltype' => 'home_root_t' })

  file { "/mnt/${alien_fs_root}/${alien_folder_name}":
    ensure  => directory,
    group   => $gid,
    owner   => $uid,
    require => File["/mnt/${alien_fs_root}"],
    seluser => 'unconfined_u',
  }
}

# Create a local cvmfs user
class profile::cvmfs::local_user (
  String $uname = 'cvmfs',
  String $group = 'cvmfs-reserved',
  Integer $uid = 13000004,
  Integer $gid = 8000131,
  String $selinux_user = 'unconfined_u',
  String $mls_range = 's0-s0:c0.c1023',
) {
  group { $group:
    ensure => present,
    gid    => $gid,
    before => Package['cvmfs'],
  }
  user { $uname:
    ensure     => present,
    forcelocal => true,
    uid        => $uid,
    gid        => $gid,
    managehome => false,
    home       => '/var/lib/cvmfs',
    shell      => '/usr/sbin/nologin',
    require    => Group[$group],
    before     => Package['cvmfs'],
  }
  if $group != 'cvmfs' {
    # cvmfs rpm create a user and a group 'cvmfs' if they do not exist.
    # If the group created for the local user 'cvmfs' is not named 'cvmfs',
    # we make sure the group 'cvmfs' is attributed the same gid before installing
    # package cvmfs.
    group { 'cvmfs':
      allowdupe => true,
      gid       => $gid,
      require   => Group[$group],
      before    => Package['cvmfs'],
    }
  }
}
