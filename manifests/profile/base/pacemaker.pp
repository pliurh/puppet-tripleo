# Copyright 2016 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
#
# == Class: tripleo::profile::base::pacemaker
#
# Pacemaker profile for tripleo
#
# === Parameters
#
# [*step*]
#   (Optional) The current step in deployment. See tripleo-heat-templates
#   for more details.
#   Defaults to hiera('step')
#
# [*pcs_tries*]
#   (Optional) The number of times pcs commands should be retried.
#   Defaults to hiera('pcs_tries', 20)
#
# [*remote_short_node_names*]
#   (Optional) List of short node names for pacemaker remote nodes
#   Defaults to hiera('pacemaker_remote_short_node_names', [])
#
# [*remote_node_ips*]
#   (Optional) List of node ips for pacemaker remote nodes
#   Defaults to hiera('pacemaker_remote_node_ips', [])
#
# [*remote_authkey*]
#   (Optional) Authkey for pacemaker remote nodes
#   Defaults to undef
#
# [*remote_reconnect_interval*]
#   (Optional) Reconnect interval for the remote
#   Defaults to hiera('pacemaker_remote_reconnect_interval', 60)
#
# [*remote_monitor_interval*]
#   (Optional) Monitor interval for the remote
#   Defaults to hiera('pacemaker_monitor_reconnect_interval', 20)
#
# [*remote_tries*]
#   (Optional) Number of tries for the remote resource creation
#   Defaults to hiera('pacemaker_remote_tries', 5)
#
# [*remote_try_sleep*]
#   (Optional) Number of seconds to sleep between remote creation tries
#   Defaults to hiera('pacemaker_remote_try_sleep', 60)
#
class tripleo::profile::base::pacemaker (
  $step                      = hiera('step'),
  $pcs_tries                 = hiera('pcs_tries', 20),
  $remote_short_node_names   = hiera('pacemaker_remote_short_node_names', []),
  $remote_node_ips           = hiera('pacemaker_remote_node_ips', []),
  $remote_authkey            = undef,
  $remote_reconnect_interval = hiera('pacemaker_remote_reconnect_interval', 60),
  $remote_monitor_interval   = hiera('pacemaker_remote_monitor_interval', 20),
  $remote_tries              = hiera('pacemaker_remote_tries', 5),
  $remote_try_sleep          = hiera('pacemaker_remote_try_sleep', 60),
) {

  if count($remote_short_node_names) != count($remote_node_ips) {
    fail("Count of ${remote_short_node_names} is not equal to count of ${remote_node_ips}")
  }

  Pcmk_resource <| |> {
    tries     => 10,
    try_sleep => 3,
  }

  if $::hostname == downcase(hiera('pacemaker_short_bootstrap_node_name')) {
    $pacemaker_master = true
  } else {
    $pacemaker_master = false
  }

  $enable_fencing = str2bool(hiera('enable_fencing', false)) and $step >= 5

  if $step >= 1 {
    $pacemaker_short_node_names = join(hiera('pacemaker_short_node_names'), ',')
    $pacemaker_cluster_members = downcase(regsubst($pacemaker_short_node_names, ',', ' ', 'G'))
    $corosync_ipv6 = str2bool(hiera('corosync_ipv6', false))
    if $corosync_ipv6 {
      $cluster_setup_extras = { '--token' => hiera('corosync_token_timeout', 1000), '--ipv6' => '' }
    } else {
      $cluster_setup_extras = { '--token' => hiera('corosync_token_timeout', 1000) }
    }
    class { '::pacemaker':
      hacluster_pwd => hiera('hacluster_pwd'),
    } ->
    class { '::pacemaker::corosync':
      cluster_members      => $pacemaker_cluster_members,
      setup_cluster        => $pacemaker_master,
      cluster_setup_extras => $cluster_setup_extras,
      remote_authkey       => $remote_authkey,
    }
    class { '::pacemaker::stonith':
      disable => !$enable_fencing,
      tries   => $pcs_tries,
    }
    if $enable_fencing {
      include ::tripleo::fencing

      # enable stonith after all Pacemaker resources have been created
      Pcmk_resource<||> -> Class['tripleo::fencing']
      Pcmk_constraint<||> -> Class['tripleo::fencing']
      Exec <| tag == 'pacemaker_constraint' |> -> Class['tripleo::fencing']
      # enable stonith after all fencing devices have been created
      Class['tripleo::fencing'] -> Class['pacemaker::stonith']
    }
    # We have pacemaker remote nodes configured so let's add them as resources
    # We do this during step 1 right after wait-for-settle, because during step 2
    # resources might already be created on pacemaker remote nodes and we need
    # a guarantee that remote nodes are already up
    if $pacemaker_master and count($remote_short_node_names) > 0 {
      # Creates a { "node" => "ip_address", ...} hash
      $remotes_hash = hash(zip($remote_short_node_names, $remote_node_ips))
      pacemaker::resource::remote { $remote_short_node_names:
        remote_address     => $remotes_hash[$title],
        reconnect_interval => $remote_reconnect_interval,
        op_params          => "monitor interval=${remote_monitor_interval}",
        tries              => $remote_tries,
        try_sleep          => $remote_try_sleep,
      }
    }
  }

  if $step >= 2 {
    if $pacemaker_master {
      include ::pacemaker::resource_defaults
    }
  }

}
