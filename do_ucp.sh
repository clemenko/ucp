#!/bin/bash
###################################
# edit vars
###################################
set -e
num=3 #3 or larger please!
prefix=ddc
password=Pa22word
zone=nyc1
#size=2gb
size=s-1vcpu-3gb
key=30:98:4f:c5:47:c2:88:28:fe:3c:23:cd:52:49:51:01
license_file="docker_subscription.lic"

#image=centos-7-x64
#image=rancheros
image=coreos-stable

ucp_ver=latest
dtr_ver=latest

minio=false # true will add the minio service for testing an s3 service.
loadbalancer=false
storageos=false

######  NO MOAR EDITS #######
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
NORMAL=$(tput sgr0)

if [ "$image" = rancheros ]; then user=rancher; fi
if [ "$image" = centos-7-x64 ]; then user=root; fi
if [ "$image" = coreos-stable ]; then user=core; fi

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
 uuid=$(uuidgen| awk -F"-" '{print $2}')
 build_list="$prefix-$uuid $build_list"
done
echo -n " building vms : $build_list "
doctl compute droplet create $build_list --region $zone --image $image --size $size --ssh-keys $key --wait > /dev/null 2>&1
doctl compute droplet list|grep -v ID|grep $prefix|awk '{print $3" "$2}'> hosts.txt

echo "$GREEN" "[ok]" "$NORMAL"

sleep 15

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
doctl compute domain records create dockr.life --record-type CNAME --record-name "gitlab" --record-ttl 300 --record-data app.dockr.life. > /dev/null 2>&1

echo "$GREEN" "[ok]" "$NORMAL"

if [ "$image" = centos-7-x64 ]; then

  echo -n " updating the os and installing docker ee "
  pdsh -l $user -w $host_list 'yum update -y; yum install -y yum-utils; echo "'$ee_url'" > /etc/yum/vars/dockerurl; echo "7" > /etc/yum/vars/dockerosversion; yum-config-manager --add-repo $(cat /etc/yum/vars/dockerurl)/docker-ee.repo; yum makecache fast; yum-config-manager --enable docker-ee-stable-17.06; yum -y install docker-ee; systemctl start docker; docker plugin disable docker/telemetry:1.0.0.linux-x86_64-stable; echo "vm.swappiness=0" >> /etc/sysctl.conf; echo "vm.overcommit_memory=1" >> /etc/sysctl.conf;  echo "net.ipv4.neigh.default.gc_thresh1 = 80000" >> /etc/sysctl.conf; echo "net.ipv4.neigh.default.gc_thresh2 = 90000" >> /etc/sysctl.conf; echo "net.ipv4.neigh.default.gc_thresh3 = 100000" >> /etc/sysctl.conf; echo "net.ipv4.tcp_keepalive_time=600" >> /etc/sysctl.conf; echo "fs.may_detach_mounts=1" >> /etc/sysctl.conf; echo "fs.inotify.max_user_instances=8192" >> /etc/sysctl.conf; echo "fs.inotify.max_user_watches=1048576" >> /etc/sysctl.conf;  sysctl -p ' > /dev/null 2>&1
  echo "$GREEN" "[ok]" "$NORMAL"

  echo -n " adding overlay storage driver "
  pdsh -l $user -w $host_list 'echo -e "{\n \"storage-driver\": \"overlay2\", \n \"storage-opts\": [\"overlay2.override_kernel_check=true\"], \n \"log-driver\": \"json-file\", \"log-opts\": {\"max-size\": \"10m\", \"max-file\": \"3\"}, \n \"metrics-addr\" : \"0.0.0.0:9323\", \n \"experimental\" : true \n}" > /etc/docker/daemon.json; systemctl restart docker'
  echo "$GREEN" "[ok]" "$NORMAL"
fi

if [ "$image" = rancheros ]; then
  echo "updating rancher with the latest engine"
  pdsh -l $user -w $host_list 'sudo ros engine switch docker-17.06.1-ce' > /dev/null 2>&1
fi

echo -n " starting ucp server "
ssh $user@$controller1 "docker run --rm -i --name ucp -v /var/run/docker.sock:/var/run/docker.sock docker/ucp:$ucp_ver install --admin-password $password --host-address $controller1 --san ucp.dockr.life --disable-usage --disable-tracking" > /dev/null 2>&1
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
eval $(<env.sh) > /dev/null 2>&1
echo "$GREEN" "[ok]" "$NORMAL"

echo -n " adding license "
#token=$(curl -sk "https://$controller1/auth/login" -X POST -d '{"username":"admin","password":"'$password'"}'|jq -r .auth_token)
#curl -k "https://$controller1/api/config/license" -X POST -H "Authorization: Bearer $token" -d "{\"auto_refresh\":true,\"license_config\":$(cat $license_file |jq .)}"
docker config create com.docker.license-1 $license_file > /dev/null 2>&1
docker service update --config-add source=com.docker.license-1,target=/etc/ucp/docker.lic ucp-agent --detach=false > /dev/null 2>&1


# docker run -it --rm --name ucp -v /var/run/docker.sock:/var/run/docker.sock docker/ucp:2.2.2 install --admin-username admin --admin-password docker123 --host-address 172.245.1.52 --controller-port 4443 --disable-tracking --disable-usage --san ucp.demo.mac --san 172.245.1.52 --san 10.1.2.3 --license "$(cat /Users/mbentley/Downloads/docker_subscription.lic)"
echo "$GREEN" "[ok]" "$NORMAL"

#echo " setting up mangers"
#pdsh -l root -w $manager2,$manager3 "docker swarm join --token $MGRTOKEN $controller1:2377" > /dev/null 2>&1

sleep 30

echo -n " setting up nodes "
node_list=$(sed -n 1,"$num"p hosts.txt|awk '{printf $1","}')
pdsh -l $user -w $node_list "docker swarm join --token $WRKTOKEN $controller1:2377" > /dev/null 2>&1
echo "$GREEN" "[ok]" "$NORMAL"

sleep 60

#echo -n " building nfs server for dtr "
#ssh root@$dtr_server 'chmod -R 777 /opt/; yum -y install nfs-utils; systemctl enable rpcbind nfs-server; systemctl start rpcbind nfs-server ; echo "/opt *(rw,sync,no_root_squash,no_all_squash)" > /etc/exports; systemctl restart nfs-server' > /dev/null 2>&1
#echo "$GREEN" "[ok]" "$NORMAL"

echo -n " installing DTR "
docker run -it --rm docker/dtr:$dtr_ver install --ucp-url https://ucp.dockr.life --ucp-node $dtr_node --dtr-external-url https://dtr.dockr.life --ucp-username admin --ucp-password $password --ucp-insecure-tls > /dev/null 2>&1
#--nfs-storage-url nfs://$dtr_server/opt

curl -sk https://$dtr_server/ca > dtr-ca.pem
echo "$GREEN" "[ok]" "$NORMAL"

echo -n " disabling scheduling on controllers "
#token=$(curl -sk "https://$controller1/auth/login" -X POST -d '{"username":"admin","password":"'$password'"}'|jq -r .auth_token)
#curl -k --user admin:$password "https://$controller1/api/config/scheduling" -X POST -H "Authorization: Bearer $token" -d "{\"enable_admin_ucp_scheduling\":true,\"enable_user_ucp_scheduling\":false}"
echo "$RED" "[fix]" "$NORMAL"

echo -n " configuring garbage collection"
curl -skX POST --user admin:$password -H "Content-Type: application/json" -H "Accept: application/json"  -d "{\"action\": \"gc\",\"schedule\": \"0 0 1 * * 0\",\"retries\": 0,\"deadline\": \"\",\"stopTimeout\": \"30s\"}" "https://dtr.dockr.life/api/v0/crons"  > /dev/null 2>&1
echo "$GREEN" "[ok]" "$NORMAL"

echo -n " enabling HRM"
token=$(curl -sk "https://$controller1/auth/login" -X POST -d '{"username":"admin","password":"'$password'"}'|jq -r .auth_token)
#curl -k --user admin:$password "https://$controller1/api/hrm" -X POST -H 'Content-Type: application/json;charset=utf-8' -H "Authorization: Bearer $token" -d "{\"HTTPPort\":80,\"HTTPSPort\":8443}"
echo "$RED" "[OFF]" "$NORMAL"

echo " enabling scanning engine"
curl -k -X POST --user admin:$password "https://$dtr_server/api/v0/meta/settings" -H "Content-Type: application/json" -H "Accept: application/json"  -d "{ \"reportAnalytics\": false, \"anonymizeAnalytics\": false, \"disableBackupWarning\": true, \"scanningEnabled\": true, \"scanningSyncOnline\": true }" > /dev/null 2>&1

if [ "$image" = centos-7-x64 ]; then
  echo -n " updating nodes with DTR's CA "
  #Add DTR CA to all the nodes (ALL):
  pdsh -l $user -w $node_list "curl -sk https://dtr.dockr.life/ca -o /etc/pki/ca-trust/source/anchors/dtr.dockr.life.crt; update-ca-trust; systemctl restart docker" > /dev/null 2>&1
fi
echo "$RED" "[fix]" "$NORMAL"

#prometheus : https://github.com/docker/orca/blob/master/project/prometheus.md
#docker run --rm -i -v $(pwd):/data -v ucp-metrics-inventory:/inventory -v $(pwd)/prometheus.yml:/etc/prometheus/prometheus.yml -p 9090:9090 prom/prometheus

#curl notes
#curl \
#    --cert ${DOCKER_CERT_PATH}/cert.pem \
#    --key ${DOCKER_CERT_PATH}/key.pem \
#    --cacert ${DOCKER_CERT_PATH}/ca.pem \
#    ${UCP_URL}/info | jq "."

if [ "$loadbalancer" = true ]; then
  echo -n " adding load balancer for worker nodes - this can take a minute or two "
  doctl compute load-balancer create --name lb1 --region $zone --algorithm least_connections --sticky-sessions type:none --forwarding-rules entry_protocol:http,entry_port:80,target_protocol:http,target_port:80 --health-check protocol:tcp,port:80 --droplet-ids $(doctl compute droplet list|grep -v ID|sed -n 2,4p |awk '{printf $1","}'|sed 's/.$//') > /dev/null 2>&1;
  echo "$GREEN" "[ok]" "$NORMAL"
fi

if [ "$minio" = true ]; then
 echo -n " setting up minio "
 ssh $user@$dtr_server 'chmod -R 777 /opt/; docker run -d -p 9000:9000 --name minio minio/minio server /opt' > /dev/null 2>&1
 sleep 5
 min_access=$(ssh $user@$dtr_server "docker logs minio |grep AccessKey |awk '{print \$2}'")
 echo $min_access > min_access.txt
 min_secret=$(ssh $user@$dtr_server "docker logs minio |grep SecretKey |awk '{print \$2}'")
 echo $min_secret > min_secret.txt
 echo "$GREEN" "[ok]" "$NORMAL"
fi

echo " adding certificates"
#token=$(curl -sk "https://ucp.dockr.life/auth/login" -X POST -d '{"username":"admin","password":"Pa22word"}'|jq -r .auth_token)

#curl -sk 'https://ucp.dockr.life/api/nodes/certs' -H 'accept-encoding: gzip, deflate, br' -H "authorization: Bearer $token" -H 'accept: application/json, text/plain, */*' --data-binary '{"ca":"-----BEGIN CERTIFICATE-----\nMIICKDCCAc6gAwIBAgIUTCPedoVlUIG+2pUhQEG6zxmnByYwCgYIKoZIzj0EAwIw\nEzERMA8GA1UEAxMIc3dhcm0tY2EwHhcNMTcwMzI5MTQwMTAwWhcNMjcwMzI3MTQw\nMTAwWjCBjjEJMAcGA1UEBhMAMQkwBwYDVQQIEwAxCTAHBgNVBAcTADFKMEgGA1UE\nChNBT3JjYTogTkFXSTpJSkpJOlFPRlE6NkdUMjpCRU1UOjVLR0Q6SEVQMzpSNkJX\nOlpYV1A6Q1lLTDpXQVVCOldTWEcxDzANBgNVBAsTBkNsaWVudDEOMAwGA1UEAxMF\nYWRtaW4wWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAT5AK9rPTEyGc1rO3wydLxQ\n0gRoicBIIwXtVDFYC1A96OIRWO4o9Fj1Va9zTzFbtfg/jsIyAWviNJ1eJ/bG2uN4\no4GDMIGAMA4GA1UdDwEB/wQEAwIFoDATBgNVHSUEDDAKBggrBgEFBQcDAjAMBgNV\nHRMBAf8EAjAAMB0GA1UdDgQWBBRlRH+HUuNWtIcw3jfifH/6DfX8jDAfBgNVHSME\nGDAWgBSbY517jcS1ZuH6+3H9l23mVW1Q6zALBgNVHREEBDACgQAwCgYIKoZIzj0E\nAwIDSAAwRQIgQGM9SnOSFbKGVDBy05e1ei9k3YFLb//q1x4CCSgcbcACIQD3YJsb\nNo8+bldNwrbUYOWxOaUIicVmUiVyk/0ejXsbQQ==\n-----END CERTIFICATE-----\n","key":"server3","cert":"server2"}' --compressed
echo "$RED" "[fix]" "$NORMAL"

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

  curl -sk -X POST https://ucp.dockr.life/accounts/ -H "Authorization: Bearer $token" -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -H 'Content-Type: application/json;charset=utf-8' -d "{\"name\":\"orcabank\",\"isOrg\":true}" > /dev/null 2>&1

  ops_team_id=$(curl -sk -X POST https://ucp.dockr.life/accounts/orcabank/teams -H "Authorization: Bearer $token" -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -H 'Content-Type: application/json;charset=utf-8' -d "{\"name\":\"ops\",\"description\":\"ops team of awesomeness\"}" | jq -r .id)

  mobile_team_id=$(curl -sk -X POST https://ucp.dockr.life/accounts/orcabank/teams -H "Authorization: Bearer $token" -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -H 'Content-Type: application/json;charset=utf-8' -d "{\"name\":\"mobile\",\"description\":\"dev team of awesomeness\"}" | jq -r .id)

  payments_team_id=$(curl -sk -X POST https://ucp.dockr.life/accounts/orcabank/teams -H "Authorization: Bearer $token" -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -H 'Content-Type: application/json;charset=utf-8' -d "{\"name\":\"payments\",\"description\":\"dev team of awesomeness\"}" | jq -r .id)

  security_team_id=$(curl -sk -X POST https://ucp.dockr.life/accounts/orcabank/teams -H "Authorization: Bearer $token" -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -H 'Content-Type: application/json;charset=utf-8' -d "{\"name\":\"security\",\"description\":\"security team of awesomeness\"}" | jq -r .id)

  ci_team_id=$(curl -sk -X POST https://ucp.dockr.life/accounts/orcabank/teams -H "Authorization: Bearer $token" -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -H 'Content-Type: application/json;charset=utf-8' -d "{\"name\":\"ci\",\"description\":\"ci team of awesomeness\"}" | jq -r .id)

  echo "$GREEN" "[ok]" "$NORMAL"

  echo -n " adding users"
  token=$(curl -sk -d '{"username":"admin","password":"'$password'"}' https://ucp.dockr.life/auth/login | jq -r .auth_token)
  curl -skX POST https://ucp.dockr.life/api/accounts -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -H 'Content-Type: application/json;charset=utf-8' -H "Authorization: Bearer $token" -d  "{\"role\":1,\"username\":\"bob\",\"password\":\"Pa22word\",\"first_name\":\"bob developer\"}"

  curl -skX POST https://ucp.dockr.life/api/accounts -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -H 'Content-Type: application/json;charset=utf-8' -H "Authorization: Bearer $token" -d  "{\"role\":1,\"username\":\"tim\",\"password\":\"Pa22word\",\"first_name\":\"tim ops\"}"

  curl -skX POST https://ucp.dockr.life/api/accounts -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -H 'Content-Type: application/json;charset=utf-8' -H "Authorization: Bearer $token" -d  "{\"role\":1,\"username\":\"jeff\",\"password\":\"Pa22word\",\"first_name\":\"jeff security\"}"

  curl -skX POST https://ucp.dockr.life/api/accounts -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -H 'Content-Type: application/json;charset=utf-8' -H "Authorization: Bearer $token" -d  "{\"role\":1,\"username\":\"andy\",\"password\":\"Pa22word\",\"first_name\":\"andy admin\"}"

  curl -skX POST https://ucp.dockr.life/api/accounts -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -H 'Content-Type: application/json;charset=utf-8' -H "Authorization: Bearer $token" -d  "{\"role\":1,\"username\":\"gitlab\",\"password\":\"Pa22word\",\"first_name\":\"gitlab ci\"}"
  echo "$GREEN" "[ok]" "$NORMAL"

  echo -n " adding users to teams"
  token=$(curl -sk -d '{"username":"admin","password":"'$password'"}' https://ucp.dockr.life/auth/login | jq -r .auth_token)
  curl -skX PUT "https://ucp.dockr.life/accounts/orcabank/teams/ops/members/tim" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d "{}" > /dev/null 2>&1

  curl -skX PUT "https://ucp.dockr.life/accounts/orcabank/teams/security/members/jeff" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d "{}" > /dev/null 2>&1

  curl -skX PUT "https://ucp.dockr.life/accounts/orcabank/teams/mobile/members/bob" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d "{}" > /dev/null 2>&1

  curl -skX PUT "https://ucp.dockr.life/accounts/orcabank/teams/payments/members/bob" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d "{}" > /dev/null 2>&1

  curl -skX PUT "https://ucp.dockr.life/accounts/orcabank/teams/ci/members/gitlab" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d "{}" > /dev/null 2>&1

  echo "$GREEN" "[ok]" "$NORMAL"

  echo -n " adding developer role"
  token=$(curl -sk -d '{"username":"admin","password":"'$password'"}' https://ucp.dockr.life/auth/login | jq -r .auth_token)
  dev_role_id=$(curl -skX POST "https://ucp.dockr.life/roles" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d "{\"name\":\"developer\",\"system_role\": false,\"operations\": {\"Container\":{\"Container Attach\": [],\"Container Exec\": [],\"Container Logs\": [],\"Container View\": []},\"Service\": {\"Service Logs\": [],\"Service View\": [],\"Service View Tasks\":[]}}}" | jq -r .id)
  echo "$GREEN" "[ok]" "$NORMAL"

  echo -n " adding collections"
  token=$(curl -sk -d '{"username":"admin","password":"'$password'"}' https://ucp.dockr.life/auth/login | jq -r .auth_token)

  prod_col_id=$(curl -skX POST "https://ucp.dockr.life/collections" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d "{\"name\":\"prod\",\"path\":\"/\",\"parent_id\": \"swarm\"}" | jq -r .id)

  mobile_id=$(curl -skX POST "https://ucp.dockr.life/collections" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d "{\"name\":\"mobile\",\"path\":\"/prod\",\"parent_id\": \"$prod_col_id\"}" | jq -r .id)

  payments_id=$(curl -skX POST "https://ucp.dockr.life/collections" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d "{\"name\":\"payments\",\"path\":\"/prod\",\"parent_id\": \"$prod_col_id\"}" | jq -r .id)

  shared_mobile_id=$(curl -skX POST "https://ucp.dockr.life/collections" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d "{\"name\":\"mobile\",\"path\":\"/\",\"parent_id\": \"shared\"}" | jq -r .id)

  shared_payments_id=$(curl -skX POST "https://ucp.dockr.life/collections" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d "{\"name\":\"payments\",\"path\":\"/\",\"parent_id\": \"shared\"}" | jq -r .id)

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

  curl -skX PUT -u admin:$password -H "Content-Type: application/json" -H "Accept: application/json" -d "{\"name\": \"flask_build\",\"shortDescription\": \"custom flask build\",\"longDescription\": \"the best damm custom flask app ever\",\"visibility\": \"private\",\"scanOnPush\": true }" "https://dtr.dockr.life/api/v0/repositories/admin" > /dev/null 2>&1

  curl -skX PUT -u admin:$password -H "Content-Type: application/json" -H "Accept: application/json" -d "{\"name\": \"flask\",\"shortDescription\": \"custom flask\",\"longDescription\": \"the best damm custom flask app ever\",\"visibility\": \"public\",\"scanOnPush\": true }" "https://dtr.dockr.life/api/v0/repositories/admin" > /dev/null 2>&1

  curl -skX PUT -u admin:$password -H "Content-Type: application/json" -H "Accept: application/json" -d "{\"name\": \"alpine\",\"shortDescription\": \"upstream\",\"longDescription\": \"upstream from hub.docker.com\",\"visibility\": \"public\",\"scanOnPush\": true }" "https://dtr.dockr.life/api/v0/repositories/admin" > /dev/null 2>&1

  curl -skX PUT -u admin:$password -H "Content-Type: application/json" -H "Accept: application/json" -d "{\"name\": \"alpine_build\",\"shortDescription\": \"upstream private\",\"longDescription\": \"the best damm custom flask app ever\",\"visibility\": \"private\",\"scanOnPush\": true }" "https://dtr.dockr.life/api/v0/repositories/admin" > /dev/null 2>&1

  curl -skX PUT -u admin:$password -H "Content-Type: application/json" -H "Accept: application/json" -d "{\"name\": \"nginx\",\"shortDescription\": \"upstream nginx\",\"longDescription\": \"upstream from hub.docker.com\",\"visibility\": \"private\",\"scanOnPush\": true }" "https://dtr.dockr.life/api/v0/repositories/admin" > /dev/null 2>&1

  echo "$GREEN" "[ok]" "$NORMAL"

  echo -n " adding demo secret"
  curl -skX PUT "https://ucp.dockr.life/secrets/create" -H  "accept: application/json" -H  "Authorization: Bearer $token" -H  "content-type: application/json" -d "{\"Data\":\"Z3JlYXRlc3QgZGVtbyBldmVyCg==\",\"Labels\":{\"com.docker.ucp.access.label\":\"/prod\"},\"Name\":\"demo_title_v1\"}" > /dev/null 2>&1

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
    pdsh -l $user -w $add_ip 'echo -e "{ \"storage-driver\": \"overlay2\", \n  \"storage-opts\": [\"overlay2.override_kernel_check=true\"], \n \"metrics-addr\" : \"0.0.0.0:9323\", \n \"experimental\" : true \n}" > /etc/docker/daemon.json; systemctl restart docker'
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

############################## destroy ################################
function kill () {

if [ -f hosts.txt ]; then
  echo -n " killing it all "
  for i in $(awk '{print $2}' hosts.txt); do doctl compute droplet delete --force $i; done
  for i in $(awk '{print $1}' hosts.txt); do ssh-keygen -q -R $i > /dev/null 2>&1; done
  for i in $(doctl compute domain records list dockr.life|grep 'ucp\|dtr\|app\|gitlab'|awk '{print $1}'); do doctl compute domain records delete -f dockr.life $i; done

  if [ "$(doctl compute load-balancer list|grep lb1|wc -l| sed -e 's/^[[:space:]]*//')" = "1" ]; then
   doctl compute load-balancer delete -f $(doctl compute load-balancer list|grep -v ID|awk '{print $1}') > /dev/null 2>&1;
  fi

  rm -rf *.txt *.log *.zip *.pem *.pub env.* backup.tar
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
  doctl compute droplet list |grep $prefix
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
   echo " - Minio : http://$dtr_server:9000"
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
