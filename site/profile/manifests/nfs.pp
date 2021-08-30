class profile::nfs::client (String $server_ip) {
  $domain_name = lookup({ name          => 'profile::freeipa::base::domain_name',
                          default_value => $::domain })
  $nfs_domain  = "int.${domain_name}"

  class { '::nfs':
    client_enabled      => true,
    nfs_v4_client       => true,
    nfs_v4_idmap_domain => $nfs_domain
  }

  $nfs_export_list = keys(lookup('profile::nfs::server::devices', undef, undef, {}))
  $options_nfsv4 = 'proto=tcp,nosuid,nolock,noatime,actimeo=3,nfsvers=4.2,seclabel,bg'
  $nfs_export_list.each | String $name | {
    nfs::client::mount { "/${name}":
        server        => $server_ip,
        share         => $name,
        options_nfsv4 => $options_nfsv4
    }
  }
}

class profile::nfs::server (
  Hash[String, Array[String]] $devices,
) {
  require profile::base

  $domain_name = lookup({ name          => 'profile::freeipa::base::domain_name',
                          default_value => $::domain })
  $nfs_domain  = "int.${domain_name}"

  file { '/lib/systemd/system/clean-nfs-rbind.service':
    mode    => '0644',
    owner   => 'root',
    group   => 'root',
    content => @(END)
[Unit]
Before=nfs-server.service

[Service]
Type=oneshot
RemainAfterExit=true
ExecStop=/usr/bin/sed "-i ';/export/;d' /etc/fstab"

[Install]
WantedBy=multi-user.target
END
  }

  exec { 'clean-nfs-rbind-systemd-reload':
    command     => 'systemctl daemon-reload',
    path        => [ '/usr/bin', '/bin', '/usr/sbin' ],
    refreshonly => true,
    require     => File['/lib/systemd/system/clean-nfs-rbind.service']
  }

  service { 'clean-nfs-rbind':
    ensure  => running,
    enable  => true,
    require => Exec['clean-nfs-rbind-systemd-reload']
  }

  $cidr = profile::getcidr()
  class { '::nfs':
    server_enabled             => true,
    nfs_v4                     => true,
    storeconfigs_enabled       => false,
    nfs_v4_export_root         => '/export',
    nfs_v4_export_root_clients => "${cidr}(ro,fsid=root,insecure,no_subtree_check,async,root_squash)",
    nfs_v4_idmap_domain        => $nfs_domain
  }

  file { '/etc/nfs.conf':
    ensure => present,
    owner  => 'root',
    group  => 'root',
    mode   => '0644',
    source => 'puppet:///modules/profile/nfs/nfs.conf',
    notify => Service[$::nfs::server_service_name],
  }

  service { ['rpc-statd', 'rpcbind', 'rpcbind.socket']:
    ensure => stopped,
    enable => mask,
    notify => Service[$::nfs::server_service_name],
  }

  package { 'lvm2':
    ensure => installed
  }

  $home_dev_glob    = lookup('profile::nfs::server::devices.home', undef, undef, [])
  $project_dev_glob = lookup('profile::nfs::server::devices.project', undef, undef, [])
  $scratch_dev_glob = lookup('profile::nfs::server::devices.scratch', undef, undef, [])

  $home_dev_regex = regsubst($home_dev_glob, /[?*]/, {'?' => '.', '*' => '.*' })
  $project_dev_regex = regsubst($project_dev_glob, /[?*]/, {'?' => '.', '*' => '.*' })
  $scratch_dev_regex = regsubst($scratch_dev_glob, /[?*]/, {'?' => '.', '*' => '.*' })

  if ! empty($home_dev_regex) {
    file { ['/mnt/home'] :
      ensure  => directory,
      seltype => 'home_root_t',
    }

    $home_pool = $::facts['/dev/disk'].filter |$key, $values| {
      $home_dev_regex.any|$regex| {
        $key =~ Regexp($regex)
      }
    }.map |$key, $values| {
      $values
    }

    exec { 'vgchange-home_vg':
      command => 'vgchange -ay home_vg',
      onlyif  => ['test ! -d /dev/home_vg', 'vgscan -t | grep -q "home_vg"'],
      require => [Package['lvm2']],
      path    => ['/bin', '/usr/bin', '/sbin', '/usr/sbin'],
    }

    physical_volume { $home_pool:
      ensure => present,
    }

    volume_group { 'home_vg':
      ensure           => present,
      physical_volumes => $home_pool,
      createonly       => true,
      followsymlinks   => true,
    }

    lvm::logical_volume { 'home':
      ensure            => present,
      volume_group      => 'home_vg',
      fs_type           => 'xfs',
      mountpath         => '/mnt/home',
      mountpath_require => true,
    }

    selinux::fcontext::equivalence { '/mnt/home':
      ensure  => 'present',
      target  => '/home',
      require => Mount['/mnt/home'],
      notify  => Selinux::Exec_restorecon['/mnt/home']
    }

    selinux::exec_restorecon { '/mnt/home': }

    nfs::server::export{ '/mnt/home' :
      ensure  => 'mounted',
      clients => "${cidr}(rw,async,root_squash,no_all_squash,security_label)",
      notify  => Service[$::nfs::server_service_name],
      require => [
        Mount['/mnt/home'],
        Class['::nfs'],
      ]
    }
  }

  if ! empty($project_dev_regex) {
    file { ['/project'] :
      ensure  => directory,
      seltype => 'home_root_t',
    }

    $project_pool = $::facts['/dev/disk'].filter |$key, $values| {
      $project_dev_regex.any|$regex| {
        $key =~ Regexp($regex)
      }
    }.map |$key, $values| {
      $values
    }

    exec { 'vgchange-project_vg':
      command => 'vgchange -ay project_vg',
      onlyif  => ['test ! -d /dev/project_vg', 'vgscan -t | grep -q "project_vg"'],
      require => [Package['lvm2']],
      path    => ['/bin', '/usr/bin', '/sbin', '/usr/sbin'],
    }

    physical_volume { $project_pool:
      ensure => present,
    }

    volume_group { 'project_vg':
      ensure           => present,
      physical_volumes => $project_pool,
      createonly       => true,
      followsymlinks   => true,
    }

    lvm::logical_volume { 'project':
      ensure            => present,
      volume_group      => 'project_vg',
      fs_type           => 'xfs',
      mountpath         => '/project',
      mountpath_require => true,
    }

    selinux::fcontext::equivalence { '/project':
      ensure  => 'present',
      target  => '/home',
      require => Mount['/project'],
      notify  => Selinux::Exec_restorecon['/project']
    }

    selinux::exec_restorecon { '/project': }

    nfs::server::export{ '/project':
      ensure  => 'mounted',
      clients => "${cidr}(rw,async,root_squash,no_all_squash,security_label)",
      notify  => Service[$::nfs::server_service_name],
      require => [
        Mount['/project'],
        Class['::nfs'],
      ]
    }
  }

  if ! empty($scratch_dev_regex) {
    file { ['/scratch'] :
      ensure  => directory,
      seltype => 'home_root_t',
    }

    $scratch_pool = $::facts['/dev/disk'].filter |$key, $values| {
      $scratch_dev_regex.any|$regex| {
        $key =~ Regexp($regex)
      }
    }.map |$key, $values| {
      $values
    }

    exec { 'vgchange-scratch_vg':
      command => 'vgchange -ay scratch_vg',
      onlyif  => ['test ! -d /dev/scratch_vg', 'vgscan -t | grep -q "scratch_vg"'],
      require => [Package['lvm2']],
      path    => ['/bin', '/usr/bin', '/sbin', '/usr/sbin'],
    }

    physical_volume { $scratch_pool:
      ensure => present,
    }

    volume_group { 'scratch_vg':
      ensure           => present,
      physical_volumes => $scratch_pool,
      createonly       => true,
      followsymlinks   => true,
    }

    lvm::logical_volume { 'scratch':
      ensure            => present,
      volume_group      => 'scratch_vg',
      fs_type           => 'xfs',
      mountpath         => '/scratch',
      mountpath_require => true,
    }

    selinux::fcontext::equivalence { '/scratch':
      ensure  => 'present',
      target  => '/home',
      require => Mount['/scratch'],
      notify  => Selinux::Exec_restorecon['/scratch']
    }

    selinux::exec_restorecon { '/scratch': }

    nfs::server::export{ '/scratch':
      ensure  => 'mounted',
      clients => "${cidr}(rw,async,root_squash,no_all_squash,security_label)",
      notify  => Service[$::nfs::server_service_name],
      require => [
        Mount['/scratch'],
        Class['::nfs'],
      ]
    }
  }

  exec { 'unexportfs_exportfs':
    command => 'exportfs -ua; cat /proc/fs/nfs/exports; exportfs -a',
    path    => ['/usr/sbin', '/usr/bin'],
    unless  => 'grep -qvP "(^#|^/export\s)" /proc/fs/nfs/exports'
  }
}

define profile::nfs::server::export_volume (
  String $vol_name,
  Array[String] $regexes,
  String $seltype = 'home_root_t',
) {

  file { ["/mnt/${vol_name}"] :
    ensure  => directory,
    seltype => $seltype,
  }

  $pool = $::facts['/dev/disk'].filter |$key, $values| {
    $regexes.any|$regex| {
      $key =~ Regexp($regex)
    }
  }.map |$key, $values| {
    $values
  }

  exec { "vgchange-${vol_name}_vg":
    command => "vgchange -ay ${vol_name}_vg",
    onlyif  => ["test ! -d /dev/${vol_name}_vg", "vgscan -t | grep -q '${vol_name}_vg'"],
    require => [Package['lvm2']],
    path    => ['/bin', '/usr/bin', '/sbin', '/usr/sbin'],
  }

  physical_volume { $pool:
    ensure => present,
  }

  volume_group { "${vol_name}_vg":
    ensure           => present,
    physical_volumes => $pool,
    createonly       => true,
    followsymlinks   => true,
  }

  lvm::logical_volume { $vol_name:
    ensure            => present,
    volume_group      => "${vol_name}_vg",
    fs_type           => 'xfs',
    mountpath         => "/mnt/${vol_name}",
    mountpath_require => true,
  }

  selinux::fcontext::equivalence { "/mnt/${vol_name}":
    ensure  => 'present',
    target  => '/home',
    require => Mount["/mnt/${vol_name}"],
    notify  => Selinux::Exec_restorecon[$vol_name]
  }

  selinux::exec_restorecon { "/mnt/${vol_name}": }

  nfs::server::export{ "/mnt/${vol_name}":
    ensure  => 'mounted',
    clients => "${cidr}(rw,async,root_squash,no_all_squash,security_label)",
    notify  => Service[$::nfs::server_service_name],
    require => [
      Mount["/mnt/${vol_name}"],
      Class['::nfs'],
    ]
  }
}
