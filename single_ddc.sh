#!/bin/bash
###################################
# edit vars
###################################
prefix=single
password=Pa22word
zone=nyc1
size=4gb
key=30:98:4f:c5:47:c2:88:28:fe:3c:23:cd:52:49:51:01
image=centos-7-2-x64
#image=ubuntu-16-04-x64
password=Pa22word
license_file="docker_subscription.lic"

######  NO MOAR EDITS #######
################################# up ################################

function up () {
export PDSH_RCMD_TYPE=ssh
 uuid=$(uuidgen| awk -F"-" '{print $2}')

echo " building vms - $prefix-$uuid"
doctl compute droplet create $prefix-$uuid --region $zone --image $image --size $size --ssh-keys $key --wait > /dev/null 2>&1
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

echo " adding ntp and syncing time"
pdsh -l root -w $host_list 'yum install -y ntp; ntpdate -s 0.centos.pool.ntp.org; systemctl start ntpd' > /dev/null 2>&1

echo " installing latest docker"
pdsh -l root -w $host_list 'curl -fsSL https://test.docker.com/ | bash;  systemctl enable docker;  systemctl start docker' > /dev/null 2>&1

echo " adding overlay storage driver"
pdsh -l root -w $host_list ' echo "{ \"storage-driver\": \"overlay\"}" > /etc/docker/daemon.json; systemctl restart docker'

echo " starting ucp server"
ssh root@$controller1 "docker run --rm -i --name ucp -v /var/run/docker.sock:/var/run/docker.sock docker/ucp install --admin-password $password --host-address $controller1" > /dev/null 2>&1

sleep 10
echo " adding license"
token=$(curl -sk "https://$controller1/auth/login" -X POST -d '{"username":"admin","password":"Pa22word"}'|jq -r .auth_token)
curl -k "https://$controller1/api/config/license" -X POST -H "Authorization: Bearer $token" -d "{\"auto_refresh\":true,\"license_config\":$(cat $license_file |jq .)}"

echo " downloading certs"
AUTHTOKEN=$(curl -sk -d '{"username":"admin","password":"'$password'"}' https://$controller1/auth/login | jq -r .auth_token)
curl -sk -H "Authorization: Bearer $AUTHTOKEN" https://$controller1/api/clientbundle -o bundle.zip

sleep 20

echo " installing DTR"
unzip bundle.zip > /dev/null 2>&1
curl -sk https://$controller1/ca > ucp-ca.pem

eval $(<env.sh)
#ssh -t root@$dtr_server "curl -sk https://$controller1/ca > /root/ucp-ca.pem; docker run -it --rm docker/dtr install --ucp-url https://$controller1 --ucp-node $dtr_node --dtr-external-url $dtr_server --ucp-username admin --ucp-password $password --ucp-ca '$(cat ucp-ca.pem)' "
#docker run -it --rm docker/dtr install --ucp-url https://$controller1 --ucp-node $dtr_node --dtr-external-url $controller1 --ucp-username admin --ucp-password $password --ucp-ca "$(cat ucp-ca.pem)"
#--nfs-storage-url nfs://$dtr_server/opt
#curl -sk https://$controller1/ca > dtr-ca.pem


echo " updating nodes with DTR's CA"
#Add DTR CA to all the nodes (ALL):
#pdsh -l root -w $controller1 "curl -sk https://$controller1/ca -o /etc/pki/ca-trust/source/anchors/$controller1.crt; update-ca-trust; systemctl restart docker" > /dev/null 2>&1

#notary notes
#add dtr_ca.pem to all the nodes.
#wget https://github.com/docker/notary/releases/download/v0.4.2/notary-Linux-amd64; mv notary-Linux-amd64 notary; chmod 755 notary
#alias notary="./notary -s https://107.170.2.91 -d ~/.docker/trust --tlscacert dtr-ca.pem"
#notary init -p 107.170.2.91/admin/alpine
#export DOCKER_CONTENT_TRUST=1
#docker tag 107.170.2.91/admin/alpine 107.170.2.91/admin/alpine:signed
#mkdir -p ~/.docker/tls/107.170.2.91/
#rsync -avP dtr-ca.pem ~/.docker/tls/107.170.2.91/ca.crt

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
  echo "===== Cluster ====="
  doctl compute droplet list |grep $prefix
  echo ""
  echo "===== Dashboards ====="
  echo " - UCP   : https://$controller1"
  echo " - username : admin"
  echo " - password : "$password
  echo ""
  echo " - DTR   : https://$controller1"
  echo ""
}

case "$1" in
        up) up;;
        kill) kill;;
        status) status;;
        *) echo "Usage: $0 {up|kill|status}"; exit 1
esac
