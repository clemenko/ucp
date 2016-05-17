#!/bin/bash
###################################
# edit vars
###################################
num=4
prefix=ucp
project=dev
image="coreos_1010"
#image="CentOS 7.latest"
USER=core
flavor=mash.memory.small
key_name=labnc_186
#gui admin password
password=Pa22word
version=v1.0.1

rancher=false

################################# up ################################
function build () {
 uuid=$(uuidgen| awk -F"-" '{print $1}')
 echo -n " building : $prefix-$uuid "
 supernova -q $project boot --flavor $flavor --key-name $key_name --image "$image" --config-drive true $prefix-$uuid > /dev/null 2>&1
 until [ $(supernova -q $project show $prefix-$uuid | grep status | awk '{print $4}') = "ACTIVE" ]; do echo -n "."; sleep 3; done
 next_ip=$(supernova dev floating-ip-list | grep -v "172.16"|grep "10.0.141"|head -1|awk '{print $4}')
 supernova -q $project add-floating-ip $prefix-$uuid $next_ip
 echo $prefix-$uuid $(supernova -q $project show $prefix-$uuid | grep network|awk '{print $5" "$6}' | grep -v DELETE|sed 's/,//g') >> hosts.txt
 echo ""
}

function up () {
 if [ -f hosts.txt ]; then echo "hosts.txt found. Are you sure you want to override it? "; exit; fi

 #build
 for i in $(seq 1 $num); do
   build
 done

sleep 30

 echo -n " checking for ssh."
 for ext in $(cat hosts.txt|awk '{print $3}'); do
   until [ $(ssh -o ConnectTimeout=1 $USER@$ext 'exit' 2>&1 | grep 'timed out' | wc -l) = 0 ]; do echo -n "." ; done
 done
 echo ""

 host_list=$(cat hosts.txt|awk '{printf $3","}'|sed 's/,$//')

 #add etc hosts
 etc_hosts_cmd=$(cat hosts.txt|awk '{printf "echo "$2" "$1"| sudo tee --append /etc/hosts;"}'|sed 's/.$//')
 pdsh -l $USER -w $host_list 'chmod u+w /etc/hosts; sed -i -e "/127.0.0.1 $HOSTNAME/d" -e "/::1 $HOSTNAME/d" /etc/hosts'
 #pdsh -l core -w $host_list "$etc_hosts_cmd" > /dev/null 2>&1


 echo -n " starting ucp server."
 server=$(cat hosts.txt|head -1|awk '{print $3}')


 echo " setting up nodes."

exit
 ssh $USER@$server "docker run -d -p 8080:8080 --restart=always --name rancher-server rancher/server:$version" > /dev/null 2>&1
 until curl $server:8080 > /dev/null 2>&1; do echo -n .; sleep 1; done
 echo " "

 echo " setting up rancher server"
 curl -s 'http://'$server':8080/v1/activesettings/1as!api.host?projectId=user' -X PUT -H 'Accept: application/json' -H 'Content-Type: application/json; charset=UTF-8' --data '{"id":"1as!api.host","type":"activeSetting","name":"api.host","activeValue":null,"inDb":false,"source":null,"value":"'$server':8080"}' > /dev/null 2>&1
 curl -s 'http://'$server':8080/v1/registrationtokens?projectId=1a5' -X POST -H 'Accept: application/json' -H 'Content-Type: application/json; charset=UTF-8' -H 'Referer: http://'$server':8080/static/hosts/add/custom' > /dev/null 2>&1
 sleep 10

 echo " - attaching agents"
 agent_string=$(curl -s http://$server:8080/v1/registrationtokens?projectId=1a5|sed 's/\\\\\//\//g' | sed 's/[{}]//g' | awk -v k="text" '{n=split($0,a,","); for (i=1; i<=n; i++) print a[i]}' | sed 's/\"\:\"/\|/g' | sed 's/[\,]/ /g' | sed 's/\"//g' | grep -w command|sed 's/command|sudo//g')
 echo $agent_string > agent_string.txt
 agent_list=$(cat hosts.txt|tail -n +2|awk '{printf $3","}')
 pdsh -l $USER -w $agent_list "$agent_string" > install.log 2>&1

 echo " - setting up api keys"
 api_string=$(curl -s 'http://'$server':8080/v1/apikey?projectId=1a5' -X POST -H 'Accept: application/json' --data {"type":"apikey"})
 RANCHER_ACCESS_KEY=$(echo $api_string|sed 's/\\\\\//\//g' | sed 's/[{}]//g' | awk -v k="text" '{n=split($0,a,","); for (i=1; i<=n; i++) print a[i]}' | sed 's/\"\:\"/\|/g' | sed 's/[\,]/ /g' | sed 's/\"//g'|grep publicValue|awk -F"|" '{print $2}')
 RANCHER_SECRET_KEY=$(echo $api_string|sed 's/\\\\\//\//g' | sed 's/[{}]//g' | awk -v k="text" '{n=split($0,a,","); for (i=1; i<=n; i++) print a[i]}' | sed 's/\"\:\"/\|/g' | sed 's/[\,]/ /g' | sed 's/\"//g'|grep secretValue|awk -F"|" '{print $2}')
 echo $RANCHER_ACCESS_KEY:$RANCHER_SECRET_KEY > secrets.txt

 echo " - setting up security"
 curl -s 'http://'$server':8080/v1/localauthconfig' -X POST -H 'Accept: application/json' -H 'Content-Type: application/json; charset=UTF-8' --data '{"accessMode":"unrestricted","name":"admin","id":null,"type":"localAuthConfig","enabled":false,"password":"'$password'","username":"admin"}' > /dev/null 2>&1
 curl -s 'http://'$server':8080/v1/token' -X POST -H 'Accept: application/json' -H 'Content-Type: application/json; charset=UTF-8' --data '{"code":"admin:'$password'","authProvider":"localauthconfig"}' > /dev/null 2>&1
 curl -s 'http://'$server':8080/v1/localauthconfig' -X POST -H 'Accept: application/json' -H 'Content-Type: application/json; charset=UTF-8' --data '{"accessMode":"unrestricted","name":"admin","id":null,"type":"localAuthConfig","enabled":true,"password":"'$password'","username":"admin"}' > /dev/null 2>&1

echo ""
echo "========= UCP install complete ========="
status
}

############################## destroy ################################
function kill () {
echo " killing it all."
for i in $(cat hosts.txt|awk '{print $1}'); do supernova $project delete $i; done
for i in $(cat hosts.txt|awk '{print $3}'); do ssh-keygen -q -R $i > /dev/null 2>&1; done
rm -rf *.txt *.log
}

############################# status ################################
function status () {
  server=$(cat hosts.txt|head -1|awk '{print $3}')
  RANCHER_ACCESS_KEY=$(cat secrets.txt|awk -F":" '{print $1}')
  RANCHER_SECRET_KEY=$(cat secrets.txt|awk -F":" '{print $2}')
  echo "===== Cluster ====="
  supernova $project list |grep $prefix
  echo ""
  echo "===== Dashboards ====="
  echo "Rancher : http://"$server":8080"
  echo " - username : admin"
  echo " - password : "$password
  echo ""
  echo "===== Secret Keys ====="
  echo "export RANCHER_URL=http://"$server":8080/v1/projects/1a5"
  echo "export RANCHER_ACCESS_KEY="$RANCHER_ACCESS_KEY
  echo "export RANCHER_SECRET_KEY="$RANCHER_SECRET_KEY
  echo "export NIFI_MASTER=$(cat hosts.txt |sed -n '2p'|awk '{print $2}')"
}

case "$1" in
        up) up;;
        kill) kill;;
        status) status;;
        *) echo "Usage: $0 {up|kill|status|presentation}"; exit 1
esac
