#!/bin/bash

#Provided by @mrlesmithjr
#EveryThingShouldBeVirtual.com

# This script configures the node as a logstash broker sending to redis on backend logstash processors

set -e
# Setup logging
# Logs stderr and stdout to separate files.
exec 2> >(tee "./ELK-Broker-Node.err")
exec > >(tee "./ELK-Broker-Node.log")

# Setting colors for output
red="$(tput setaf 1)"
yellow="$(tput bold ; tput setaf 3)"
NC="$(tput sgr0)"

# Capture your FQDN Domain Name and IP Address
echo "${yellow}Capturing your hostname${NC}"
yourhostname=$(hostname)
echo "${yellow}Capturing your domain name${NC}"
yourdomainname=$(dnsdomainname)
echo "${yellow}Capturing your FQDN${NC}"
yourfqdn=$(hostname -f)
echo "${yellow}Detecting IP Address${NC}"
IPADDY="$(ifconfig | grep -A 1 'eth0' | tail -1 | cut -d ':' -f 2 | cut -d ' ' -f 1)"
echo "Your hostname is currently ${red}$yourhostname${NC}"
echo "Your domain name is currently ${red}$yourdomainname${NC}"
echo "Your FQDN is currently ${red}$yourfqdn${NC}"
echo "Detected IP Address is ${red}$IPADDY${NC}"

# Disable CD Sources in /etc/apt/sources.list
echo "Disabling CD Sources and Updating Apt Packages and Installing Pre-Reqs"
sed -i -e 's|deb cdrom:|# deb cdrom:|' /etc/apt/sources.list
apt-get -qq update

############################### Logstash - Elasticsearch cluster Setup ##################################
# Install Pre-Reqs
apt-get install -y --force-yes git curl software-properties-common ntp

# Install Oracle Java 7 **NOT Used - Installing openjdk-7-jre above
echo "Installing Oracle Java 7"
add-apt-repository -y ppa:webupd8team/java
apt-get -qq update
echo oracle-java7-installer shared/accepted-oracle-license-v1-1 select true | /usr/bin/debconf-set-selections
apt-get install -y oracle-java7-installer oracle-java7-set-default
 
##################### Logstash Front-End Broker Setup ###########################################
# Install Pre-Reqs
apt-get install -y --force-yes ruby ruby1.9.1-dev libcurl4-openssl-dev

# Install Redis-Server
apt-get -y install redis-server
# Configure Redis-Server to listen on all interfaces
sed -i -e 's|bind 127.0.0.1|bind 0.0.0.0|' /etc/redis/redis.conf
service redis-server restart

# Setup rsyslog to forward syslog to logstash
echo "Enter the VIP Hostname being used in your setup"
echo "This will be the same as what is intended to be used to setup HAProxy VIP Info"
echo "Example....logstash"
echo "This will be used to setup rsyslog to forward syslog events for this node to logstash"
echo -n "Enter VIP Info: "
read logstashinfo
echo '*.* @@'$logstashinfo'' | tee -a  /etc/rsyslog.d/50-default.conf
service rsyslog restart

# Install Logstash
cd /opt
#wget https://download.elasticsearch.org/logstash/logstash/logstash-1.4.1.tar.gz
wget https://download.elasticsearch.org/logstash/logstash/logstash-1.4.2.tar.gz
tar zxvf logstash-*.tar.gz
mv logstash-1.4.*/ logstash
/opt/logstash/bin/plugin install contrib

# Create Logstash Init Script
(
cat <<'EOF'
#! /bin/sh

### BEGIN INIT INFO
# Provides:          logstash
# Required-Start:    $remote_fs $syslog
# Required-Stop:     $remote_fs $syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Start daemon at boot time
# Description:       Enable service provided by daemon.
### END INIT INFO

. /lib/lsb/init-functions

name="logstash"
logstash_bin="/opt/logstash/bin/logstash"
logstash_conf="/etc/logstash/logstash.conf"
logstash_log="/var/log/logstash.log"
pid_file="/var/run/$name.pid"
patterns_path="/etc/logstash/patterns"

start () {
        command="${logstash_bin} -- agent -f $logstash_conf --log ${logstash_log}"

        log_daemon_msg "Starting $name" "$name"
        if start-stop-daemon --start --quiet --oknodo --pidfile "$pid_file" -b -m --exec $command; then
                log_end_msg 0
        else
                log_end_msg 1
        fi
}

stop () {
        log_daemon_msg "Stopping $name" "$name"
        start-stop-daemon --stop --quiet --oknodo --pidfile "$pid_file"
}

status () {
        status_of_proc -p "$pid_file" "$name"
}

case $1 in
        start)
                if status; then exit 0; fi
                start
                ;;
        stop)
                stop
                ;;
        reload)
                stop
                start
                ;;
        restart)
                stop
                start
                ;;
        status)
                status && exit 0 || exit $?
                ;;
        *)
                echo "Usage: $0 {start|stop|restart|reload|status}"
                exit 1
                ;;
esac

exit 0
EOF
) | tee /etc/init.d/logstash

# Make logstash executable
chmod +x /etc/init.d/logstash

# Enable logstash start on bootup
update-rc.d logstash defaults 96 04

# Collect information for VIP (IP|HOSTNAME) To inject into script
echo "Enter the HAProxy VIP (IP|HOSTNAME) for your setup"
echo "This will be what points to your back-end ELK Cluster Client Nodes"
echo "This will also be the VIP, hostname or FQDN that was setup in haproxy.cfg"
echo "(Example - 10.0.101.60, logstash or logstash.example.local"
echo -n "Enter your information here: "
read logstashinfo
echo "You entered ${red}$logstashinfo${NC}"

# Create Logstash configuration file
mkdir /etc/logstash
tee -a /etc/logstash/logstash.conf <<EOF
input {
        file {
                path => "/var/log/nginx/access.log"
                type => "nginx-access"
                sincedb_path => "/var/log/.nginxaccesssincedb"
        }
}
input {
        file {
                path => "/var/log/nginx/error.log"
                type => "nginx-error"
                sincedb_path => "/var/log/.nginxerrorsincedb"
        }
}
input {
        tcp {
                type => "syslog"
                port => "514"
        }
}
input {
        tcp {
                type => "VMware"
                port => "1514"
        }
}
input {
        tcp {
                type => "vCenter"
                port => "1515"
        }
}
input {
        tcp {
                type => "Netscaler"
                port => "1517"
        }
}
input {
        tcp {
                type => "eventlog"
                port => "3515"
                format => "json"
        }
}
input {
        tcp {
                type => "iis"
                port => "3525"
                codec => "json_lines"
        }
}
output {
  redis {
  host => $logstashinfo
  data_type => "list"
  key => "logstash"
  }
}
EOF

# Update elasticsearch-template for logstash
mv /opt/logstash/lib/logstash/outputs/elasticsearch/elasticsearch-template.json /opt/logstash/lib/logstash/outputs/elasticsearch/elasticsearch-template.json.orig
tee -a /opt/logstash/lib/logstash/outputs/elasticsearch/elasticsearch-template.json <<EOF
{
  "template" : "logstash-*",
  "settings" : {
    "index.refresh_interval" : "5s"
  },
  "mappings" : {
    "_default_" : {
       "_all" : {"enabled" : true},
       "dynamic_templates" : [ {
         "string_fields" : {
           "match" : "*",
           "match_mapping_type" : "string",
           "mapping" : {
             "type" : "string", "index" : "analyzed", "omit_norms" : true,
               "fields" : {
                 "raw" : {"type": "string", "index" : "not_analyzed", "ignore_above" : 256}
               }
           }
         }
       } ],
       "properties" : {
         "@version": { "type": "string", "index": "not_analyzed" },
         "geoip"  : {
           "type" : "object",
             "dynamic": true,
             "path": "full",
             "properties" : {
               "location" : { "type" : "geo_point" }
             }
         },
        "actconn": { "type": "long", "index": "not_analyzed" },
        "backend_queue": { "type": "long", "index": "not_analyzed" },
        "beconn": { "type": "long", "index": "not_analyzed" },
        "bytes": { "type": "long", "index": "not_analyzed" },
        "bytes_read": { "type": "long", "index": "not_analyzed" },
        "datastore_latency_from": { "type": "long", "index": "not_analyzed" },
        "datastore_latency_to": { "type": "long", "index": "not_analyzed" },
        "feconn": { "type": "long", "index": "not_analyzed" },
        "msg_size": { "type": "long", "index": "not_analyzed" },
        "response_time": { "type": "long", "index": "not_analyzed" },
        "retries": { "type": "long", "index": "not_analyzed" },
        "srv_queue": { "type": "long", "index": "not_analyzed" },
        "srvconn": { "type": "long", "index": "not_analyzed" },
        "time_backend_connect": { "type": "long", "index": "not_analyzed" },
        "time_backend_response": { "type": "long", "index": "not_analyzed" },
        "time_duration": { "type": "long", "index": "not_analyzed" },
        "time_queue": { "type": "long", "index": "not_analyzed" },
        "time_request": { "type": "long", "index": "not_analyzed" }
       }
    }
  }
}
EOF

# Create IPTables Grok pattern
tee -a /opt/logstash/patterns/IPTABLES <<EOF
NETFILTERMAC %{COMMONMAC:dst_mac}:%{COMMONMAC:src_mac}:%{ETHTYPE:ethtype}
ETHTYPE (?:(?:[A-Fa-f0-9]{2}):(?:[A-Fa-f0-9]{2}))
IPTABLES1 (?:IN=%{WORD:in_device} OUT=(%{WORD:out_device})? MAC=%{NETFILTERMAC} SRC=%{IP:src_ip} DST=%{IP:dst_ip}.*(TTL=%{INT:ttl})?.*PROTO=%{WORD:proto}?.*SPT=%{INT:src_port}?.*DPT=%{INT:dst_port}?.*)
IPTABLES2 (?:IN=%{WORD:in_device} OUT=(%{WORD:out_device})? MAC=%{NETFILTERMAC} SRC=%{IP:src_ip} DST=%{IP:dst_ip}.*(TTL=%{INT:ttl})?.*PROTO=%{INT:proto}?.*)
IPTABLES (?:%{IPTABLES1}|%{IPTABLES2})
EOF

# Restart logstash service
service logstash restart

# Logrotate job for logstash
tee -a /etc/logrotate.d/logstash <<EOF
/var/log/logstash.log {
        monthly
        rotate 12
        compress
        delaycompress
        missingok
        notifempty
        create 644 root root
}
EOF

# All Done
echo "Installation has completed!!"
echo "Now continue on and setup your ELK-Processor nodes"
#echo -e "To connect to cluster connect to ${red}http://$logstashinfo/kibana${NC}"
echo "${yellow}EveryThingShouldBeVirtual.com${NC}"
echo "${yellow}@mrlesmithjr${NC}"
echo "${yellow}Enjoy!!!${NC}"
