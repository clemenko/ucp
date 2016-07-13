#!/bin/bash
###################################
# edit vars
###################################
num=3
prefix=ucp
password=Pa22word
zone=nyc2
size=2gb
key=30:98:4f:c5:47:c2:88:28:fe:3c:23:cd:52:49:51:01
#image=coreos-stable
image=ubuntu-16-04-x64
password=Pa22word
license_file="docker_subscription.lic"

export PDSH_RCMD_TYPE=ssh
################################# up ################################
function build () {
 uuid=$(uuidgen| awk -F"-" '{print $1}')
 echo " building : $prefix-$uuid "
 doctl compute droplet create $prefix-$uuid --region $zone --image $image --size $size --ssh-keys $key  > /dev/null 2>&1
}

function up () {
 if [ -f hosts.txt ]; then echo "hosts.txt found. Are you sure you want to override it? "; exit; fi

 #build
 for i in $(seq 1 $num); do
   build
 done

sleep 10
doctl compute droplet list|grep -v ID|grep $prefix|awk '{print $3" "$2}'> hosts.txt

echo -n " checking for ssh."
for ext in $(cat hosts.txt|awk '{print $1}'); do
  until [ $(ssh -o ConnectTimeout=1 root@$ext 'exit' 2>&1 | grep 'timed out' | wc -l) = 0 ]; do echo -n "." ; done
done
sleep 15
echo ""

host_list=$(cat hosts.txt|awk '{printf $1","}'|sed 's/,$//')
echo " installing latest docker"
pdsh -l root -w $host_list 'curl -fsSL https://get.docker.com/ | sh; systemctl enable docker; systemctl start docker' > /dev/null 2>&1


echo " starting ucp server."

server=$(cat hosts.txt|head -1|awk '{print $1}')
fingerprint=$(ssh root@$server "docker run --rm -i --name ucp -v /var/run/docker.sock:/var/run/docker.sock docker/ucp install --admin-password $password --host-address $server" 2>&1 |grep Fingerprint|awk '{print $7}'|sed -e 's/Fingerprint=//g' -e 's/"//g')

sleep 5

echo " adding licenses."
token=$(curl -sk "https://$server/auth/login" -X POST -d '{"username":"admin","password":"Pa22word"}'|jq -r .auth_token)
curl -k "https://$server/api/config/license" -X POST -H "Authorization: Bearer $token" -d "{\"auto_refresh\":true,\"license_config\":$(cat $license_file |jq .)}"

echo " setting up nodes."
node_list=$(cat hosts.txt |grep -v "$server"|awk '{printf $1","}')
pdsh -l root -w $node_list "docker run --rm -i --name ucp -v /var/run/docker.sock:/var/run/docker.sock docker/ucp join --admin-username admin --admin-password $password --fingerprint $fingerprint --url https://$server" > /dev/null 2>&1

echo " downloading certs"
AUTHTOKEN=$(curl -sk -d '{"username":"admin","password":"$password"}' https://$server/auth/login | jq -r .auth_token)
curl -sk -H "Authorization: Bearer $AUTHTOKEN" https://$server/api/clientbundle -o bundle.zip

echo " restarting docker daemons"
 pdsh -l root -w $host_list "sudo systemctl restart docker"

echo ""
echo "========= UCP install complete ========="
echo " please wait a minute for the docker daemons to restart."
status
}

############################## destroy ################################
function kill () {
echo " killing it all."
for i in $(cat hosts.txt|awk '{print $2}'); do doctl compute droplet delete $i; done
for i in $(cat hosts.txt|awk '{print $1}'); do ssh-keygen -q -R $i > /dev/null 2>&1; done
rm -rf *.txt *.log *.zip
}

############################# status ################################
function status () {
  server=$(cat hosts.txt|head -1|awk '{print $1}')
  echo "===== Cluster ====="
  doctl compute droplet list |grep $prefix
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
        *) echo "Usage: $0 {up|kill|status}"; exit 1
esac
