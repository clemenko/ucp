#!/bin/bash
###################################
# edit vars
###################################
set -e
num=3 #3 or larger please!
prefix=ddc
password=Pa22word
zone=nyc1
size=2gb
key=30:98:4f:c5:47:c2:88:28:fe:3c:23:cd:52:49:51:01
#image=centos-7-x64
image=rancheros
license_file="docker_subscription.lic"
ee_url=$(cat url.env)
ucp_ver=latest

######  NO MOAR EDITS #######
################################# up ################################

RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
NORMAL=$(tput sgr0)

function up () {
export PDSH_RCMD_TYPE=ssh
build_list=""
uuid=""
for i in $(seq 1 $num); do
 uuid=$(uuidgen| awk -F"-" '{print $2}')
 build_list="$prefix-$uuid $build_list"
done
echo -n " building vms - $build_list "
doctl compute droplet create $build_list --region $zone --image $image --size $size --ssh-keys $key --wait > /dev/null 2>&1
doctl compute droplet list|grep -v ID|grep $prefix|awk '{print $3" "$2}'> hosts.txt

echo "$GREEN" "[OK]" "$NORMAL"

sleep 10

echo -n " checking for ssh"
for ext in $(awk '{print $1}' hosts.txt); do
  until [ $(ssh -o ConnectTimeout=1 rancher@$ext 'exit' 2>&1 | grep 'timed out' | wc -l) = 0 ]; do echo -n "." ; sleep 5; done
done
echo "$GREEN" "[OK]" "$NORMAL"

host_list=$(awk '{printf $1","}' hosts.txt|sed 's/,$//')

#setting nodes
controller1=$(sed -n 1p hosts.txt|awk '{print $1}')
dtr_server=$(sed -n 2p hosts.txt|awk '{printf $1}')
dtr_node=$(sed -n 2p hosts.txt|awk '{printf $2}')
app_node=$(sed -n 3p hosts.txt|awk '{printf $1}')

echo -n " updating dns "
doctl compute domain records create dockr.life --record-type A --record-name ucp --record-ttl 300 --record-data $controller1 > /dev/null 2>&1
doctl compute domain records create dockr.life --record-type A --record-name dtr --record-ttl 300 --record-data $dtr_server > /dev/null 2>&1
doctl compute domain records create dockr.life --record-type A --record-name app --record-ttl 300 --record-data $app_node > /dev/null 2>&1
doctl compute domain records create dockr.life --record-type CNAME --record-name "*" --record-ttl 300 --record-data app.dockr.life. > /dev/null 2>&1
echo "$GREEN" "[OK]" "$NORMAL"

sleep 30

#echo -n " updating rancheros docker version"
#pdsh -l rancher -w $host_list "sudo ros engine switch docker-17.05.0-ce"
#echo "$GREEN" "[OK]" "$NORMAL"

echo -n " starting ucp server "
ssh rancher@$controller1 "docker run --rm -i --name ucp -v /var/run/docker.sock:/var/run/docker.sock docker/ucp:$ucp_ver install --admin-password $password --host-address $controller1 --san ucp.dockr.life --disable-usage --disable-tracking" > /dev/null 2>&1
echo "$GREEN" "[OK]" "$NORMAL"

echo -n " getting tokens "
MGRTOKEN=$(ssh rancher@$controller1 "docker swarm join-token -q manager")
WRKTOKEN=$(ssh rancher@$controller1 "docker swarm join-token -q worker")
echo $MGRTOKEN > manager_token.txt
echo $WRKTOKEN > worker_token.txt
echo "$GREEN" "[OK]" "$NORMAL"

sleep 10

echo -n " adding license "
token=$(curl -sk "https://$controller1/auth/login" -X POST -d '{"username":"admin","password":"'$password'"}'|jq -r .auth_token)
curl -k "https://$controller1/api/config/license" -X POST -H "Authorization: Bearer $token" -d "{\"auto_refresh\":true,\"license_config\":$(cat $license_file |jq .)}"
echo "$GREEN" "[OK]" "$NORMAL"

#echo " setting up mangers"
#pdsh -l root -w $manager2,$manager3 "docker swarm join --token $MGRTOKEN $controller1:2377" > /dev/null 2>&1

sleep 10
echo -n " setting up nodes "
node_list=$(sed -n 1,"$num"p hosts.txt|awk '{printf $1","}')
pdsh -l rancher -w $node_list "docker swarm join --token $WRKTOKEN $controller1:2377" > /dev/null 2>&1
echo "$GREEN" "[OK]" "$NORMAL"

echo -n " downloading client bundle "
AUTHTOKEN=$(curl -sk -d '{"username":"admin","password":"'$password'"}' https://$controller1/auth/login | jq -r .auth_token)
curl -sk -H "Authorization: Bearer $AUTHTOKEN" https://$controller1/api/clientbundle -o bundle.zip
echo "$GREEN" "[OK]" "$NORMAL"

sleep 60

#echo -n " building nfs server for dtr "
#ssh root@$dtr_server 'chmod -R 777 /opt/; yum -y install nfs-utils; systemctl enable rpcbind nfs-server; systemctl start rpcbind nfs-server ; echo "/opt *(rw,sync,no_root_squash,no_all_squash)" > /etc/exports; systemctl restart nfs-server' > /dev/null 2>&1
#echo "$GREEN" "[OK]" "$NORMAL"

echo -n " installing DTR "
unzip bundle.zip > /dev/null 2>&1
curl -sk https://$controller1/ca > ucp-ca.pem

eval $(<env.sh)
#docker run -it --rm docker/dtr install --ucp-url https://ucp.dockr.life --ucp-node $dtr_node --dtr-external-url https://dtr.dockr.life --ucp-username admin --ucp-password $password --ucp-ca "$(cat ucp-ca.pem)" > /dev/null 2>&1

docker run -it --rm docker/dtr install --ucp-url https://ucp.dockr.life --ucp-node $dtr_node --dtr-external-url https://dtr.dockr.life --ucp-username admin --ucp-password $password --ucp-insecure-tls > /dev/null 2>&1


#--nfs-storage-url nfs://$dtr_server/opt
curl -sk https://$dtr_server/ca > dtr-ca.pem
echo "$GREEN" "[OK]" "$NORMAL"

echo -n " disabling scheduling on controllers "
token=$(curl -sk "https://$controller1/auth/login" -X POST -d '{"username":"admin","password":"'$password'"}'|jq -r .auth_token)
curl -k --user admin:$password "https://$controller1/api/config/scheduling" -X POST -H "Authorization: Bearer $token" -d "{\"enable_admin_ucp_scheduling\":true,\"enable_user_ucp_scheduling\":false}"
echo "$GREEN" "[OK]" "$NORMAL"

#echo -n " enabling HRM"
#token=$(curl -sk "https://$controller1/auth/login" -X POST -d '{"username":"admin","password":"'$password'"}'|jq -r .auth_token)
#curl -k --user admin:$password "https://$controller1/api/hrm" -X POST -H 'Content-Type: application/json;charset=utf-8' -H "Authorization: Bearer $token" -d "{\"HTTPPort\":80,\"HTTPSPort\":8443}"
#echo "$GREEN" "[OK]" "$NORMAL"

echo " enabling scanning engine"
curl -skX POST --user admin:$password -H "Content-Type: application/json" -H "Accept: application/json"  -d "{ \"reportAnalytics\": false, \"anonymizeAnalytics\": false, \"disableBackupWarning\": true, \"scanningEnabled\": true, \"scanningSyncOnline\": true }" "https://dtr.dockr.life/api/v0/meta/settings"  > /dev/null 2>&1
echo "$GREEN" "[OK]" "$NORMAL"

#echo -n " adding load balancer for worker nodes - this can take a minute or two "
#doctl compute load-balancer create --name lb1 --region $zone --algorithm least_connections --sticky-sessions type:none --forwarding-rules entry_protocol:http,entry_port:80,target_protocol:http,target_port:80 --health-check protocol:tcp,port:80 --droplet-ids $(doctl compute droplet list|grep -v ID|sed -n 2,4p |awk '{printf $1","}'|sed 's/.$//') > /dev/null 2>&1;
#echo "$GREEN" "[OK]" "$NORMAL"


echo ""
echo "========= UCP install complete ========="
echo ""
status
}

################################ demo ##############################
function demo () {
 controller1=$(sed -n 1p hosts.txt|awk '{print $1}')
 eval $(<env.sh)

  echo -n " adding devops team with permission label"
  token=$(curl -sk -d '{"username":"admin","password":"'$password'"}' https://$controller1/auth/login | jq -r .auth_token)
  team_id=$(curl -sk -X POST -H "Authorization: Bearer $token" 'https://ucp.dockr.life/enzi/v0/accounts/docker-datacenter/teams' -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -H 'Content-Type: application/json;charset=utf-8' -d "{\"name\":\"devops\"}" |jq -r .id)

  token=$(curl -sk -d '{"username":"admin","password":"'$password'"}' https://$controller1/auth/login | jq -r .auth_token)
  curl -k -X POST -H "Authorization: Bearer $token" "https://ucp.dockr.life/api/teamlabels/$team_id/prod" -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -d "2"
  echo "$GREEN" "[OK]" "$NORMAL"

  echo -n " adding developer team with permission label"
  token=$(curl -sk -d '{"username":"admin","password":"'$password'"}' https://$controller1/auth/login | jq -r .auth_token)
  team_id=$(curl -sk -X POST -H "Authorization: Bearer $token" 'https://ucp.dockr.life/enzi/v0/accounts/docker-datacenter/teams' -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -H 'Content-Type: application/json;charset=utf-8' -d "{\"name\":\"developers\"}" |jq -r .id)

  token=$(curl -sk -d '{"username":"admin","password":"'$password'"}' https://$controller1/auth/login | jq -r .auth_token)
  curl -k -X POST -H "Authorization: Bearer $token" "https://ucp.dockr.life/api/teamlabels/$team_id/prod" -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -d "1"
  echo "$GREEN" "[OK]" "$NORMAL"

  echo -n " adding demo repos to DTR"
  curl -skX POST --user admin:$password -H "Content-Type: application/json" -H "Accept: application/json" -d "{\"name\": \"flask\",\"shortDescription\": \"custom flask\",\"longDescription\": \"the best damm custom flask app ever\",\"visibility\": \"public\",\"scanOnPush\": true }" "https://dtr.dockr.life/api/v0/repositories/admin" > /dev/null 2>&1

  curl -skX POST --user admin:$password -H "Content-Type: application/json" -H "Accept: application/json" -d "{\"name\": \"alpine\",\"shortDescription\": \"upstream\",\"longDescription\": \"upstream from hub.docker.com\",\"visibility\": \"public\",\"scanOnPush\": true }" "https://dtr.dockr.life/api/v0/repositories/admin" > /dev/null 2>&1

  curl -skX POST --user admin:$password -H "Content-Type: application/json" -H "Accept: application/json" -d "{\"name\": \"nginx\",\"shortDescription\": \"upstream\",\"longDescription\": \"upstream from hub.docker.com\",\"visibility\": \"public\",\"scanOnPush\": true }" "https://dtr.dockr.life/api/v0/repositories/admin" > /dev/null 2>&1
  echo "$GREEN" "[OK]" "$NORMAL"

  echo -n " adding demo secret"
  echo "greatest demo ever" | docker secret create -l com.docker.ucp.access.label=prod demo_title_v1 - > /dev/null 2>&1
  echo "$GREEN" "[OK]" "$NORMAL"
}

############################## destroy ################################
function kill () {
echo -n " killing it all "
#doctl
for i in $(awk '{print $2}' hosts.txt); do doctl compute droplet delete --force $i; done
for i in $(awk '{print $1}' hosts.txt); do ssh-keygen -q -R $i > /dev/null 2>&1; done
for i in $(doctl compute domain records list dockr.life|grep 'app\|ucp\|dtr\|suntrust'|awk '{print $1}'); do doctl compute domain records delete -f dockr.life $i; done

if [ "$(doctl compute load-balancer list|grep lb1|wc -l| sed -e 's/^[[:space:]]*//')" = "1" ]; then
 doctl compute load-balancer delete -f $(doctl compute load-balancer list|grep -v ID|awk '{print $1}') > /dev/null 2>&1;
fi

rm -rf *.txt *.log *.zip *.pem *.pub env.* backup.tar
echo "$GREEN" "[OK]" "$NORMAL"
}

############################# status ################################
function status () {
  controller1=$(head -1 hosts.txt|awk '{print $1}')
  dtr_server=$(sed -n 2p hosts.txt|awk '{printf $1}')
  echo "===== Cluster ====="
  doctl compute droplet list |grep $prefix
  echo ""
  echo "===== Dashboards ====="
  echo " - UCP   : https://ucp.dockr.life"
  echo " - username : admin"
  echo " - password : "$password
  echo ""
  echo " - DTR   : https://dtr.dockr.life"
  echo ""
  echo "===== Load Balancer ====="
  echo " - http://"$(doctl compute load-balancer list|grep -v ID|awk '{print $2}')" "
  echo ""
#  echo " - Minio : http://$dtr_server:9000"
#  echo " - Access key : $(cat min_access.txt)"
#  echo " - Secret key : $(cat min_secret.txt)"
#  echo ""
}

case "$1" in
        up) up;;
        kill) kill;;
        status) status;;
        demo) demo;;
        *) echo "Usage: $0 {up|kill|demo|status}"; exit 1
esac
