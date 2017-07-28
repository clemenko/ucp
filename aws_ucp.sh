#!/bin/bash
###################################
# edit vars
###################################
num=10 #4 or larger please!
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
 aws ec2 create-tags --resources $(aws ec2 run-instances --image-id ami-13be557e --count 1 --user-data $'#cloud-config\nhostname: '$prefix-$uuid --instance-type m4.large --key-name clemenko --subnet-id subnet-c6f1498e --security-group-ids sg-645e211a | jq -r ".Instances[0].InstanceId" ) --tags "Key=Name,Value=$prefix-$uuid"
 sleep 5
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
dtr_node1=$(cat hosts.txt|sed -n 4p|awk '{printf $2}')
dtr_node2=$(cat hosts.txt|sed -n 5p|awk '{printf $2}')
dtr_server2=$(cat hosts.txt|sed -n 5p|awk '{printf $1}')
dtr_node3=$(cat hosts.txt|sed -n 6p|awk '{printf $2}')
dtr_server3=$(cat hosts.txt|sed -n 6p|awk '{printf $1}')

echo -n " adding instances to ucp elb"
aws elb register-instances-with-load-balancer --load-balancer-name clemenko-ucp-akamai --instances $(cat hosts.txt|sed -n '1p;2p;3p'|awk '{printf $3" "}') > /dev/null 2>&1
echo "$GREEN" "[OK]" "$NORMAL"

echo -n " adding instances to dtr elb"
aws elb register-instances-with-load-balancer --load-balancer-name clemenko-dtr-akamai --instances $(cat hosts.txt|sed -n '4p;5p;6p'|awk '{printf $3" "}') > /dev/null 2>&1
echo "$GREEN" "[OK]" "$NORMAL"

echo -n " adding instances to app elb"
aws elb register-instances-with-load-balancer --load-balancer-name clemenko-app-akamai --instances $(cat hosts.txt|sed -n '7p;8p;9p;10p'|awk '{printf $3" "}') > /dev/null 2>&1
echo "$GREEN" "[OK]" "$NORMAL"

echo -n " installing docker ee "
pdsh -l ubuntu -w $host_list "sudo apt-get install -y apt-transport-https curl software-properties-common && curl -fsSL $ee_url/ubuntu/gpg | sudo apt-key add - && sudo add-apt-repository \"deb [arch=amd64] $ee_url/ubuntu "'$(lsb_release -cs)'" stable-17.03\" && sudo apt update && sudo apt upgrade -y && sudo apt install -y docker-ee && sudo systemctl enable docker" > /dev/null 2>&1
echo "$GREEN" "[OK]" "$NORMAL"

echo -n " starting ucp server "
ssh ubuntu@$manager1 "sudo docker run --rm -i --name ucp -v /var/run/docker.sock:/var/run/docker.sock docker/ucp:$ucp_ver install --admin-password $password --host-address $manager1 --san $manager1 --san ucp.dockr.life --disable-usage --disable-tracking && sudo shutdown now -r" > /dev/null 2>&1
echo "$GREEN" "[OK]" "$NORMAL"

sleep 30

echo -n " restarting manager"
until [ $(ssh -o ConnectTimeout=1 ubuntu@$manager1 'exit' 2>&1 | grep 'timed out' | wc -l) = 0 ]; do echo -n "." ; sleep 5; done
echo "$GREEN" "[OK]" "$NORMAL"

sleep 30

echo -n " getting tokens "
MGRTOKEN=$(ssh ubuntu@$manager1 "sudo docker swarm join-token -q manager")
WRKTOKEN=$(ssh ubuntu@$manager1 "sudo docker swarm join-token -q worker")
echo $MGRTOKEN > manager_token.txt
echo $WRKTOKEN > worker_token.txt
echo "$GREEN" "[OK]" "$NORMAL"

sleep 30

echo -n " adding license "
token=$(curl -sk "https://$manager1/auth/login" -X POST -d '{"username":"admin","password":"'$password'"}'|jq -r .auth_token)
curl -k "https://$manager1/api/config/license" -X POST -H "Authorization: Bearer $token" -d "{\"auto_refresh\":true,\"license_config\":$(cat $license_file |jq .)}"
echo "$GREEN" "[OK]" "$NORMAL"


echo -n " setting up mangers"
ssh ubuntu@$manager2 "sudo docker swarm join --token $MGRTOKEN --advertise-addr $manager2 $manager1:2377" > /dev/null 2>&1
ssh ubuntu@$manager3 "sudo docker swarm join --token $MGRTOKEN --advertise-addr $manager3 $manager1:2377" > /dev/null 2>&1
echo "$GREEN" "[OK]" "$NORMAL"

sleep 30

echo -n " setting up nodes "
node_list=$(sed -n 4,"$num"p hosts.txt|awk '{printf $1","}')
pdsh -l ubuntu -w $node_list "sudo docker swarm join --token $WRKTOKEN $manager1:2377" > /dev/null 2>&1
echo "$GREEN" "[OK]" "$NORMAL"

sleep 60

echo -n " downloading client bundle "
AUTHTOKEN=$(curl -sk -d '{"username":"admin","password":"'$password'"}' https://ucp.dockr.life/auth/login | jq -r .auth_token)
curl -sk -H "Authorization: Bearer $AUTHTOKEN" https://ucp.dockr.life/api/clientbundle -o bundle.zip
echo "$GREEN" "[OK]" "$NORMAL"

sleep 60

echo -n " installing DTR "
unzip bundle.zip > /dev/null 2>&1
eval $(<env.sh)

docker run -it --rm docker/dtr install --ucp-url https://ucp.dockr.life --ucp-node $dtr_node1 --dtr-external-url https://dtr.dockr.life --ucp-username admin --ucp-password $password --ucp-insecure-tls > /dev/null 2>&1

curl -sk https://$dtr_server/ca > dtr-ca.pem
echo "$GREEN" "[OK]" "$NORMAL"

sleep 30

echo -n " adding dtr certificates"
curl -skX POST --user admin:$password 'https://dtr.dockr.life/api/v0/meta/settings' -H 'Host: dtr.dockr.life' -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -H 'Content-Type: application/json;charset=utf-8' -d {"dtrHost":"dtr.dockr.life","httpProxy":"","httpsProxy":"","noProxy":"","disableBackupWarning":true,"reportAnalytics":true,"anonymizeAnalytics":false,"webTLSCert":"-----BEGIN CERTIFICATE-----\nMIIGPjCCBSagAwIBAgISA1sW85GPstQn6rSW6ezQbvNuMA0GCSqGSIb3DQEBCwUA\nMEoxCzAJBgNVBAYTAlVTMRYwFAYDVQQKEw1MZXQncyBFbmNyeXB0MSMwIQYDVQQD\nExpMZXQncyBFbmNyeXB0IEF1dGhvcml0eSBYMzAeFw0xNzA1MTIxODQ5MDBaFw0x\nNzA4MTAxODQ5MDBaMBsxGTAXBgNVBAMTEHd3dy5jbGVtZW5rby5jb20wggEiMA0G\nCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDlT/otQEvBNM+LkI4tCjWAzWhFBmeI\n2CwcbB7nPLyq+TITwWSKac1P89S0vlvELRVmoHwHMCrsn+8j1XUKDIGLDwcKoQVN\nFSTL6/AMlUjnDjFhJjBp/T6EPK2eTEXW33pmpzMqMLKCeG0qGjI9OpGZBqS4TV0a\nDFYqgdCM3LMNQk09SJOk4o7QeVFfwWs0f3Qyiemo8fYbIpz7I9ztmUDn9t7Ya2Pg\nzMpvyhurBHAcrsLjlj7rp/eaCSvGmIb3b3lWrS2t84wVpg/vv2dnkBlZ1QW5Im9j\nY7QYGB7vutUb7TywC9F759XAx+p2UgR+5pRzcJ0Bhd86WuhwsHODuySjAgMBAAGj\nggNLMIIDRzAOBgNVHQ8BAf8EBAMCBaAwHQYDVR0lBBYwFAYIKwYBBQUHAwEGCCsG\nAQUFBwMCMAwGA1UdEwEB/wQCMAAwHQYDVR0OBBYEFBxhdLv3MbQlQnsnvBkff0mt\nwhaWMB8GA1UdIwQYMBaAFKhKamMEfd265tE5t6ZFZe/zqOyhMHAGCCsGAQUFBwEB\nBGQwYjAvBggrBgEFBQcwAYYjaHR0cDovL29jc3AuaW50LXgzLmxldHNlbmNyeXB0\nLm9yZy8wLwYIKwYBBQUHMAKGI2h0dHA6Ly9jZXJ0LmludC14My5sZXRzZW5jcnlw\ndC5vcmcvMIIBUwYDVR0RBIIBSjCCAUaCCmFuZHljLmluZm+CDGNsZW1lbmtvLmNv\nbYIMY2xlbWVua28ubmV0ggpkb2Nrci5saWZlgg5kdHIuZG9ja3IubGlmZYIOZHlu\nYXNwbGludC5uZXSCDmR5bmFzcGxpbnQub3JnghBmbGFzay5kb2Nrci5saWZlgg5r\nZW5ueWNsYW1wLmNvbYIPc2hpcnRtdWxsZXQuY29tgg51Y3AuZG9ja3IubGlmZYIJ\nd2F2ZmQub3Jngg53d3cuYW5keWMuaW5mb4IQd3d3LmNsZW1lbmtvLmNvbYIQd3d3\nLmNsZW1lbmtvLm5ldIISd3d3LmR5bmFzcGxpbnQubmV0ghJ3d3cuZHluYXNwbGlu\ndC5vcmeCEnd3dy5rZW5ueWNsYW1wLmNvbYITd3d3LnNoaXJ0bXVsbGV0LmNvbYIN\nd3d3LndhdmZkLm9yZzCB/gYDVR0gBIH2MIHzMAgGBmeBDAECATCB5gYLKwYBBAGC\n3xMBAQEwgdYwJgYIKwYBBQUHAgEWGmh0dHA6Ly9jcHMubGV0c2VuY3J5cHQub3Jn\nMIGrBggrBgEFBQcCAjCBngyBm1RoaXMgQ2VydGlmaWNhdGUgbWF5IG9ubHkgYmUg\ncmVsaWVkIHVwb24gYnkgUmVseWluZyBQYXJ0aWVzIGFuZCBvbmx5IGluIGFjY29y\nZGFuY2Ugd2l0aCB0aGUgQ2VydGlmaWNhdGUgUG9saWN5IGZvdW5kIGF0IGh0dHBz\nOi8vbGV0c2VuY3J5cHQub3JnL3JlcG9zaXRvcnkvMA0GCSqGSIb3DQEBCwUAA4IB\nAQAtds0zpBaNCcxxdEMuhtC3BBVRyXtal0DoSlrs7CWqlLtVGEhqbZNVWtb1Y/kQ\nWy+315cQgFHmsTxXc17DnNwqGkw2tN8hmSaEqZaZCjAv2MXYlTnAZWtL/mL4pl0b\nNQp32RWshUDxUirFid/KpEgvz6OFAJ4/GEA1T7P5yd6IPhzZRNPcoO7xqvE/kdal\nhU0RoedhqyBoNe/6sUwkv7W2ekIxNxZRsVf092GVwRB/lxxBhbLsLn4eQGhqdwIQ\nqG1XOpB6sEOaHse6mFEYfvgNH7OwACI0rySrc/HMg0S4LHJAypPARW5E5skMxk/h\nnlZyR+E/4lan+Z5U4svsmeCl\n-----END CERTIFICATE-----","webTLSKey":"-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDlT/otQEvBNM+L\nkI4tCjWAzWhFBmeI2CwcbB7nPLyq+TITwWSKac1P89S0vlvELRVmoHwHMCrsn+8j\n1XUKDIGLDwcKoQVNFSTL6/AMlUjnDjFhJjBp/T6EPK2eTEXW33pmpzMqMLKCeG0q\nGjI9OpGZBqS4TV0aDFYqgdCM3LMNQk09SJOk4o7QeVFfwWs0f3Qyiemo8fYbIpz7\nI9ztmUDn9t7Ya2PgzMpvyhurBHAcrsLjlj7rp/eaCSvGmIb3b3lWrS2t84wVpg/v\nv2dnkBlZ1QW5Im9jY7QYGB7vutUb7TywC9F759XAx+p2UgR+5pRzcJ0Bhd86Wuhw\nsHODuySjAgMBAAECggEAXd32L83Q9L60cpHy0RcLvbTXiOHNQeQTcnMD124yYN5v\nFE0m5c3XgHH0USRXFh/KUd9BxgN+nqv9TTLUnQ9ve8fj/wLY06vjCyKCefQmCobx\nya3DRa+nhqP8Af+A2ytRxHGO7SdP+z5mmURt6khuTzC7/sGUadRA9Vd8Uh0JolQK\nQ4g9hFXfUF5Mh4EVLAak/qS2wP4Cscy0FmIAKnqaWiSq5SEHj7lOPuiphwwj9VE2\naRuh3xXMwBn6S1tuV8l73NuNPK9sbS6NA7WT8hV2KClZ3dsqd1Jova3m9z97Ju2C\nTUFVaUONCEKPWYNjIJxx1era48fy0CYgsp0nXKqVkQKBgQDy905p3JusTH/6KVPb\noNYThIRqM2J19UW9F7XRYhdB8wQf0noOGw8D9VBcftnJR2dciA+vnqP3mHZNGOEH\nnD5Eo48rlcV+EmmeqfPCduGJfq8SLwZKlHWxq8pLnsG8rlIPiQGfT5HEmxzPuuEQ\nd4Q5S0B82I9LwvLnezqIjYx2uwKBgQDxnSnRkJeK3T1I/vhN3YEUNkOqD3AIMHrd\nA+cPNtt8/4zF+OEsPFkNndxKDwRd2zZ5S+xLPGoi5RnieS1+shk6hHWZWjLy9BoK\nGGVDx8c/FNGrrAid0r96oXNGK36wOAIq8Nw7eyic1XneQod1SxL57HkjWcjorl9S\nSJZ8reNPOQKBgA4nji/opEETa9k9Ex+WbSJR9Azj1XadxWRQv0zldAlpiPH5pxav\nSN6oKfhZg4KQYFspqhBHI7JG9Y1kR6fT2GTTSoH1hb3kgLa3m/XWSylhcf2TM8Cg\niYLCSVTCePLvDOTOzINldU6I4tLPRlFZRSC5W5ZqX17AirolmbFe3bIFAoGAFW1O\nrBsalWIRcUvLUXx3WgeF8Kr10IQcIUWbVCoVRPyUy2nK7lVbwG1jf93dEUXDivZE\nulddQkL3DLKaakX5HstocnUhV5J2TLblJCGvddSu036qNPTfrkxrIKnyzkXpS02Y\n+l1tuJrl9+QGh0xlHmzuQUhRHPF52p49WklBg2ECgYEAqL/DaJqL0pC2lfu3ziCa\nc+nFiiAG7q7V4JD7dSi4KsMyZ5FoMXFhJpNeBtxYnL7OhEOFYQLth6JBJezOV0GL\nxymxHC5gH5j+J+EWysPOtoAOub5Vfcb5WCCoeImRgqQ60u1MUNrjA2M+DfrKvIkx\nr7Dtx25q6I+DYC18aPZ2Scg=\n-----END PRIVATE KEY-----","webTLSCA":"-----BEGIN CERTIFICATE-----\nMIIEkjCCA3qgAwIBAgIQCgFBQgAAAVOFc2oLheynCDANBgkqhkiG9w0BAQsFADA/\nMSQwIgYDVQQKExtEaWdpdGFsIFNpZ25hdHVyZSBUcnVzdCBDby4xFzAVBgNVBAMT\nDkRTVCBSb290IENBIFgzMB4XDTE2MDMxNzE2NDA0NloXDTIxMDMxNzE2NDA0Nlow\nSjELMAkGA1UEBhMCVVMxFjAUBgNVBAoTDUxldCdzIEVuY3J5cHQxIzAhBgNVBAMT\nGkxldCdzIEVuY3J5cHQgQXV0aG9yaXR5IFgzMIIBIjANBgkqhkiG9w0BAQEFAAOC\nAQ8AMIIBCgKCAQEAnNMM8FrlLke3cl03g7NoYzDq1zUmGSXhvb418XCSL7e4S0EF\nq6meNQhY7LEqxGiHC6PjdeTm86dicbp5gWAf15Gan/PQeGdxyGkOlZHP/uaZ6WA8\nSMx+yk13EiSdRxta67nsHjcAHJyse6cF6s5K671B5TaYucv9bTyWaN8jKkKQDIZ0\nZ8h/pZq4UmEUEz9l6YKHy9v6Dlb2honzhT+Xhq+w3Brvaw2VFn3EK6BlspkENnWA\na6xK8xuQSXgvopZPKiAlKQTGdMDQMc2PMTiVFrqoM7hD8bEfwzB/onkxEz0tNvjj\n/PIzark5McWvxI0NHWQWM6r6hCm21AvA2H3DkwIDAQABo4IBfTCCAXkwEgYDVR0T\nAQH/BAgwBgEB/wIBADAOBgNVHQ8BAf8EBAMCAYYwfwYIKwYBBQUHAQEEczBxMDIG\nCCsGAQUFBzABhiZodHRwOi8vaXNyZy50cnVzdGlkLm9jc3AuaWRlbnRydXN0LmNv\nbTA7BggrBgEFBQcwAoYvaHR0cDovL2FwcHMuaWRlbnRydXN0LmNvbS9yb290cy9k\nc3Ryb290Y2F4My5wN2MwHwYDVR0jBBgwFoAUxKexpHsscfrb4UuQdf/EFWCFiRAw\nVAYDVR0gBE0wSzAIBgZngQwBAgEwPwYLKwYBBAGC3xMBAQEwMDAuBggrBgEFBQcC\nARYiaHR0cDovL2Nwcy5yb290LXgxLmxldHNlbmNyeXB0Lm9yZzA8BgNVHR8ENTAz\nMDGgL6AthitodHRwOi8vY3JsLmlkZW50cnVzdC5jb20vRFNUUk9PVENBWDNDUkwu\nY3JsMB0GA1UdDgQWBBSoSmpjBH3duubRObemRWXv86jsoTANBgkqhkiG9w0BAQsF\nAAOCAQEA3TPXEfNjWDjdGBX7CVW+dla5cEilaUcne8IkCJLxWh9KEik3JHRRHGJo\nuM2VcGfl96S8TihRzZvoroed6ti6WqEBmtzw3Wodatg+VyOeph4EYpr/1wXKtx8/\nwApIvJSwtmVi4MFU5aMqrSDE6ea73Mj2tcMyo5jMd6jmeWUHK8so/joWUoHOUgwu\nX4Po1QYz+3dszkDqMp4fklxBwXRsW10KXzPMTZ+sOPAveyxindmjkW8lGy+QsRlG\nPfZ+G6Z6h7mjem0Y+iWlkYcV4PIWL1iwBi8saCbGS5jN2p8M+X+Q7UNKEkROb3N6\nKOqkqm57TH2H3eDJAkSnh6/DNFu0Qg==\n-----END CERTIFICATE-----","disableUpgrades":false}
echo "$GREEN" "[OK]" "$NORMAL"

sleep 30

echo -n " adding dtr replicas"
replica_id=$(docker inspect $(docker ps|grep dtr-api|awk '{print $1}')|jq -r .[].Config.Env|grep DTR_REPLICA_ID|head -1|sed -e 's/  "DTR_REPLICA_ID=//g' -e 's/",//g')

ssh -t ubuntu@$dtr_server2 "sudo docker run -it --rm docker/dtr:2.2.4 join --ucp-node $dtr_node2 --ucp-url https://ucp.dockr.life --ucp-username admin --ucp-password $password --ucp-insecure-tls --existing-replica-id $replica_id" > /dev/null 2>&1
ssh -t ubuntu@$dtr_server3 "sudo docker run -it --rm docker/dtr:2.2.4 join --ucp-node $dtr_node3 --ucp-url https://ucp.dockr.life --ucp-username admin --ucp-password $password --ucp-insecure-tls --existing-replica-id $replica_id" > /dev/null 2>&1
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
pdsh -l ubuntu -w $node_list "curl -sk https://$dtr_server/ca -o /etc/pki/ca-trust/source/anchors/dtr.dockr.life.crt; update-ca-trust; systemctl restart docker" > /dev/null 2>&1
echo "$GREEN" "[OK]" "$NORMAL"

echo -n " adding ucp certificates"
token=$(curl -sk "https://ucp.dockr.life/auth/login" -X POST -d '{"username":"admin","password":"Pa22word"}'|jq -r .auth_token)
curl -sk 'https://ucp.dockr.life/api/nodes/certs' -H 'accept-encoding: gzip, deflate, br' -H "authorization: Bearer $token" -H 'accept: application/json, text/plain, */*' -d '{"ca":"-----BEGIN CERTIFICATE-----\nMIIEkjCCA3qgAwIBAgIQCgFBQgAAAVOFc2oLheynCDANBgkqhkiG9w0BAQsFADA/\nMSQwIgYDVQQKExtEaWdpdGFsIFNpZ25hdHVyZSBUcnVzdCBDby4xFzAVBgNVBAMT\nDkRTVCBSb290IENBIFgzMB4XDTE2MDMxNzE2NDA0NloXDTIxMDMxNzE2NDA0Nlow\nSjELMAkGA1UEBhMCVVMxFjAUBgNVBAoTDUxldCdzIEVuY3J5cHQxIzAhBgNVBAMT\nGkxldCdzIEVuY3J5cHQgQXV0aG9yaXR5IFgzMIIBIjANBgkqhkiG9w0BAQEFAAOC\nAQ8AMIIBCgKCAQEAnNMM8FrlLke3cl03g7NoYzDq1zUmGSXhvb418XCSL7e4S0EF\nq6meNQhY7LEqxGiHC6PjdeTm86dicbp5gWAf15Gan/PQeGdxyGkOlZHP/uaZ6WA8\nSMx+yk13EiSdRxta67nsHjcAHJyse6cF6s5K671B5TaYucv9bTyWaN8jKkKQDIZ0\nZ8h/pZq4UmEUEz9l6YKHy9v6Dlb2honzhT+Xhq+w3Brvaw2VFn3EK6BlspkENnWA\na6xK8xuQSXgvopZPKiAlKQTGdMDQMc2PMTiVFrqoM7hD8bEfwzB/onkxEz0tNvjj\n/PIzark5McWvxI0NHWQWM6r6hCm21AvA2H3DkwIDAQABo4IBfTCCAXkwEgYDVR0T\nAQH/BAgwBgEB/wIBADAOBgNVHQ8BAf8EBAMCAYYwfwYIKwYBBQUHAQEEczBxMDIG\nCCsGAQUFBzABhiZodHRwOi8vaXNyZy50cnVzdGlkLm9jc3AuaWRlbnRydXN0LmNv\nbTA7BggrBgEFBQcwAoYvaHR0cDovL2FwcHMuaWRlbnRydXN0LmNvbS9yb290cy9k\nc3Ryb290Y2F4My5wN2MwHwYDVR0jBBgwFoAUxKexpHsscfrb4UuQdf/EFWCFiRAw\nVAYDVR0gBE0wSzAIBgZngQwBAgEwPwYLKwYBBAGC3xMBAQEwMDAuBggrBgEFBQcC\nARYiaHR0cDovL2Nwcy5yb290LXgxLmxldHNlbmNyeXB0Lm9yZzA8BgNVHR8ENTAz\nMDGgL6AthitodHRwOi8vY3JsLmlkZW50cnVzdC5jb20vRFNUUk9PVENBWDNDUkwu\nY3JsMB0GA1UdDgQWBBSoSmpjBH3duubRObemRWXv86jsoTANBgkqhkiG9w0BAQsF\nAAOCAQEA3TPXEfNjWDjdGBX7CVW+dla5cEilaUcne8IkCJLxWh9KEik3JHRRHGJo\nuM2VcGfl96S8TihRzZvoroed6ti6WqEBmtzw3Wodatg+VyOeph4EYpr/1wXKtx8/\nwApIvJSwtmVi4MFU5aMqrSDE6ea73Mj2tcMyo5jMd6jmeWUHK8so/joWUoHOUgwu\nX4Po1QYz+3dszkDqMp4fklxBwXRsW10KXzPMTZ+sOPAveyxindmjkW8lGy+QsRlG\nPfZ+G6Z6h7mjem0Y+iWlkYcV4PIWL1iwBi8saCbGS5jN2p8M+X+Q7UNKEkROb3N6\nKOqkqm57TH2H3eDJAkSnh6/DNFu0Qg==\n-----END CERTIFICATE-----\n","key":"-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDlT/otQEvBNM+L\nkI4tCjWAzWhFBmeI2CwcbB7nPLyq+TITwWSKac1P89S0vlvELRVmoHwHMCrsn+8j\n1XUKDIGLDwcKoQVNFSTL6/AMlUjnDjFhJjBp/T6EPK2eTEXW33pmpzMqMLKCeG0q\nGjI9OpGZBqS4TV0aDFYqgdCM3LMNQk09SJOk4o7QeVFfwWs0f3Qyiemo8fYbIpz7\nI9ztmUDn9t7Ya2PgzMpvyhurBHAcrsLjlj7rp/eaCSvGmIb3b3lWrS2t84wVpg/v\nv2dnkBlZ1QW5Im9jY7QYGB7vutUb7TywC9F759XAx+p2UgR+5pRzcJ0Bhd86Wuhw\nsHODuySjAgMBAAECggEAXd32L83Q9L60cpHy0RcLvbTXiOHNQeQTcnMD124yYN5v\nFE0m5c3XgHH0USRXFh/KUd9BxgN+nqv9TTLUnQ9ve8fj/wLY06vjCyKCefQmCobx\nya3DRa+nhqP8Af+A2ytRxHGO7SdP+z5mmURt6khuTzC7/sGUadRA9Vd8Uh0JolQK\nQ4g9hFXfUF5Mh4EVLAak/qS2wP4Cscy0FmIAKnqaWiSq5SEHj7lOPuiphwwj9VE2\naRuh3xXMwBn6S1tuV8l73NuNPK9sbS6NA7WT8hV2KClZ3dsqd1Jova3m9z97Ju2C\nTUFVaUONCEKPWYNjIJxx1era48fy0CYgsp0nXKqVkQKBgQDy905p3JusTH/6KVPb\noNYThIRqM2J19UW9F7XRYhdB8wQf0noOGw8D9VBcftnJR2dciA+vnqP3mHZNGOEH\nnD5Eo48rlcV+EmmeqfPCduGJfq8SLwZKlHWxq8pLnsG8rlIPiQGfT5HEmxzPuuEQ\nd4Q5S0B82I9LwvLnezqIjYx2uwKBgQDxnSnRkJeK3T1I/vhN3YEUNkOqD3AIMHrd\nA+cPNtt8/4zF+OEsPFkNndxKDwRd2zZ5S+xLPGoi5RnieS1+shk6hHWZWjLy9BoK\nGGVDx8c/FNGrrAid0r96oXNGK36wOAIq8Nw7eyic1XneQod1SxL57HkjWcjorl9S\nSJZ8reNPOQKBgA4nji/opEETa9k9Ex+WbSJR9Azj1XadxWRQv0zldAlpiPH5pxav\nSN6oKfhZg4KQYFspqhBHI7JG9Y1kR6fT2GTTSoH1hb3kgLa3m/XWSylhcf2TM8Cg\niYLCSVTCePLvDOTOzINldU6I4tLPRlFZRSC5W5ZqX17AirolmbFe3bIFAoGAFW1O\nrBsalWIRcUvLUXx3WgeF8Kr10IQcIUWbVCoVRPyUy2nK7lVbwG1jf93dEUXDivZE\nulddQkL3DLKaakX5HstocnUhV5J2TLblJCGvddSu036qNPTfrkxrIKnyzkXpS02Y\n+l1tuJrl9+QGh0xlHmzuQUhRHPF52p49WklBg2ECgYEAqL/DaJqL0pC2lfu3ziCa\nc+nFiiAG7q7V4JD7dSi4KsMyZ5FoMXFhJpNeBtxYnL7OhEOFYQLth6JBJezOV0GL\nxymxHC5gH5j+J+EWysPOtoAOub5Vfcb5WCCoeImRgqQ60u1MUNrjA2M+DfrKvIkx\nr7Dtx25q6I+DYC18aPZ2Scg=\n-----END PRIVATE KEY-----\n","cert":"-----BEGIN CERTIFICATE-----\nMIIGPjCCBSagAwIBAgISA1sW85GPstQn6rSW6ezQbvNuMA0GCSqGSIb3DQEBCwUA\nMEoxCzAJBgNVBAYTAlVTMRYwFAYDVQQKEw1MZXQncyBFbmNyeXB0MSMwIQYDVQQD\nExpMZXQncyBFbmNyeXB0IEF1dGhvcml0eSBYMzAeFw0xNzA1MTIxODQ5MDBaFw0x\nNzA4MTAxODQ5MDBaMBsxGTAXBgNVBAMTEHd3dy5jbGVtZW5rby5jb20wggEiMA0G\nCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDlT/otQEvBNM+LkI4tCjWAzWhFBmeI\n2CwcbB7nPLyq+TITwWSKac1P89S0vlvELRVmoHwHMCrsn+8j1XUKDIGLDwcKoQVN\nFSTL6/AMlUjnDjFhJjBp/T6EPK2eTEXW33pmpzMqMLKCeG0qGjI9OpGZBqS4TV0a\nDFYqgdCM3LMNQk09SJOk4o7QeVFfwWs0f3Qyiemo8fYbIpz7I9ztmUDn9t7Ya2Pg\nzMpvyhurBHAcrsLjlj7rp/eaCSvGmIb3b3lWrS2t84wVpg/vv2dnkBlZ1QW5Im9j\nY7QYGB7vutUb7TywC9F759XAx+p2UgR+5pRzcJ0Bhd86WuhwsHODuySjAgMBAAGj\nggNLMIIDRzAOBgNVHQ8BAf8EBAMCBaAwHQYDVR0lBBYwFAYIKwYBBQUHAwEGCCsG\nAQUFBwMCMAwGA1UdEwEB/wQCMAAwHQYDVR0OBBYEFBxhdLv3MbQlQnsnvBkff0mt\nwhaWMB8GA1UdIwQYMBaAFKhKamMEfd265tE5t6ZFZe/zqOyhMHAGCCsGAQUFBwEB\nBGQwYjAvBggrBgEFBQcwAYYjaHR0cDovL29jc3AuaW50LXgzLmxldHNlbmNyeXB0\nLm9yZy8wLwYIKwYBBQUHMAKGI2h0dHA6Ly9jZXJ0LmludC14My5sZXRzZW5jcnlw\ndC5vcmcvMIIBUwYDVR0RBIIBSjCCAUaCCmFuZHljLmluZm+CDGNsZW1lbmtvLmNv\nbYIMY2xlbWVua28ubmV0ggpkb2Nrci5saWZlgg5kdHIuZG9ja3IubGlmZYIOZHlu\nYXNwbGludC5uZXSCDmR5bmFzcGxpbnQub3JnghBmbGFzay5kb2Nrci5saWZlgg5r\nZW5ueWNsYW1wLmNvbYIPc2hpcnRtdWxsZXQuY29tgg51Y3AuZG9ja3IubGlmZYIJ\nd2F2ZmQub3Jngg53d3cuYW5keWMuaW5mb4IQd3d3LmNsZW1lbmtvLmNvbYIQd3d3\nLmNsZW1lbmtvLm5ldIISd3d3LmR5bmFzcGxpbnQubmV0ghJ3d3cuZHluYXNwbGlu\ndC5vcmeCEnd3dy5rZW5ueWNsYW1wLmNvbYITd3d3LnNoaXJ0bXVsbGV0LmNvbYIN\nd3d3LndhdmZkLm9yZzCB/gYDVR0gBIH2MIHzMAgGBmeBDAECATCB5gYLKwYBBAGC\n3xMBAQEwgdYwJgYIKwYBBQUHAgEWGmh0dHA6Ly9jcHMubGV0c2VuY3J5cHQub3Jn\nMIGrBggrBgEFBQcCAjCBngyBm1RoaXMgQ2VydGlmaWNhdGUgbWF5IG9ubHkgYmUg\ncmVsaWVkIHVwb24gYnkgUmVseWluZyBQYXJ0aWVzIGFuZCBvbmx5IGluIGFjY29y\nZGFuY2Ugd2l0aCB0aGUgQ2VydGlmaWNhdGUgUG9saWN5IGZvdW5kIGF0IGh0dHBz\nOi8vbGV0c2VuY3J5cHQub3JnL3JlcG9zaXRvcnkvMA0GCSqGSIb3DQEBCwUAA4IB\nAQAtds0zpBaNCcxxdEMuhtC3BBVRyXtal0DoSlrs7CWqlLtVGEhqbZNVWtb1Y/kQ\nWy+315cQgFHmsTxXc17DnNwqGkw2tN8hmSaEqZaZCjAv2MXYlTnAZWtL/mL4pl0b\nNQp32RWshUDxUirFid/KpEgvz6OFAJ4/GEA1T7P5yd6IPhzZRNPcoO7xqvE/kdal\nhU0RoedhqyBoNe/6sUwkv7W2ekIxNxZRsVf092GVwRB/lxxBhbLsLn4eQGhqdwIQ\nqG1XOpB6sEOaHse6mFEYfvgNH7OwACI0rySrc/HMg0S4LHJAypPARW5E5skMxk/h\nnlZyR+E/4lan+Z5U4svsmeCl\n-----END CERTIFICATE-----\n"}'

echo "$GREEN" "[OK]" "$NORMAL"

echo ""
echo "========= UCP install complete ========="
echo ""
status

}

function demo () {
  controller1=$(sed -n 1p hosts.txt|awk '{print $1}')
  eval $(<env.sh)

  echo -n " adding devop team with permission label"
  token=$(curl -sk -d '{"username":"admin","password":"'$password'"}' https://$controller1/auth/login | jq -r .auth_token)
  team_id=$(curl -sk -X POST -H "Authorization: Bearer $token" 'https://ucp.dockr.life/enzi/v0/accounts/docker-datacenter/teams' -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -H 'Content-Type: application/json;charset=utf-8' -d "{\"name\":\"devops\"}" |jq -r .id)

  token=$(curl -sk -d '{"username":"admin","password":"'$password'"}' https://$controller1/auth/login | jq -r .auth_token)
  curl -k -X POST -H "Authorization: Bearer $token" "https://ucp.dockr.life/api/teamlabels/$team_id/prod" -H 'Accept: application/json, text/plain, */*' -H 'Accept-Language: en-US,en;q=0.5' --compressed -d "2"
  echo "$GREEN" "[OK]" "$NORMAL"

  echo -n " adding devop team with permission label"
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
echo -n " killing it all."
#doctl
#for i in $(cat hosts.txt|awk '{print $2}'); do doctl compute droplet delete $i; done
#aws
for i in $(cat hosts.txt|awk '{print $3}'); do aws ec2 terminate-instances --instance-ids $i > /dev/null 2>&1; done

for i in $(cat hosts.txt|awk '{print $1}'); do ssh-keygen -q -R $i > /dev/null 2>&1; done
rm -rf *.txt *.log *.zip ca.pem cert.pem dtr-ca.pem key.pem ucp-ca.pem *.pub env.* backup.tar
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
  echo " - UCP   : https://ucp.dockr.life"
  echo " - username : admin"
  echo " - password : "$password
  echo ""
  echo " - DTR   : https://dtr.dockr.life"
  echo " - username : admin"
  echo " - password : "$password
  echo ""
}

case "$1" in
        up) up;;
        kill) kill;;
        status) status;;
        demo) demo;;
        *) echo "Usage: $0 {up|kill|demo|status}"; exit 1
esac
