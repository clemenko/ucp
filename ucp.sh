#!/bin/bash
###################################
# edit vars
###################################
num=5  #4 or larger please!
prefix=ucp
password=Pa22word
zone=nyc2
size=1gb
key=30:98:4f:c5:47:c2:88:28:fe:3c:23:cd:52:49:51:01
#image=centos-7-2-x64
image=ubuntu-16-04-x64
password=Pa22word
license_file="docker_subscription.lic"

######  NO MOAR EDITS #######
################################# up ################################
function build () {
 uuid=$(uuidgen| awk -F"-" '{print $1}')
 echo " building : $prefix-$uuid "
 doctl compute droplet create $prefix-$uuid --region $zone --image $image --size $size --ssh-keys $key  > /dev/null 2>&1
}

function up () {
export PDSH_RCMD_TYPE=ssh
secret=$(uuidgen|sed 's/-//g')
echo $secret > secret.txt

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

#setting nodes
manager1=$(cat hosts.txt|sed -n 1p|awk '{print $1}')
manager2=$(cat hosts.txt|sed -n 2p|awk '{print $1}')
manager3=$(cat hosts.txt|sed -n 3p|awk '{print $1}')
dtr_server=$(cat hosts.txt|sed -n 4p|awk '{printf $1}')
dtr_node=$(cat hosts.txt|sed -n 4p|awk '{printf $2}')

echo " installing latest docker"
pdsh -l root -w $host_list 'curl -fsSL https://experimental.docker.com/ | sh; systemctl enable docker; systemctl start docker' > /dev/null 2>&1

echo " starting ucp server."

fingerprint=$(ssh root@$manager1 "docker run --rm -i --name ucp -v /var/run/docker.sock:/var/run/docker.sock docker/ucp install --admin-password $password --host-address $manager1" 2>&1 |grep Fingerprint|awk '{print $7}'|sed -e 's/Fingerprint=//g' -e 's/"//g')

sleep 5

echo " adding licenses."
token=$(curl -sk "https://$manager1/auth/login" -X POST -d '{"username":"admin","password":"Pa22word"}'|jq -r .auth_token)
curl -k "https://$manager1/api/config/license" -X POST -H "Authorization: Bearer $token" -d "{\"auto_refresh\":true,\"license_config\":$(cat $license_file |jq .)}"

echo " backing up controller CA's"
ssh root@$manager1 'echo yes|docker run --rm -i --name ucp -v /var/run/docker.sock:/var/run/docker.sock docker/ucp backup --root-ca-only --passphrase "'$secret'" > /tmp/backup.tar' > /dev/null 2>&1
rsync -avP root@$manager1:/tmp/backup.tar . > /dev/null 2>&1

echo " setting up mangers"
rsync -avP backup.tar root@$manager2:/tmp > /dev/null 2>&1
rsync -avP backup.tar root@$manager3:/tmp > /dev/null 2>&1
ssh -t root@$manager2 "docker run --rm -it --name ucp -v /var/run/docker.sock:/var/run/docker.sock -v /tmp/backup.tar:/backup.tar docker/ucp join --admin-username admin --admin-password $password --fingerprint $fingerprint --url https://$manager1 --replica --passphrase $secret"
ssh -t root@$manager3 "docker run --rm -it --name ucp -v /var/run/docker.sock:/var/run/docker.sock -v /tmp/backup.tar:/backup.tar docker/ucp join --admin-username admin --admin-password $password --fingerprint $fingerprint --url https://$manager1 --replica --passphrase $secret"

echo " setting up nodes."
node_list=$(cat hosts.txt |sed -n 3,"$num"p|awk '{printf $1","}')
pdsh -l root -w $node_list "docker run --rm -i --name ucp -v /var/run/docker.sock:/var/run/docker.sock docker/ucp join --admin-username admin --admin-password $password --fingerprint $fingerprint --url https://$manager1" > /dev/null 2>&1

echo " downloading certs"
AUTHTOKEN=$(curl -sk -d '{"username":"admin","password":"'$password'"}' https://$manager1/auth/login | jq -r .auth_token)
curl -sk -H "Authorization: Bearer $AUTHTOKEN" https://$manager1/api/clientbundle -o bundle.zip

echo -n " restarting docker daemons"
pdsh -l root -w $host_list "sudo systemctl restart docker"
until [ $(curl -sk https://$manager1/ca|grep BEGIN|wc -l) = 1 ]; do echo -n "."; sleep 5; done
echo ""

echo " installing DTR"
unzip bundle.zip > /dev/null 2>&1
curl -sk https://$manager1/ca > ucp-ca.pem
sed -i '/DOCKER_HOST/a export DOCKER_API_VERSION=1.23' env.sh
eval $(<env.sh)
export DOCKER_API_VERSION=1.23
docker run -it --rm docker/dtr install --ucp-url https://$manager1 --ucp-node $dtr_node --dtr-external-url $dtr_server --ucp-username admin --ucp-password $password --ucp-ca "$(cat ucp-ca.pem)" > /dev/null 2>&1

echo ""
echo "========= UCP install complete ========="
echo ""
status
}

############################## destroy ################################
function kill () {
echo " killing it all."
for i in $(cat hosts.txt|awk '{print $2}'); do doctl compute droplet delete $i; done
for i in $(cat hosts.txt|awk '{print $1}'); do ssh-keygen -q -R $i > /dev/null 2>&1; done
rm -rf *.txt *.log *.zip *.pem *.pub env.* backup.tar
}

############################# status ################################
function status () {
  manager1=$(cat hosts.txt|head -1|awk '{print $1}')
  dtr_server=$(cat hosts.txt|sed -n 4p|awk '{printf $1}')
  echo "===== Cluster ====="
  doctl compute droplet list |grep $prefix
  echo ""
  echo "===== Dashboards ====="
  echo " - UCP   : https://$manager1"
  echo " - username : admin"
  echo " - password : "$password
  echo ""
  echo " - DTR   : https://$dtr_server"
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
