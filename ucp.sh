#!/bin/bash
###################################
# edit vars
###################################
set -e
num=3 #3 or larger please!
prefix=ddc
password=Pa22word
zone=nyc1
size=s-2vcpu-4gb
key=30:98:4f:c5:47:c2:88:28:fe:3c:23:cd:52:49:51:01
license_file="docker_subscription.lic"

image=centos-7-x64
#image=rancheros
#image=ubuntu-16-04-x64

ucp_ver=latest
dtr_ver=latest
#engine_repo=docker-ee-stable-17.06
engine_repo=docker-ee-stable-18.09

minio=true # true will add the minio service for testing an s3 service.
loadbalancer=false
storageos=false
nfs=false

######  NO MOAR EDITS #######
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
NORMAL=$(tput sgr0)
BLUE=$(tput setaf 4)

if [ "$image" = rancheros ]; then user=rancher; fi
if [ "$image" = centos-7-x64 ]; then user=root; fi

if ! $(which -s curl); then echo "$RED" " ** Curl was not found. Please install before preceeding. ** " "$NORMAL" ; fi
if ! $(which -s jq); then echo "$RED" " ** Jq was not found. Please install before preceeding. ** " "$NORMAL" ; fi
if ! $(which -s pdsh); then echo "$RED" " ** Pdsh was not found. Please install before preceeding. ** " "$NORMAL" ; fi
if ! $(which -s uuid); then echo "$RED" " ** Uuid was not found. Please install before preceeding. ** " "$NORMAL" ; fi

################################# up ################################
function up () {

if [ -f $license_file ]; then
  license_file="$license_file"
else
  echo "$RED" "Warning - docker license file missing..." "$NORMAL"
  exit
fi

if [ -f url.env ]; then
  ee_url=$(cat url.env)/centos
else
  echo "$RED" "Warning - docker ee url.env file missing..." "$NORMAL"
  exit
fi

if [ -f hosts.txt ]; then
  echo "$RED" "Warning - cluster already detected..." "$NORMAL"
  exit
fi

build_list=""
uuid=""
for i in $(seq 1 $num); do
 #uuid=$(uuidgen| awk -F"-" '{print $2}')
 uuid=$(uuid -v4| awk -F"-" '{print $4}')
 build_list="$prefix-$uuid $build_list"
done
echo -n " building vms : $build_list "
doctl compute droplet create $build_list --region $zone --image $image --size $size --ssh-keys $key --wait > /dev/null 2>&1
doctl compute droplet list|grep -v ID|grep $prefix|awk '{print $3" "$2}'> hosts.txt

#add gcloud

echo "$GREEN" "[ok]" "$NORMAL"

sleep 60

echo -n " checking for ssh "
for ext in $(awk '{print $1}' hosts.txt); do
  until [ $(ssh -o ConnectTimeout=1 $user@$ext 'exit' 2>&1 | grep 'timed out' | wc -l) = 0 ]; do echo -n "." ; sleep 5; done
done
echo "$GREEN" "[ok]" "$NORMAL"

host_list=$(awk '{printf $1","}' hosts.txt|sed 's/,$//')

#setting nodes
controller1=$(sed -n 1p hosts.txt|awk '{print $1}')
dtr_server=$(sed -n 2p hosts.txt|awk '{printf $1}')
dtr_node=$(sed -n 2p hosts.txt|awk '{printf $2}')
worker=$(sed -n 3p hosts.txt|awk '{printf $1}')

echo -n " updating dns "
doctl compute domain records create dockr.life --record-type A --record-name ucp --record-ttl 300 --record-data $controller1 > /dev/null 2>&1
doctl compute domain records create dockr.life --record-type A --record-name dtr --record-ttl 300 --record-data $dtr_server > /dev/null 2>&1
doctl compute domain records create dockr.life --record-type A --record-name app --record-ttl 300 --record-data $worker > /dev/null 2>&1
doctl compute domain records create dockr.life --record-type CNAME --record-name "*" --record-ttl 300 --record-data app.dockr.life. > /dev/null 2>&1
#doctl compute domain records create dockr.life --record-type CNAME --record-name "gitlab" --record-ttl 300 --record-data app.dockr.life. > /dev/null 2>&1

echo "$GREEN" "[ok]" "$NORMAL"

if [ "$image" = centos-7-x64 ]; then
  echo -n " updating the os and installing docker ee "
  pdsh -l $user -w $host_list 'yum update -y; yum install -y yum-utils; echo "'$ee_url'" > /etc/yum/vars/dockerurl; echo "7" > /etc/yum/vars/dockerosversion; yum-config-manager --add-repo $(cat /etc/yum/vars/dockerurl)/docker-ee.repo; yum makecache fast; yum-config-manager --enable '"$engine_repo"'; yum -y install docker-ee; systemctl start docker; docker plugin disable docker/telemetry:1.0.0.linux-x86_64-stable; echo "vm.swappiness=0" >> /etc/sysctl.conf; echo "vm.overcommit_memory=1" >> /etc/sysctl.conf;  echo "net.ipv4.neigh.default.gc_thresh1 = 80000" >> /etc/sysctl.conf; echo "net.ipv4.neigh.default.gc_thresh2 = 90000" >> /etc/sysctl.conf; echo "net.ipv4.neigh.default.gc_thresh3 = 100000" >> /etc/sysctl.conf; echo "net.ipv4.tcp_keepalive_time=600" >> /etc/sysctl.conf; echo "fs.may_detach_mounts=1" >> /etc/sysctl.conf; echo "fs.inotify.max_user_instances=8192" >> /etc/sysctl.conf; echo "fs.inotify.max_user_watches=1048576" >> /etc/sysctl.conf;  sysctl -p ; systemctl enable docker' > /dev/null 2>&1
  echo "$GREEN" "[ok]" "$NORMAL"

  echo -n " adding daemon configs "
  pdsh -l $user -w $host_list 'echo -e "{\n \"selinux-enabled\": true, \n \"log-driver\": \"json-file\", \n \"log-opts\": {\"max-size\": \"10m\", \"max-file\": \"3\"}, \n \"metrics-addr\" : \"0.0.0.0:9323\", \n \"experimental\" : true \n}" > /etc/docker/daemon.json; systemctl restart docker'
  echo "$GREEN" "[ok]" "$NORMAL"
fi

if [ "$image" = rancheros ]; then
  echo " updating to the latest engine"
  pdsh -l $user -w $host_list 'sudo ros engine switch docker-18.06.1-ce' > /dev/null 2>&1
  sleep 5
fi

echo -n " starting ucp server "
ssh $user@$controller1 "docker run --rm -i --name ucp -v /var/run/docker.sock:/var/run/docker.sock docker/ucp:$ucp_ver install --admin-password $password --host-address $controller1 --san ucp.dockr.life --disable-usage --disable-tracking --force-minimums" > /dev/null 2>&1
echo "$GREEN" "[ok]" "$NORMAL"

echo -n " getting tokens "
MGRTOKEN=$(ssh $user@$controller1 "docker swarm join-token -q manager")
WRKTOKEN=$(ssh $user@$controller1 "docker swarm join-token -q worker")
echo $MGRTOKEN > manager_token.txt
echo $WRKTOKEN > worker_token.txt
echo "$GREEN" "[ok]" "$NORMAL"

sleep 60

echo -n " downloading client bundle "
AUTHTOKEN=$(curl -sk -d '{"username":"admin","password":"'$password'"}' https://$controller1/auth/login | jq -r .auth_token)
curl -sk -H "Authorization: Bearer $AUTHTOKEN" https://$controller1/api/clientbundle -o bundle.zip
unzip bundle.zip > /dev/null 2>&1
curl -sk https://$controller1/ca > ucp-ca.pem
eval "$(<env.sh)" > /dev/null 2>&1
echo "$GREEN" "[ok]" "$NORMAL"

echo -n " updating task history "
docker swarm update --task-history-limit=1 > /dev/null 2>&1
echo "$GREEN" "[ok]" "$NORMAL"

echo -n " adding license "
docker config create com.docker.license-1 $license_file > /dev/null 2>&1
docker service update --config-add source=com.docker.license-1,target=/etc/ucp/docker.lic ucp-agent --detach=false > /dev/null 2>&1
echo "$GREEN" "[ok]" "$NORMAL"

#echo " setting up mangers"
#pdsh -l root -w $manager2,$manager3 "docker swarm join --token $MGRTOKEN $controller1:2377" > /dev/null 2>&1

sleep 30

echo -n " adding nodes to the cluster "
node_list=$(sed -n 1,"$num"p hosts.txt|awk '{printf $1","}')
pdsh -l $user -w $node_list "docker swarm join --token $WRKTOKEN $controller1:2377" > /dev/null 2>&1
echo "$GREEN" "[ok]" "$NORMAL"

sleep 75

if [ "$nfs" = true ]; then
  echo -n " building nfs server for dtr "
  ssh root@$dtr_server 'chmod -R 777 /opt/; yum -y install nfs-utils; systemctl enable rpcbind nfs-server; systemctl start rpcbind nfs-server ; echo "/opt *(rw,sync,no_root_squash,no_all_squash)" > /etc/exports; systemctl restart nfs-server' > /dev/null 2>&1
  echo "$GREEN" "[ok]" "$NORMAL"
fi

echo -n " installing DTR "
docker run -it --rm docker/dtr:$dtr_ver install --ucp-url https://ucp.dockr.life --ucp-node $dtr_node --dtr-external-url https://dtr.dockr.life --ucp-username admin --ucp-password $password --ucp-insecure-tls > /dev/null 2>&1
#--nfs-storage-url nfs://$dtr_server/opt

curl -sk https://$dtr_server/ca > dtr-ca.pem
echo "$GREEN" "[ok]" "$NORMAL"

echo -n " enabling Routing Mesh"
token=$(curl -sk "https://$controller1/auth/login" -X POST -d '{"username":"admin","password":"'$password'"}'|jq -r .auth_token)
curl -skX POST "https://$controller1//api/interlock" -X POST -H 'Content-Type: application/json;charset=utf-8' -H "Authorization: Bearer $token" -d '{"HTTPPort":80,"HTTPSPort":8443,"Arch":"x86_64"}'
echo "$GREEN" "[ok]" "$NORMAL"

echo -n " disabling scheduling on controllers "
#token=$(curl -sk "https://$controller1/auth/login" -X POST -d '{"username":"admin","password":"'$password'"}'|jq -r .auth_token)
#curl -k --user admin:$password "https://$controller1/api/config/scheduling" -X POST -H "Authorization: Bearer $token" -d '{"enable_admin_ucp_scheduling":true,"enable_user_ucp_scheduling":false}'

#CURRENT_CONFIG_NAME=$(docker service inspect ucp-agent --format '{{range .Spec.TaskTemplate.ContainerSpec.Configs}}{{if eq "/etc/ucp/ucp.toml" .File.Name}}{{.ConfigName}}{{end}}{{end}}')
#docker config inspect --format '{{ printf "%s" .Spec.Data }}' $CURRENT_CONFIG_NAME > ucp-config.toml
#sed -i '' 's/enable_user_ucp_scheduling = true/enable_user_ucp_scheduling = false/g' ucp-config.toml
#NEXT_CONFIG_NAME=${CURRENT_CONFIG_NAME%%-*}-$((${CURRENT_CONFIG_NAME##*-}+1))
#docker config create $NEXT_CONFIG_NAME  ucp-config.toml
#docker service update --config-rm $CURRENT_CONFIG_NAME --config-add source=$NEXT_CONFIG_NAME,target=/etc/ucp/ucp.toml ucp-agent
echo "$RED" "[fix]" "$NORMAL"

echo -n " configuring garbage collection"
curl -skX POST --user admin:$password -H "Content-Type: application/json" -H "Accept: application/json"  -d '{"action": "gc","schedule": "0 0 1 * * 0","retries": 0,"deadline": "","stopTimeout": "30s"}' "https://dtr.dockr.life/api/v0/crons"  > /dev/null 2>&1
echo "$GREEN" "[ok]" "$NORMAL"

echo -n " increasing DTR worker count"
worker_id=$(curl -skX GET -u admin:$password "https://dtr.dockr.life/api/v0/workers/" -H "accept: application/json" | jq -r .workers[0].id)
curl -skX POST -u admin:$password "https://dtr.dockr.life/api/v0/workers/$worker_id/capacity" -H "accept: application/json" -H "content-type: application/json" -d '{ "capacityMap": { "scan": 2, "scanCheck": 2 }}' > /dev/null 2>&1
echo "$GREEN" "[ok]" "$NORMAL"


echo -n " enabling scanning engine"
curl -kX POST --user admin:$password "https://$dtr_server/api/v0/meta/settings" -H "Content-Type: application/json" -H "Accept: application/json"  -d '{ "reportAnalytics": false, "anonymizeAnalytics": false, "disableBackupWarning": true, "scanningEnabled": true, "scanningSyncOnline": true, "scanningEnableAutoRecheck": true }' > /dev/null 2>&1
echo "$GREEN" "[ok]" "$NORMAL"

#if [ "$image" = centos-7-x64 ]; then
#  echo -n " updating nodes with DTR's CA "
  #Add DTR CA to all the nodes (ALL):
#  pdsh -l $user -w $node_list "curl -sk https://dtr.dockr.life/ca -o /etc/pki/ca-trust/source/anchors/dtr.dockr.life.crt; update-ca-trust; systemctl restart docker" > /dev/null 2>&1
#fi

if [ "$loadbalancer" = true ]; then
  echo -n " adding load balancer for worker nodes - this can take a minute or two "
  doctl compute load-balancer create --name lb1 --region $zone --algorithm least_connections --sticky-sessions type:none --forwarding-rules entry_protocol:http,entry_port:80,target_protocol:http,target_port:80 --health-check protocol:tcp,port:80 --droplet-ids $(doctl compute droplet list|grep -v ID|sed -n 2,4p |awk '{printf $1","}'|sed 's/.$//') > /dev/null 2>&1;
  echo "$GREEN" "[ok]" "$NORMAL"
fi

if [ "$minio" = true ]; then
  echo -n " setting up minio "

  min_access=$(uuid -v4 | sed 's/-//g')
  echo $min_access > min_access.txt
  min_secret=$(uuid -v4 | sed 's/-//g')
  echo $min_secret > min_secret.txt

  ssh $user@$dtr_server "mkdir /opt/minio; chmod -R 777 /opt/minio; docker run -v /opt/minio/:/opt/:Z -e MINIO_ACCESS_KEY=$min_access -e MINIO_SECRET_KEY=$min_secret -d -p 9000:9000 minio/minio server /opt" > /dev/null 2>&1
  sleep 5

  min_token=$(curl -sk 'http://dtr.dockr.life:9000/minio/webrpc' -H 'Accept-Encoding: gzip, deflate' -H 'Content-Type: application/json' -d '{"id":1,"jsonrpc":"2.0","params":{"username":"'$min_access'","password":"'$min_secret'"},"method":"Web.Login"}' --compressed | jq -r .result.token)

  curl -sk 'http://dtr.dockr.life:9000/minio/webrpc' -H 'Accept-Encoding: gzip, deflate' -H 'Content-Type: application/json' -H "Authorization: Bearer $min_token"  --data-binary '{"id":1,"jsonrpc":"2.0","params":{"bucketName":"dtr"},"method":"Web.MakeBucket"}' --compressed  > /dev/null 2>&1

  curl -skX PUT -u admin:$password 'https://dtr.dockr.life/api/v0/admin/settings/registry/simple' -H 'content-type: application/json' -d '{"storage":{"delete":{"enabled":true},"maintenance":{"readonly":{"enabled":false}},"s3":{"v4auth":true,"secure":true,"skipverify":false,"regionendpoint":"http://dtr.dockr.life:9000","bucket":"dtr","rootdirectory":"/","secretkey":"'$min_secret'","region":"us-east-1","accesskey":"'$min_access'"}}}'  > /dev/null 2>&1

  echo "$GREEN" "[ok]" "$NORMAL"
fi

echo ""
echo "========= UCP install complete ========="
echo ""
status
}

################################ demo ##############################
function demo () {
  #review https://gist.github.com/mbentley/f289435e065650253b608467251eef49

  controller1=$(sed -n 1p hosts.txt|awk '{print $1}')

  echo -n " adding organizations and teams"
  token=$(curl -sk -d '{"username":"admin","password":"'$password'"}' https://ucp.dockr.life/auth/login | jq -r .auth_token) > /dev/null 2>&1

  curl -sk -X POST https://ucp.dockr.life/accounts/ -H "Authorization: Bearer $token" -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -H 'Content-Type: application/json;charset=utf-8' -d '{"name":"orcabank","isOrg":true}' > /dev/null 2>&1

  ops_team_id=$(curl -sk -X POST https://ucp.dockr.life/accounts/orcabank/teams -H "Authorization: Bearer $token" -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -H 'Content-Type: application/json;charset=utf-8' -d '{"name":"ops","description":"ops team of awesomeness"}' | jq -r .id)

  mobile_team_id=$(curl -sk -X POST https://ucp.dockr.life/accounts/orcabank/teams -H "Authorization: Bearer $token" -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -H 'Content-Type: application/json;charset=utf-8' -d '{"name":"mobile","description":"dev team of awesomeness"}' | jq -r .id)

  payments_team_id=$(curl -sk -X POST https://ucp.dockr.life/accounts/orcabank/teams -H "Authorization: Bearer $token" -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -H 'Content-Type: application/json;charset=utf-8' -d '{"name":"payments","description":"dev team of awesomeness"}' | jq -r .id)

  security_team_id=$(curl -sk -X POST https://ucp.dockr.life/accounts/orcabank/teams -H "Authorization: Bearer $token" -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -H 'Content-Type: application/json;charset=utf-8' -d '{"name":"security","description":"security team of awesomeness"}' | jq -r .id)

  ci_team_id=$(curl -sk -X POST https://ucp.dockr.life/accounts/orcabank/teams -H "Authorization: Bearer $token" -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -H 'Content-Type: application/json;charset=utf-8' -d '{"name":"ci","description":"ci team of awesomeness"}' | jq -r .id)

  echo "$GREEN" "[ok]" "$NORMAL"

  echo -n " adding users"
  token=$(curl -sk -d '{"username":"admin","password":"'$password'"}' https://ucp.dockr.life/auth/login | jq -r .auth_token)

  curl -skX POST https://ucp.dockr.life/accounts/ -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d '{  "fullName": "tim ops",  "isActive": true,  "isAdmin": false,  "isOrg": false,  "name": "tim",  "password": "Pa22word",  "searchLDAP": false}' > /dev/null 2>&1

  curl -skX POST https://ucp.dockr.life/accounts/ -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d '{  "fullName": "bob developer",  "isActive": true,  "isAdmin": false,  "isOrg": false,  "name": "bob",  "password": "Pa22word",  "searchLDAP": false}' > /dev/null 2>&1

  curl -skX POST https://ucp.dockr.life/accounts/ -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json"  -d '{  "fullName": "jeff security",  "isActive": true,  "isAdmin": false,  "isOrg": false,  "name": "jeff",  "password": "Pa22word",  "searchLDAP": false}' > /dev/null 2>&1

  curl -skX POST https://ucp.dockr.life/accounts/ -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json"  -d '{  "fullName": "andy admin",  "isActive": true,  "isAdmin": true,  "isOrg": false,  "name": "andy",  "password": "Pa22word",  "searchLDAP": false}' > /dev/null 2>&1

  curl -skX POST https://ucp.dockr.life/accounts/ -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json"  -d '{  "fullName": "gitlab ci",  "isActive": true,  "isAdmin": true,  "isOrg": false,  "name": "gitlab",  "password": "Pa22word",  "searchLDAP": false}' > /dev/null 2>&1
  echo "$GREEN" "[ok]" "$NORMAL"

  echo -n " adding users to teams"
  token=$(curl -sk -d '{"username":"admin","password":"'$password'"}' https://ucp.dockr.life/auth/login | jq -r .auth_token)
  curl -skX PUT "https://ucp.dockr.life/accounts/orcabank/teams/ops/members/tim" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d '{}' > /dev/null 2>&1

  curl -skX PUT "https://ucp.dockr.life/accounts/orcabank/teams/security/members/jeff" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d '{}' > /dev/null 2>&1

  curl -skX PUT "https://ucp.dockr.life/accounts/orcabank/teams/mobile/members/bob" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d '{}' > /dev/null 2>&1

  curl -skX PUT "https://ucp.dockr.life/accounts/orcabank/teams/payments/members/bob" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d '{}' > /dev/null 2>&1

  curl -skX PUT "https://ucp.dockr.life/accounts/orcabank/teams/ci/members/gitlab" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d '{}' > /dev/null 2>&1

  echo "$GREEN" "[ok]" "$NORMAL"

  echo -n " adding developer role"
  token=$(curl -sk -d '{"username":"admin","password":"'$password'"}' https://ucp.dockr.life/auth/login | jq -r .auth_token)
  dev_role_id=$(curl -skX POST "https://ucp.dockr.life/roles" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d '{"name":"developer","system_role": false,"operations": {"Container":{"Container Attach": [],"Container Exec": [],"Container Logs": [],"Container View": []},"Service": {"Service Logs": [],"Service View": [],"Service View Tasks":[]}}}' | jq -r .id)
  echo "$GREEN" "[ok]" "$NORMAL"

  echo -n " adding collections"
  token=$(curl -sk -d '{"username":"admin","password":"'$password'"}' https://ucp.dockr.life/auth/login | jq -r .auth_token)

  prod_col_id=$(curl -skX POST "https://ucp.dockr.life/collections" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d '{"name":"prod","path":"/","parent_id": "swarm"}' | jq -r .id)

  mobile_id=$(curl -skX POST "https://ucp.dockr.life/collections" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d '{"name":"mobile","path":"/prod","parent_id": "'$prod_col_id'"}' | jq -r .id)

  payments_id=$(curl -skX POST "https://ucp.dockr.life/collections" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d '{"name":"payments","path":"/prod","parent_id": "'$prod_col_id'"}' | jq -r .id)

  shared_mobile_id=$(curl -skX POST "https://ucp.dockr.life/collections" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d '{"name":"mobile","path":"/","parent_id": "shared"}' | jq -r .id)

  shared_payments_id=$(curl -skX POST "https://ucp.dockr.life/collections" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d '{"name":"payments","path":"/","parent_id": "shared"}' | jq -r .id)

  #write id to a tmp file
  echo $shared_payments_id > col_tmp.txt
  echo $shared_mobile_id >> col_tmp.txt
  echo $payments_id >> col_tmp.txt
  echo $mobile_id >> col_tmp.txt
  echo $prod_col_id >> col_tmp.txt

  echo "$GREEN" "[ok]" "$NORMAL"

  echo -n " adding grants"
  curl -skX PUT "https://ucp.dockr.life/collectionGrants/$security_team_id/$prod_col_id/viewonly" -H  "accept: application/json" -H  "Authorization: Bearer $token"

  curl -skX PUT "https://ucp.dockr.life/collectionGrants/$ops_team_id/$prod_col_id/fullcontrol" -H  "accept: application/json" -H  "Authorization: Bearer $token"

  curl -skX PUT "https://ucp.dockr.life/collectionGrants/$payments_team_id/$payments_id/$dev_role_id" -H  "accept: application/json" -H  "Authorization: Bearer $token"

  curl -skX PUT "https://ucp.dockr.life/collectionGrants/$mobile_team_id/$mobile_id/$dev_role_id" -H  "accept: application/json" -H  "Authorization: Bearer $token"
  echo "$GREEN" "[ok]" "$NORMAL"

  echo -n " adding demo repos to DTR "

  curl -skX POST -u admin:$password -H "Content-Type: application/json" -H "Accept: application/json" -d '{"name": "flask_build","shortDescription": "custom flask build","longDescription": "the best damm custom flask app ever", "enableManifestLists": false, "immutableTags": false,"visibility": "private","scanOnPush": true }' "https://dtr.dockr.life/api/v0/repositories/admin" > /dev/null 2>&1

  curl -skX POST -u admin:$password -H "Content-Type: application/json" -H "Accept: application/json" -d '{"name": "flask","shortDescription": "custom flask","longDescription": "the best damm custom flask app ever","enableManifestLists": false, "immutableTags": false, "visibility": "public","scanOnPush": true }' "https://dtr.dockr.life/api/v0/repositories/admin" > /dev/null 2>&1

  curl -skX POST -u admin:$password -H "Content-Type: application/json" -H "Accept: application/json" -d '{"name": "alpine","shortDescription": "upstream","longDescription": "upstream from hub.docker.com","visibility": "public","enableManifestLists": false, "immutableTags": false,"scanOnPush": true }' "https://dtr.dockr.life/api/v0/repositories/admin" > /dev/null 2>&1

  curl -skX POST -u admin:$password -H "Content-Type: application/json" -H "Accept: application/json" -d '{"name": "alpine_build","shortDescription": "upstream private","longDescription": "the best damm custom flask app ever","enableManifestLists": false, "immutableTags": false,"visibility": "private","scanOnPush": true }' "https://dtr.dockr.life/api/v0/repositories/admin" > /dev/null 2>&1

  curl -skX POST -u admin:$password -H "Content-Type: application/json" -H "Accept: application/json" -d '{"name": "nginx","shortDescription": "upstream nginx","longDescription": "upstream from hub.docker.com","enableManifestLists": false, "immutableTags": false,"visibility": "private","scanOnPush": true }' "https://dtr.dockr.life/api/v0/repositories/admin" > /dev/null 2>&1
  echo "$GREEN" "[ok]" "$NORMAL"

  echo -n " adding promotion policy for admin/flask_build"
  curl -skX POST -u admin:$password "https://dtr.dockr.life/api/v0/repositories/admin/flask_build/promotionPolicies?initialEvaluation=true" -H "accept: application/json" -H "content-type: application/json" -d '{ "enabled": true, "rules": [ { "field": "vulnerability_critical", "operator": "lte", "values": [ "10" ] } ], "tagTemplate": "%n", "targetRepository": "admin/flask"}' > /dev/null 2>&1

  curl -skX POST -u admin:$password "https://dtr.dockr.life/api/v0/repositories/admin/alpine_build/promotionPolicies?initialEvaluation=true" -H "accept: application/json" -H "content-type: application/json" -d '{ "enabled": true, "rules": [ { "field": "vulnerability_critical", "operator": "lte", "values": [ "0" ] } ], "tagTemplate": "%n", "targetRepository": "admin/alpine"}' > /dev/null 2>&1

  echo "$GREEN" "[ok]" "$NORMAL"


  echo -n " adding demo secret"
  curl -skX POST "https://ucp.dockr.life/secrets/create" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d '{"Data":"Z3JlYXRlc3QgZGVtbyBldmVyCg==","Labels":{"com.docker.ucp.access.label":"/prod"},"Name":"demo_title_v1"}' > /dev/null 2>&1

  echo "$GREEN" "[ok]" "$NORMAL"

}

################################ demo wipe ##############################
function wipe () {
  #clean the demo stuff

  if [ -f col_tmp.txt ]; then

    token=$(curl -sk -d '{"username":"admin","password":"'$password'"}' https://ucp.dockr.life/auth/login | jq -r .auth_token)

    echo -n " removing secrets"
    for secret_id in $(curl -skX GET "https://ucp.dockr.life/secrets" -H  "accept: application/json" -H  "Authorization: Bearer $token"| jq -r .[].ID); do
       curl -skX DELETE "https://ucp.dockr.life/secrets/$secret_id" -H  "accept: application/json" -H  "Authorization: Bearer $token"
    done
    echo "$GREEN" "[ok]" "$NORMAL"

    echo -n " removing grants"
    echo "$GREEN" "[ok]" "$NORMAL"

    echo -n " removing users and organizations"
    for user in $(curl -skX GET "https://ucp.dockr.life/accounts/?filter=all&limit=100" -H  "accept: application/json" -H  "Authorization: Bearer $token"| jq -r .accounts[].name|grep -v -E '(admin|docker-datacenter)'); do
      curl -skX DELETE "https://ucp.dockr.life/accounts/$user" -H  "accept: application/json" -H  "Authorization: Bearer $token"
    done
    echo "$GREEN" "[ok]" "$NORMAL"

    echo -n " removing collections"
    for cols in $(cat col_tmp.txt); do
       curl -skX DELETE "https://ucp.dockr.life/collections/$cols" -H  "accept: application/json" -H  "Authorization: Bearer $token"
    done
    rm -rf col_tmp.txt
    echo "$GREEN" "[ok]" "$NORMAL"

    echo -n " removing roles"
    for role in $(curl -skX GET "https://ucp.dockr.life/roles" -H  "accept: application/json" -H  "Authorization: Bearer $token"| jq -r .[].id | grep -v -E '(fullcontrol|scheduler|none|viewonly|restrictedcontrol)'); do
      curl -skX DELETE "https://ucp.dockr.life/roles/$role" -H  "accept: application/json" -H  "Authorization: Bearer $token"
    done
    echo "$GREEN" "[ok]" "$NORMAL"
  else
    echo -n " looks like nothing to remove"
    echo "$GREEN" "[ok]" "$NORMAL"
  fi
}

############################## add node ################################
function add () {
  controller1=$(sed -n 1p hosts.txt|awk '{print $1}')
  uuid=$(uuidgen| awk -F"-" '{print $2}')
  WRKTOKEN=$(cat worker_token.txt)
  ee_url=$(cat url.env)/centos

  echo -n " building vm - $prefix-$uuid "
  doctl compute droplet create $prefix-$uuid --region $zone --image $image --size $size --ssh-keys $key --wait > /dev/null 2>&1
  doctl compute droplet list|grep -v ID|grep $prefix-$uuid|awk '{print $3" "$2}' >> hosts.txt
  add_ip=$(cat hosts.txt|grep $prefix-$uuid|awk '{print $1}')
  echo "$GREEN" "[ok]" "$NORMAL"

  echo -n " checking for ssh "
    until [ $(ssh -o ConnectTimeout=1 $user@$add_ip 'exit' 2>&1 | grep 'timed out' | wc -l) = 0 ]; do echo -n "." ; sleep 5; done
  echo "$GREEN" "[ok]" "$NORMAL"

  sleep 10

  if [ "$image" = centos-7-x64 ]; then
    echo -n " updating the os and installing docker ee "
    pdsh -l $user -w $add_ip 'yum update -y; yum install -y yum-utils; echo "'$ee_url'" > /etc/yum/vars/dockerurl; echo "7" > /etc/yum/vars/dockerosversion; yum-config-manager --add-repo $(cat /etc/yum/vars/dockerurl)/docker-ee.repo; yum makecache fast; yum-config-manager --enable docker-ee-stable-17.06; yum -y install docker-ee; systemctl start docker; docker plugin disable docker/telemetry:1.0.0.linux-x86_64-stable' > /dev/null 2>&1
    echo "$GREEN" "[ok]" "$NORMAL"

    echo -n " adding overlay storage driver "
    pdsh -l $user -w $add_ip 'echo -e "{ "storage-driver": "overlay2", \n  "storage-opts": ["overlay2.override_kernel_check=true"], \n "metrics-addr" : "0.0.0.0:9323", \n "experimental" : true \n}" > /etc/docker/daemon.json; systemctl restart docker'
    echo "$GREEN" "[ok]" "$NORMAL"
  fi

  if [ "$image" = rancheros ]; then
    echo "updating rancher with the latest engine"
    pdsh -l $user -w $add_ip 'sudo ros engine switch docker-17.06.1-ce' > /dev/null 2>&1
  fi

  echo -n " joining the cluster "
  pdsh -l $user -w $add_ip "docker swarm join --token $WRKTOKEN $controller1:2377" > /dev/null 2>&1
  echo "$GREEN" "[ok]" "$NORMAL"

}

############################## kill ################################
function kill () {

if [ -f hosts.txt ]; then
  echo -n " killing it all "
  for i in $(awk '{print $2}' hosts.txt); do doctl compute droplet delete --force $i; done
  for i in $(awk '{print $1}' hosts.txt); do ssh-keygen -q -R $i > /dev/null 2>&1; done
  for i in $(doctl compute domain records list dockr.life|grep 'ucp\|dtr\|app\|gitlab'|awk '{print $1}'); do doctl compute domain records delete -f dockr.life $i; done

  if [ "$(doctl compute load-balancer list|grep lb1|wc -l| sed -e 's/^[[:space:]]*//')" = "1" ]; then
   doctl compute load-balancer delete -f $(doctl compute load-balancer list|grep -v ID|awk '{print $1}') > /dev/null 2>&1;
  fi

  rm -rf *.txt *.log *.zip *.pem *.pub env.* backup.tar kube.yml ucp-config.toml
else
  echo -n " no hosts file found "
fi
echo "$GREEN" "[ok]" "$NORMAL"
}

############################# status ################################
function status () {
  controller1=$(head -1 hosts.txt|awk '{print $1}')
  dtr_server=$(sed -n 2p hosts.txt|awk '{printf $1}')
  echo "===== Cluster ====="
  doctl compute droplet list --no-header |grep $prefix
  echo ""
  echo "===== Dashboards ====="
  echo " - UCP   : https://ucp.dockr.life"
  echo " - username : admin"
  echo " - password : "$password
  echo ""
  echo " - DTR   : https://dtr.dockr.life"
  echo ""

  if [ "$loadbalancer" = true ]; then
   echo "===== Load Balancer ====="
   echo " - http://"$(doctl compute load-balancer list|grep -v ID|awk '{print $2}')" "
   echo ""
  fi

  if [ "$minio" = true ]; then
   echo " - Minio : http://dtr.dockr.life:9000"
   echo " - Access key : $(cat min_access.txt)"
   echo " - Secret key : $(cat min_secret.txt)"
   echo ""
 fi

}

case "$1" in
        up) up;;
        kill) kill;;
        add) add;;
        status) status;;
        wipe ) wipe;;
        demo) demo;;
        *) echo "Usage: $0 {up|kill|add|demo|wipe|status}"; exit 1
esac


#aws example if you want to switch.
#aws elb register-instances-with-load-balancer --load-balancer-name clemenko-ucp-akamai --instances $(cat hosts.txt|sed -n '1p;2p;3p'|awk '{printf $3" "}') > /dev/null 2>&1
#
#aws ec2 describe-instances --filters "Name=tag:Name,Values=$prefix*" | jq -c '.Reservations[].Instances[] |[.PublicIpAddress, (.Tags[]|select(.Key=="Name")|.Value), .InstanceId, .PrivateIpAddress, .State.Name]'|jq -r '@csv'|sed -e 's/"//g' -e 's/,/   /g'|grep -v terminated|grep -v shutting-down|sort -n|awk '{print $1"   "$2"   "$3"  "$4}' > hosts.txt
#
#aws ec2 create-tags --resources $(aws ec2 run-instances --image-id ami-cdc999b6 --count 1 --user-data $'#cloud-config\nhostname: '$prefix-$uuid --instance-type m4.large --key-name clemenko --subnet-id subnet-c6f1498e --security-group-ids sg-645e211a | jq -r ".Instances[0].InstanceId" ) --tags "Key=Name,Value=$prefix-$uuid"
#
