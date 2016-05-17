#!/bin/bash
###################################
# edit vars
###################################
num=3
prefix=ucp
project=dev
image="coreos_1010"
flavor=mash.memory.small
key_name=labnc_186
password=Pa22word
license_file="/home/clemenko/Downloads/docker_subscription.lic"

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
 until [ $(ssh -o ConnectTimeout=1 core@$ext 'exit' 2>&1 | grep 'timed out' | wc -l) = 0 ]; do echo -n "." ; done
done
echo ""

host_list=$(cat hosts.txt|awk '{printf $3","}'|sed 's/,$//')

 #add etc hosts
 #etc_hosts_cmd=$(cat hosts.txt|awk '{printf "echo "$2" "$1"| sudo tee --append /etc/hosts;"}'|sed 's/.$//')
 #pdsh -l core -w $host_list 'chmod u+w /etc/hosts; sed -i -e "/127.0.0.1 $HOSTNAME/d" -e "/::1 $HOSTNAME/d" /etc/hosts'

echo " starting ucp server."

server=$(cat hosts.txt|head -1|awk '{print $3}')
fingerprint=$(ssh core@$server "docker run --rm -i --name ucp -v /var/run/docker.sock:/var/run/docker.sock docker/ucp install --admin-password $password --host-address $server" 2>&1 |grep Fingerprint|awk '{print $7}'|sed -e 's/Fingerprint=//g' -e 's/"//g')

echo " adding licenses."
token=$(curl -sk "https://$server/auth/login" -X POST -d '{"username":"admin","password":"Pa22word"}'|jq -r .auth_token)
curl -k "https://$server/api/config/license" -X POST -H "Authorization: Bearer $token" -d "{\"auto_refresh\":true,\"license_config\":$(cat $license_file |jq .)}"

echo " setting up nodes."
node_list=$(cat hosts.txt |grep -v "$server"|awk '{printf $3","}')
pdsh -l core -w $node_list "docker run --rm -i --name ucp -v /var/run/docker.sock:/var/run/docker.sock docker/ucp join --admin-username admin --admin-password $password --fingerprint $fingerprint --url https://$server" > /dev/null 2>&1

echo " restarting docker daemons"
 pdsh -l core -w $host_list "sudo systemctl restart docker"

echo ""
echo "========= UCP install complete ========="
echo " please wait a minute for the docker daemons to restart."
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
  echo "===== Cluster ====="
  supernova $project list |grep $prefix
  echo ""
  echo "===== Dashboards ====="
  echo " - server   : https://$server"
  echo " - username : admin"
  echo " - password : "$password
  echo ""
}

case "$1" in
        up) up;;
        kill) kill;;
        status) status;;
        *) echo "Usage: $0 {up|kill|status|presentation}"; exit 1
esac
