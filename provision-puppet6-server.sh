#!/bin/bash

set -e

export DEBIAN_FRONTEND=noninteractive

progress_message () {
  echo "********************************************************************************"
  echo "* $1"
  echo "********************************************************************************"
}

progress_message "Loading settings"
. /tmp/.env

progress_message "Downloading Puppet release package"
wget https://apt.puppetlabs.com/puppet6-release-bionic.deb

progress_message "Installing Puppet release package"
dpkg -i puppet6-release-bionic.deb
apt-get update

progress_message "Installing Puppet agent"
if [ "$PUPPETAGENTVERSIONSERVER" = "latest" ]
then apt-get install -y puppet-agent
else apt-get install -y puppet-agent=$PUPPETAGENTVERSIONSERVER
     apt-mark hold puppet-agent
fi

progress_message "Installing Puppet server"
if [ "$PUPPETSERVERVERSION" = "latest" ]
then apt-get install -y puppetserver
else apt-get install -y puppetserver=$PUPPETSERVERVERSION
     apt-mark hold puppetserver
fi

progress_message "Installing Puppet Development Kit"
apt-get install -y pdk

progress_message "Enabling sudo to puppet account"
chsh -s /bin/bash puppet

progress_message "Installing Ruby for running rspec tests"
apt-get install -y ruby-full

progress_message "Installing Ruby gems for running rspec tests"
apt-get install -y make gcc
gem install puppet -v $PUPPETGEMVERSION
gem install puppet-lint puppet-syntax puppetlabs_spec_helper rubocop

progress_message "Updating hosts file"
echo "$MASTERIP $SERVERHOSTNAME puppet" >> /etc/hosts
echo "$CLIENTIP $CLIENTHOSTNAME" >> /etc/hosts

progress_message "Updating Puppet configuration file"
cat << PUPPETCONF > /etc/puppetlabs/puppet/puppet.conf
[main]
certname = $SERVERHOSTNAME
PUPPETCONF

progress_message "Generating CA certificate"
/opt/puppetlabs/bin/puppetserver ca setup

progress_message "Creating manifest files"
manifestdir=/etc/puppetlabs/code/environments/production/manifests
cat << CLIENTMANIFEST > $manifestdir/$CLIENTHOSTNAME.pp
node '$CLIENTHOSTNAME' {
  notify { 'test message':
    message => join(['Manifest loaded successfully. Hiera message: ',lookup('puppet6vagrant::message',String)],''),
  }
}
CLIENTMANIFEST

cat << SERVERMANIFEST > $manifestdir/$SERVERHOSTNAME.pp
node '$SERVERHOSTNAME' {

    include apache
    include puppetboard
    include puppetdb
    include puppetdb::master::config

    class { 'python':
        pip        => 'present',
        virtualenv => 'present',
        dev        => 'present',
    }

    \$puppetssldir = '/etc/puppetlabs/puppet/ssl'
    \$puppetdbssldir = '/etc/puppetlabs/puppetdb/ssl'
    \$certinstallcmd = '/usr/bin/install --mode=0640 --owner=puppetdb --group=puppetdb'

    class { 'puppetboard::apache::vhost':
         vhost_name => "$SERVERHOSTNAME",
         port       => 5000,
    }
}
SERVERMANIFEST

progress_message "Creating hiera files"
hieradir=/etc/puppetlabs/code/environments/production/data/nodes
mkdir -p $hieradir
cat << CLIENTHIERA > $hieradir/$CLIENTHOSTNAME.yaml
puppet6vagrant::message: 'Default hiera message'
CLIENTHIERA

cat << SERVERHIERA > $hieradir/$SERVERHOSTNAME.yaml
puppetdb::globals::version: $PUPPETDBVERSION
puppetdb::listen_address: "0.0.0.0"
puppetdb::ssl_listen_address: $SERVERHOSTNAME
puppetdb::manage_package_repo: true
puppetdb::postgres_version: '9.6'
puppetdb::ssl_set_cert_paths: true
puppetdb::ssl_cert_path: '/etc/puppetlabs/puppetdb/ssl/public.pem'
puppetdb::ssl_key_path: '/etc/puppetlabs/puppetdb/ssl/private.pem'
puppetdb::ssl_ca_cert_path: '/etc/puppetlabs/puppetdb/ssl/ca.pem'
puppetdb::master::config::puppetdb_server: '$SERVERHOSTNAME'
puppetdb::master::config::enable_reports: true
puppetdb::master::config::manage_report_processor: true
puppetdb::master::config::manage_config: true
puppetdb::master::config::restart_puppet: true
puppetdb::master::config::puppet_service_name: 'puppetserver'

puppetboard::enable_catalog: true
puppetboard::revision: $PUPPETBOARDVERSION
SERVERHIERA

progress_message "Creating autosign whitelist configuration file"
cat << AUTOSIGNCONF > /etc/puppetlabs/puppet/autosign.conf
$AUTOSIGNWHITELIST
AUTOSIGNCONF

progress_message "Changing ownership puppet files"
chown -R puppet:puppet /etc/puppetlabs/code

progress_message "Starting Puppet server"
systemctl enable puppetserver
systemctl start puppetserver

progress_message "Installing Puppet modules"
installmodulecmd="sudo /opt/puppetlabs/bin/puppet module install"
moduledir="/etc/puppetlabs/code/environments/production/modules"
# Pin stdlib to version 5.2.0, because the puppetboard module
# doesn't support stdlib 6.x yet, as of puppetboard version 5.0.0
$installmodulecmd --target-dir $moduledir --version 5.2.0 puppetlabs/stdlib
$installmodulecmd --target-dir $moduledir puppetlabs/puppetdb
$installmodulecmd --target-dir $moduledir puppet/puppetboard
$installmodulecmd --target-dir $moduledir puppetlabs/apache

# This initial install is needed for setting up the
# TLS certificate files
progress_message "Installing PuppetDB"
apt-get install puppetdb

progress_message "Configuring PuppetDB TLS certificates"
/opt/puppetlabs/bin/puppetdb ssl-setup

progress_message "Running puppet agent on server"
/opt/puppetlabs/bin/puppet apply $manifestdir/$SERVERHOSTNAME.pp

progress_message "Restarting PuppetDB"
systemctl restart puppetdb

progress_message "Installing validation script"
apt-get install libcapture-tiny-perl
mv /tmp/vldt /usr/local/bin
chmod 0755 /usr/local/bin/vldt

if [ -f "/tmp/.gitconfig" ]
then
    progress_message "Copying git configuration"
    cp /tmp/.gitconfig ~vagrant
    cp /tmp/.gitconfig ~puppet
fi
