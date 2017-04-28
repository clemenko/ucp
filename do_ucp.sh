#!/bin/bash
###################################
# edit vars
###################################
set -eu
num=3 #3 or larger please!
prefix=ddc
password=Pa22word
zone=nyc1
size=2gb
key=30:98:4f:c5:47:c2:88:28:fe:3c:23:cd:52:49:51:01
image=centos-7-x64
license_file="docker_subscription.lic"
ee_url=$(cat url.env)
doctl_TOKEN=$(cat ~/.config/doctl/config.yaml|awk '{print $2}')
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
  until [ $(ssh -o ConnectTimeout=1 root@$ext 'exit' 2>&1 | grep 'timed out' | wc -l) = 0 ]; do echo -n "." ; sleep 5; done
done
echo "$GREEN" "[OK]" "$NORMAL"

host_list=$(awk '{printf $1","}' hosts.txt|sed 's/,$//')

#setting nodes
controller1=$(sed -n 1p hosts.txt|awk '{print $1}')
dtr_server=$(sed -n 2p hosts.txt|awk '{printf $1}')
dtr_node=$(sed -n 2p hosts.txt|awk '{printf $2}')
hrm_server=$(sed -n 3p hosts.txt|awk '{printf $1}')

echo -n " updating dns "
curl -u "$doctl_TOKEN:" -X POST -H "Content-Type: application/json" -d '{"type":"A","name":"ucp","data":"'$controller1'","priority":null,"port":null,"ttl":300,"weight":null}' "https://api.digitalocean.com/v2/domains/shirtmullet.com/records" > /dev/null 2>&1

curl -u "$doctl_TOKEN:" -X POST -H "Content-Type: application/json" -d '{"type":"A","name":"dtr","data":"'$dtr_server'","priority":null,"port":null,"ttl":300,"weight":null}' "https://api.digitalocean.com/v2/domains/shirtmullet.com/records" > /dev/null 2>&1

#doctl compute domain records create shirtmullet.com --record-type A --record-name ucp --record-data $controller1 > /dev/null 2>&1
#doctl compute domain records create shirtmullet.com --record-type A --record-name dtr --record-data $dtr_server > /dev/null 2>&1
doctl compute domain records create shirtmullet.com --record-type A --record-name pets --record-data $hrm_server > /dev/null 2>&1
doctl compute domain records create shirtmullet.com --record-type A --record-name admin --record-data $hrm_server > /dev/null 2>&1
doctl compute domain records create shirtmullet.com --record-type A --record-name flask --record-data $hrm_server > /dev/null 2>&1
doctl compute domain records create shirtmullet.com --record-type A --record-name suntrust --record-data $hrm_server > /dev/null 2>&1
echo "$GREEN" "[OK]" "$NORMAL"

echo -n " adding ntp and syncing time "
pdsh -l root -w $host_list '#yum update -y; yum install -y ntp; ntpdate -s 0.centos.pool.ntp.org; systemctl start ntpd' > /dev/null 2>&1
echo "$GREEN" "[OK]" "$NORMAL"

#echo -n " enabling selinux"
#pdsh -l root -w $host_list 'sed -i s%disabled%enforcing% /etc/sysconfig/selinux; sed -i s%disabled%enforcing% /etc/selinux/config;shutdown now -r' > /dev/null 2>&1

#echo " updating kernel"
#pdsh -l root -w $host_list 'rpm -Uvh http://www.elrepo.org/elrepo-release-7.0-2.el7.elrepo.noarch.rpm; yum --enablerepo=elrepo-kernel install -y kernel-ml; grub2-set-default 1; reboot' > /dev/null 2>&1

#sleep 60

#for ext in $(cat hosts.txt|awk '{print $1}'); do
#  until [ $(ssh -o ConnectTimeout=1 root@$ext 'exit' 2>&1 | grep 'timed out' | wc -l) = 0 ]; do echo -n "." ; sleep 5; done
#done
#echo ""


echo -n " installing docker ee "
#pdsh -l root -w $host_list 'curl -sSLf https://packages.docker.com/1.13/install.sh | bash;  systemctl enable docker;  systemctl start docker' > /dev/null 2>&1

#EE
pdsh -l root -w $host_list 'yum install -y yum-utils; echo "'$ee_url'" > /etc/yum/vars/dockerurl; echo "7" > /etc/yum/vars/dockerosversion; yum-config-manager --add-repo $(cat /etc/yum/vars/dockerurl)/docker-ee.repo; yum makecache fast; yum -y install docker-ee; systemctl start docker' > /dev/null 2>&1
echo "$GREEN" "[OK]" "$NORMAL"


echo -n " adding overlay storage driver "
#pdsh -l root -w $host_list ' echo "{ \"storage-driver\": \"overlay\"}" > /etc/docker/daemon.json; systemctl restart docker'
pdsh -l root -w $host_list 'echo -e "{ \"storage-driver\": \"overlay2\", \n  \"storage-opts\": [\"overlay2.override_kernel_check=true\"]\n}" > /etc/docker/daemon.json; systemctl restart docker'
echo "$GREEN" "[OK]" "$NORMAL"

echo -n " starting ucp server "
ssh root@$controller1 "docker run --rm -i --name ucp -v /var/run/docker.sock:/var/run/docker.sock docker/ucp:$ucp_ver install --admin-password $password --host-address $controller1 --san ucp.shirtmullet.com" > /dev/null 2>&1
echo "$GREEN" "[OK]" "$NORMAL"

echo -n " getting tokens "
MGRTOKEN=$(ssh root@$controller1 "docker swarm join-token -q manager")
WRKTOKEN=$(ssh root@$controller1 "docker swarm join-token -q worker")
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
pdsh -l root -w $node_list "docker swarm join --token $WRKTOKEN $controller1:2377" > /dev/null 2>&1
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
#docker run -it --rm docker/dtr install --ucp-url https://ucp.shirtmullet.com --ucp-node $dtr_node --dtr-external-url https://dtr.shirtmullet.com --ucp-username admin --ucp-password $password --ucp-ca "$(cat ucp-ca.pem)" > /dev/null 2>&1

docker run -it --rm docker/dtr install --ucp-url https://ucp.shirtmullet.com --ucp-node $dtr_node --dtr-external-url https://dtr.shirtmullet.com --ucp-username admin --ucp-password $password --ucp-insecure-tls > /dev/null 2>&1


#--nfs-storage-url nfs://$dtr_server/opt
curl -sk https://$dtr_server/ca > dtr-ca.pem
echo "$GREEN" "[OK]" "$NORMAL"

echo -n " disabling scheduling on controllers "
token=$(curl -sk "https://$controller1/auth/login" -X POST -d '{"username":"admin","password":"'$password'"}'|jq -r .auth_token)
curl -k --user admin:$password "https://$controller1/api/config/scheduling" -X POST -H "Authorization: Bearer $token" -d "{\"enable_admin_ucp_scheduling\":true,\"enable_user_ucp_scheduling\":false}"
echo "$GREEN" "[OK]" "$NORMAL"

echo -n " enabling HRM"
token=$(curl -sk "https://$controller1/auth/login" -X POST -d '{"username":"admin","password":"'$password'"}'|jq -r .auth_token)
curl -k --user admin:$password "https://$controller1/api/hrm" -X POST -H 'Content-Type: application/json;charset=utf-8' -H "Authorization: Bearer $token" -d "{\"HTTPPort\":80,\"HTTPSPort\":8443}"
echo "$GREEN" "[OK]" "$NORMAL"

#echo " enabling scanning engine"
#curl -k --user admin:$password "https://$dtr_server/api/v0/meta/settings" -X POST -H 'Content-Type: application/json;charset=utf-8' -d "{\"disableBackupWarning\": true,\"scanningEnabled\":true,\"scanningSyncOnline\": true}" > /dev/null 2>&1


echo -n " updating nodes with DTR's CA "
#Add DTR CA to all the nodes (ALL):
pdsh -l root -w $node_list "curl -sk https://dtr.shirtmullet.com/ca -o /etc/pki/ca-trust/source/anchors/dtr.shirtmullet.com.crt; update-ca-trust; systemctl restart docker" > /dev/null 2>&1
echo "$GREEN" "[OK]" "$NORMAL"


#prometheus : https://github.com/docker/orca/blob/master/project/prometheus.md
#docker run --rm -i -v $(pwd):/data -v ucp-metrics-inventory:/inventory -v $(pwd)/prometheus.yml:/etc/prometheus/prometheus.yml -p 9090:9090 prom/prometheus

#curl notes
#curl \
#    --cert ${DOCKER_CERT_PATH}/cert.pem \
#    --key ${DOCKER_CERT_PATH}/key.pem \
#    --cacert ${DOCKER_CERT_PATH}/ca.pem \
#    ${UCP_URL}/info | jq "."

echo -n " adding load balancer for worker nodes - this can take a minute or two "
doctl compute load-balancer create --name lb1 --region $zone --algorithm least_connections --sticky-sessions type:none --forwarding-rules entry_protocol:http,entry_port:80,target_protocol:http,target_port:80 --health-check protocol:tcp,port:80 --droplet-ids $(doctl compute droplet list|grep -v ID|sed -n 2,4p |awk '{printf $1","}'|sed 's/.$//') > /dev/null 2>&1;
echo "$GREEN" "[OK]" "$NORMAL"

echo -n " setting up minio "
ssh root@$dtr_server 'chmod -R 777 /opt/; docker run -d -p 9000:9000 --name minio minio/minio server /opt' > /dev/null 2>&1
sleep 5
min_access=$(ssh root@$dtr_server "docker logs minio |grep AccessKey |awk '{print \$2}'")
echo $min_access > min_access.txt
min_secret=$(ssh root@$dtr_server "docker logs minio |grep SecretKey |awk '{print \$2}'")
echo $min_secret > min_secret.txt
echo "$GREEN" "[OK]" "$NORMAL"

#echo " adding certificates"
#token=$(curl -sk "https://ucp.shirtmullet.com/auth/login" -X POST -d '{"username":"admin","password":"Pa22word"}'|jq -r .auth_token)

#curl -sk 'https://ucp.shirtmullet.com/api/nodes/certs' -H 'accept-encoding: gzip, deflate, br' -H "authorization: Bearer $token" -H 'accept: application/json, text/plain, */*' --data-binary '{"ca":"-----BEGIN CERTIFICATE-----\nMIICKDCCAc6gAwIBAgIUTCPedoVlUIG+2pUhQEG6zxmnByYwCgYIKoZIzj0EAwIw\nEzERMA8GA1UEAxMIc3dhcm0tY2EwHhcNMTcwMzI5MTQwMTAwWhcNMjcwMzI3MTQw\nMTAwWjCBjjEJMAcGA1UEBhMAMQkwBwYDVQQIEwAxCTAHBgNVBAcTADFKMEgGA1UE\nChNBT3JjYTogTkFXSTpJSkpJOlFPRlE6NkdUMjpCRU1UOjVLR0Q6SEVQMzpSNkJX\nOlpYV1A6Q1lLTDpXQVVCOldTWEcxDzANBgNVBAsTBkNsaWVudDEOMAwGA1UEAxMF\nYWRtaW4wWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAT5AK9rPTEyGc1rO3wydLxQ\n0gRoicBIIwXtVDFYC1A96OIRWO4o9Fj1Va9zTzFbtfg/jsIyAWviNJ1eJ/bG2uN4\no4GDMIGAMA4GA1UdDwEB/wQEAwIFoDATBgNVHSUEDDAKBggrBgEFBQcDAjAMBgNV\nHRMBAf8EAjAAMB0GA1UdDgQWBBRlRH+HUuNWtIcw3jfifH/6DfX8jDAfBgNVHSME\nGDAWgBSbY517jcS1ZuH6+3H9l23mVW1Q6zALBgNVHREEBDACgQAwCgYIKoZIzj0E\nAwIDSAAwRQIgQGM9SnOSFbKGVDBy05e1ei9k3YFLb//q1x4CCSgcbcACIQD3YJsb\nNo8+bldNwrbUYOWxOaUIicVmUiVyk/0ejXsbQQ==\n-----END CERTIFICATE-----\n","key":"server3","cert":"server2"}' --compressed


echo ""
echo "========= UCP install complete ========="
echo ""
status
}

############################## destroy ################################
function kill () {
echo -n " killing it all "
#doctl
for i in $(awk '{print $2}' hosts.txt); do doctl compute droplet delete --force $i; done
for i in $(awk '{print $1}' hosts.txt); do ssh-keygen -q -R $i > /dev/null 2>&1; done
for i in $(doctl compute domain records list shirtmullet.com|grep 'pets\|admin\|flask\|ucp\|dtr\|suntrust'|awk '{print $1}'); do doctl compute domain records delete shirtmullet.com $i; done

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
  echo " - UCP   : https://ucp.shirtmullet.com"
  echo " - username : admin"
  echo " - password : "$password
  echo ""
  echo " - DTR   : https://dtr.shirtmullet.com"
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
        *) echo "Usage: $0 {up|kill|status}"; exit 1
esac
