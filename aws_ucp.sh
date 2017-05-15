#!/bin/bash
###################################
# edit vars
###################################
num=5  #4 or larger please!
prefix=clem-akamai
password=Pa22word
image=ubuntu-16-04-x64
password=Pa22word
license_file="docker_subscription.lic"
ee_url=$(cat url.env)
ucp_ver=latest

######  NO MOAR EDITS #######
################################# up ################################
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
NORMAL=$(tput sgr0)

function build_aws () {
 uuid=$(uuidgen| awk -F"-" '{print $2}')
 echo -n " building : $prefix-$uuid "
 aws ec2 create-tags --resources $(aws ec2 run-instances --image-id ami-13be557e --count 1 --user-data $'#cloud-config\nhostname: '$prefix-$uuid --instance-type t2.small --key-name clemenko --subnet-id subnet-63475c15 --security-group-ids sg-5dba8726 | jq -r ".Instances[0].InstanceId" ) --tags "Key=Name,Value=$prefix-$uuid"
 sleep 2
 echo "$GREEN" "[OK]" "$NORMAL"
}

function up () {
export PDSH_RCMD_TYPE=ssh

 if [ -f hosts.txt ]; then echo "hosts.txt found. Are you sure you want to override it? "; exit; fi

 #build
 for i in $(seq 1 $num); do
   build_aws
 done

sleep 20
aws ec2 describe-instances --filters "Name=tag:Name,Values=$prefix*" | jq -c '.Reservations[].Instances[] |[.PublicIpAddress, (.Tags[]|select(.Key=="Name")|.Value), .InstanceId, .PrivateIpAddress, .State.Name]'|jq -r '@csv'|sed -e 's/"//g' -e 's/,/   /g'|grep -v terminated|grep -v shutting-down|sort -n|awk '{print $1"   "$2"   "$3"  "$4}' > hosts.txt

echo -n " checking for ssh."
for ext in $(cat hosts.txt|awk '{print $1}'); do
  until [ $(ssh -o ConnectTimeout=1 ubuntu@$ext 'exit' 2>&1 | grep 'timed out' | wc -l) = 0 ]; do echo -n "." ; sleep 5; done
done
sleep 20
echo "$GREEN" "[OK]" "$NORMAL"

host_list=$(cat hosts.txt|awk '{printf $1","}'|sed 's/,$//')

#setting nodes
manager1=$(cat hosts.txt|sed -n 1p|awk '{print $1}')
manager2=$(cat hosts.txt|sed -n 2p|awk '{print $1}')
manager3=$(cat hosts.txt|sed -n 3p|awk '{print $1}')
dtr_server=$(cat hosts.txt|sed -n 4p|awk '{printf $1}')
dtr_node=$(cat hosts.txt|sed -n 4p|awk '{printf $2}')

echo -n " installing docker ee "
pdsh -l ubuntu -w $host_list 'echo "$(sudo ifconfig eth0|grep -w inet|awk '"'"'{print $2}'"'"'|awk -F":" '"'"'{print $2}'"'"') $(hostname)" |sudo tee -a /etc/hosts' > /dev/null 2>&1

pdsh -l ubuntu -w $host_list "sudo apt-get install -y apt-transport-https curl software-properties-common && curl -fsSL $ee_url/ubuntu/gpg | sudo apt-key add - && sudo add-apt-repository \"deb [arch=amd64] $ee_url/ubuntu "'$(lsb_release -cs)'" stable-17.03\" && sudo apt update && sudo apt upgrade -y && sudo apt install -y docker-ee && sudo systemctl enable docker" > /dev/null 2>&1
echo "$GREEN" "[OK]" "$NORMAL"

echo -n " starting ucp server "
ssh ubuntu@$manager1 "sudo docker run --rm -i --name ucp -v /var/run/docker.sock:/var/run/docker.sock docker/ucp:$ucp_ver install --admin-password $password --host-address $manager1 --san $manager1 --san ucp.dockr.life --disable-usage --disable-tracking && sudo shutdown now -r" > /dev/null 2>&1
echo "$GREEN" "[OK]" "$NORMAL"

sleep 30

echo -n " restarting manager"
until [ $(ssh -o ConnectTimeout=1 ubuntu@$manager1 'exit' 2>&1 | grep 'timed out' | wc -l) = 0 ]; do echo -n "." ; sleep 5; done
echo "$GREEN" "[OK]" "$NORMAL"

echo -n " getting tokens "
MGRTOKEN=$(ssh ubuntu@$manager1 "sudo docker swarm join-token -q manager")
WRKTOKEN=$(ssh ubuntu@$manager1 "sudo docker swarm join-token -q worker")
echo $MGRTOKEN > manager_token.txt
echo $WRKTOKEN > worker_token.txt
echo "$GREEN" "[OK]" "$NORMAL"

sleep 10

echo -n " adding license "
token=$(curl -sk "https://$manager1/auth/login" -X POST -d '{"username":"admin","password":"'$password'"}'|jq -r .auth_token)
curl -k "https://$manager1/api/config/license" -X POST -H "Authorization: Bearer $token" -d "{\"auto_refresh\":true,\"license_config\":$(cat $license_file |jq .)}"
echo "$GREEN" "[OK]" "$NORMAL"

echo -n " setting up mangers"
ssh ubuntu@$manager2 "sudo docker swarm join --token $MGRTOKEN --advertise-addr $manager2 $manager1:2377" > /dev/null 2>&1
ssh ubuntu@$manager3 "sudo docker swarm join --token $MGRTOKEN --advertise-addr $manager3 $manager1:2377" > /dev/null 2>&1
echo "$GREEN" "[OK]" "$NORMAL"

sleep 10
echo -n " setting up nodes "
node_list=$(sed -n 4,"$num"p hosts.txt|awk '{printf $1","}')
pdsh -l ubuntu -w $node_list "sudo docker swarm join --token $WRKTOKEN $manager1:2377" > /dev/null 2>&1
echo "$GREEN" "[OK]" "$NORMAL"

echo -n " downloading client bundle "
AUTHTOKEN=$(curl -sk -d '{"username":"admin","password":"'$password'"}' https://$manager1/auth/login | jq -r .auth_token)
curl -sk -H "Authorization: Bearer $AUTHTOKEN" https://$manager1/api/clientbundle -o bundle.zip
echo "$GREEN" "[OK]" "$NORMAL"

sleep 60

echo -n " installing DTR "
unzip bundle.zip > /dev/null 2>&1
curl -sk https://$manager1/ca > ucp-ca.pem

eval $(<env.sh)
#docker run -it --rm docker/dtr install --ucp-url https://ucp.shirtmullet.com --ucp-node $dtr_node --dtr-external-url https://dtr.shirtmullet.com --ucp-username admin --ucp-password $password --ucp-ca "$(cat ucp-ca.pem)" > /dev/null 2>&1

docker run -it --rm docker/dtr install --ucp-url https://$manager1 --ucp-node $dtr_node --dtr-external-url https://$dtr_server --ucp-username admin --ucp-password $password --ucp-insecure-tls > /dev/null 2>&1

curl -sk https://$dtr_server/ca > dtr-ca.pem
echo "$GREEN" "[OK]" "$NORMAL"

echo -n " disabling scheduling on controllers "
token=$(curl -sk "https://$manager1/auth/login" -X POST -d '{"username":"admin","password":"'$password'"}'|jq -r .auth_token)
curl -k --user admin:$password "https://$manager1/api/config/scheduling" -X POST -H "Authorization: Bearer $token" -d "{\"enable_admin_ucp_scheduling\":true,\"enable_user_ucp_scheduling\":false}"
echo "$GREEN" "[OK]" "$NORMAL"

echo -n " enabling HRM"
token=$(curl -sk "https://$manager1/auth/login" -X POST -d '{"username":"admin","password":"'$password'"}'|jq -r .auth_token)
curl -k --user admin:$password "https://$manager1/api/hrm" -X POST -H 'Content-Type: application/json;charset=utf-8' -H "Authorization: Bearer $token" -d "{\"HTTPPort\":80,\"HTTPSPort\":8443}"
echo "$GREEN" "[OK]" "$NORMAL"

#echo " enabling scanning engine"
#curl -X POST --user admin:$password -h "Content-Type: application/json" -h "Accept: application/json"  -d "{ \"reportAnalytics\": false, \"anonymizeAnalytics\": false, \"disableBackupWarning\": true, \"scanningEnabled\": true, \"scanningSyncOnline\": true }" "https://$dtr_server/api/v0/meta/settings"

echo -n " updating nodes with DTR's CA "
#Add DTR CA to all the nodes (ALL):
pdsh -l ubuntu -w $node_list "curl -sk https://$dtr_server/ca -o /etc/pki/ca-trust/source/anchors/dtr.shirtmullet.com.crt; update-ca-trust; systemctl restart docker" > /dev/null 2>&1
echo "$GREEN" "[OK]" "$NORMAL"

echo ""
echo "========= UCP install complete ========="
echo ""
status

}

############################## destroy ################################
function kill () {
echo -n " killing it all."
#doctl
#for i in $(cat hosts.txt|awk '{print $2}'); do doctl compute droplet delete $i; done
#aws
for i in $(cat hosts.txt|awk '{print $3}'); do aws ec2 terminate-instances --instance-ids $i > /dev/null 2>&1; done

for i in $(cat hosts.txt|awk '{print $1}'); do ssh-keygen -q -R $i > /dev/null 2>&1; done
rm -rf *.txt *.log *.zip *.pem *.pub env.* backup.tar
echo "$GREEN" "[OK]" "$NORMAL"

}

############################# status ################################
function status () {
  manager1=$(cat hosts.txt|head -1|awk '{print $1}')
  dtr_server=$(cat hosts.txt|sed -n 4p|awk '{printf $1}')
  echo "===== Cluster ====="
  aws ec2 describe-instances --filters "Name=tag:Name,Values=$prefix*" | jq -c '.Reservations[].Instances[] |[.PublicIpAddress, (.Tags[]|select(.Key=="Name")|.Value), .InstanceId, .State.Name]'|jq -r '@csv'|sed -e 's/"//g' -e 's/,/   /g'|grep -v terminated|grep -v shutting-down|sort -n|awk '{print $1"   "$2"   "$3}'
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
