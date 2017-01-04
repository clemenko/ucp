#!/bin/bash
###################################
# edit vars
###################################
num=4  #3 or larger please!
prefix=ddc
password=Pa22word
zone=nyc1
size=1gb
key=30:98:4f:c5:47:c2:88:28:fe:3c:23:cd:52:49:51:01
image=centos-7-x64
#image=ubuntu-16-04-x64
password=Pa22word
license_file="docker_subscription.lic"

######  NO MOAR EDITS #######
################################# up ################################

function up () {
export PDSH_RCMD_TYPE=ssh
build_list=""
uuid=""
for i in $(seq 1 $num); do
 uuid=$(uuidgen| awk -F"-" '{print $2}')
 build_list="$prefix-$uuid $build_list"
done
echo " building vms - $build_list"
doctl compute droplet create $build_list --region $zone --image $image --size $size --ssh-keys $key --wait > /dev/null 2>&1
doctl compute droplet list|grep -v ID|grep $prefix|awk '{print $3" "$2}'> hosts.txt

echo -n " checking for ssh"
for ext in $(cat hosts.txt|awk '{print $1}'); do
  until [ $(ssh -o ConnectTimeout=1 root@$ext 'exit' 2>&1 | grep 'timed out' | wc -l) = 0 ]; do echo -n "." ; sleep 5; done
done
sleep 15
echo ""

host_list=$(cat hosts.txt|awk '{printf $1","}'|sed 's/,$//')

#setting nodes
controller1=$(cat hosts.txt|sed -n 1p|awk '{print $1}')
#manager2=$(cat hosts.txt|sed -n 2p|awk '{print $1}')
#manager3=$(cat hosts.txt|sed -n 3p|awk '{print $1}')
dtr_server=$(cat hosts.txt|sed -n 2p|awk '{printf $1}')
dtr_node=$(cat hosts.txt|sed -n 2p|awk '{printf $2}')

echo " adding ntp and syncing time"
pdsh -l root -w $host_list 'yum update -y; yum install -y ntp; ntpdate -s 0.centos.pool.ntp.org; systemctl start ntpd' > /dev/null 2>&1

echo " installing latest docker"
pdsh -l root -w $host_list 'curl -sSLf https://packages.docker.com/1.12/install.sh | bash;  systemctl enable docker;  systemctl start docker' > /dev/null 2>&1

echo " adding overlay storage driver"
#pdsh -l root -w $host_list ' echo "{ \"storage-driver\": \"overlay2\"}" > /etc/docker/daemon.json; systemctl restart docker'
pdsh -l root -w $host_list 'echo -e "{ \"storage-driver\": \"overlay2\", \n  \"storage-opts\": [\"overlay2.override_kernel_check=true\"]\n}" > /etc/docker/daemon.json; systemctl restart docker'

echo " starting ucp server"
ssh root@$controller1 "docker run --rm -i --name ucp -v /var/run/docker.sock:/var/run/docker.sock docker/ucp install --admin-password $password --host-address $controller1" > /dev/null 2>&1

echo " getting tokens"
MGRTOKEN=$(ssh root@$controller1 "docker swarm join-token -q manager")
WRKTOKEN=$(ssh root@$controller1 "docker swarm join-token -q worker")
echo $MGRTOKEN > manager_token.txt
echo $WRKTOKEN > worker_token.txt

#token=$(curl -sk "https://$controller1/auth/login" -X POST -d '{"username":"admin","password":"'$password'"}'|jq -r .auth_token)
#curl -sk "https://$controller1/swarm" -H "Authorization: Bearer $token"|jq .JoinTokens

sleep 10

echo " adding license"
token=$(curl -sk "https://$controller1/auth/login" -X POST -d '{"username":"admin","password":"Pa22word"}'|jq -r .auth_token)
curl -k "https://$controller1/api/config/license" -X POST -H "Authorization: Bearer $token" -d "{\"auto_refresh\":true,\"license_config\":$(cat $license_file |jq .)}"

#echo " setting up mangers"
#pdsh -l root -w $manager2,$manager3 "docker swarm join --token $MGRTOKEN $controller1:2377" > /dev/null 2>&1

sleep 10
echo " setting up nodes"
node_list=$(cat hosts.txt |sed -n 1,"$num"p|awk '{printf $1","}')
pdsh -l root -w $node_list "docker swarm join --token $WRKTOKEN $controller1:2377" > /dev/null 2>&1

echo " downloading certs"
AUTHTOKEN=$(curl -sk -d '{"username":"admin","password":"'$password'"}' https://$controller1/auth/login | jq -r .auth_token)
curl -sk -H "Authorization: Bearer $AUTHTOKEN" https://$controller1/api/clientbundle -o bundle.zip

sleep 20

echo " setting up minio"
ssh root@$dtr_server 'chmod -R 777 /opt/; docker run -d -p 9000:9000 --name minio minio/minio server /opt' > /dev/null 2>&1
min_access=$(ssh root@$dtr_server "docker logs minio |grep AccessKey |awk '{print \$2}'")
echo $min_access > min_access.txt
min_secret=$(ssh root@$dtr_server "docker logs minio |grep SecretKey |awk '{print \$2}'")
echo $min_secret > min_secret.txt

echo " building nfs server for dtr"
ssh root@$dtr_server 'chmod -R 777 /opt/; systemctl enable rpcbind nfs-server; systemctl start rpcbind nfs-server ; echo "/opt *(rw,sync,no_root_squash,no_all_squash)" > /etc/exports; systemctl restart nfs-server  ' > /dev/null 2>&1

echo " installing DTR"
unzip bundle.zip > /dev/null 2>&1
curl -sk https://$controller1/ca > ucp-ca.pem

eval $(<env.sh)
#ssh -t root@$dtr_server "curl -sk https://$controller1/ca > /root/ucp-ca.pem; docker run -it --rm docker/dtr install --ucp-url https://$controller1 --ucp-node $dtr_node --dtr-external-url $dtr_server --ucp-username admin --ucp-password $password --ucp-ca '$(cat ucp-ca.pem)' "
docker run -it --rm docker/dtr install --ucp-url https://$controller1 --ucp-node $dtr_node --dtr-external-url https://$dtr_server --ucp-username admin --ucp-password $password --ucp-ca "$(cat ucp-ca.pem)"  > /dev/null 2>&1
#--nfs-storage-url nfs://$dtr_server/opt
curl -sk https://$dtr_server/ca > dtr-ca.pem

echo " disabling scheduling on controllers"
token=$(curl -sk "https://$controller1/auth/login" -X POST -d '{"username":"admin","password":"'$password'"}'|jq -r .auth_token)
curl -k "https://$controller1/api/config/scheduling" -X POST -H "Authorization: Bearer $token" -d "{\"enable_admin_ucp_scheduling\":true,\"enable_user_ucp_scheduling\":false}"

echo " updating nodes with DTR's CA"
#Add DTR CA to all the nodes (ALL):
pdsh -l root -w $node_list "curl -sk https://$dtr_server/ca -o /etc/pki/ca-trust/source/anchors/$dtr_server.crt; update-ca-trust; systemctl restart docker" > /dev/null 2>&1
#ubuntu : curl -sk https://$dtr_server/ca -o /usr/local/share/ca-certificates/$dtr_server.crt; update-ca-certificates; systemctl restart docker

#notary notes
#add dtr_ca.pem to all the nodes.
#wget https://github.com/docker/notary/releases/download/v0.4.2/notary-Linux-amd64; mv notary-Linux-amd64 notary; chmod 755 notary
#alias notary="./notary -s https://107.170.2.91 -d ~/.docker/trust --tlscacert dtr-ca.pem"
#notary init -p 107.170.2.91/admin/alpine
#export DOCKER_CONTENT_TRUST=1
#docker tag 107.170.2.91/admin/alpine 107.170.2.91/admin/alpine:signed
#mkdir -p ~/.docker/tls/107.170.2.91/
#rsync -avP dtr-ca.pem ~/.docker/tls/107.170.2.91/ca.crt


#prometheus : https://github.com/docker/orca/blob/master/project/prometheus.md
#docker run --rm -i -v $(pwd):/data -v ucp-metrics-inventory:/inventory -v $(pwd)/prometheus.yml:/etc/prometheus/prometheus.yml -p 9090:9090 prom/prometheus


#curl notes
#curl \
#    --cert ${DOCKER_CERT_PATH}/cert.pem \
#    --key ${DOCKER_CERT_PATH}/key.pem \
#    --cacert ${DOCKER_CERT_PATH}/ca.pem \
#    ${UCP_URL}/info | jq "."

echo ""
echo "========= UCP install complete ========="
echo ""
status
}

############################## destroy ################################
function kill () {
echo " killing it all."
#doctl
for i in $(cat hosts.txt|awk '{print $2}'); do doctl compute droplet delete --force $i; done
for i in $(cat hosts.txt|awk '{print $1}'); do ssh-keygen -q -R $i > /dev/null 2>&1; done
rm -rf *.txt *.log *.zip *.pem *.pub env.* backup.tar
}

############################# status ################################
function status () {
  controller1=$(cat hosts.txt|head -1|awk '{print $1}')
  dtr_server=$(cat hosts.txt|sed -n 2p|awk '{printf $1}')
  echo "===== Cluster ====="
  doctl compute droplet list |grep $prefix
  echo ""
  echo "===== Dashboards ====="
  echo " - UCP   : https://$controller1"
  echo " - username : admin"
  echo " - password : "$password
  echo ""
  echo " - DTR   : https://$dtr_server"
  echo ""
  echo " - Minio : http://$dtr_server:9000"
  echo " - Access key : $(cat min_access.txt)"
  echo " - Secret key : $(cat min_secret.txt)"
  echo ""
}

case "$1" in
        up) up;;
        kill) kill;;
        status) status;;
        *) echo "Usage: $0 {up|kill|status}"; exit 1
esac
