export DOCKER_TLS_VERIFY=1
export DOCKER_CERT_PATH="$(pwd)"
export DOCKER_HOST=tcp://10.0.141.58:443
#
# Bundle for user clemenko
# UCP Instance ID MKPY:I7JK:Z2ZL:DL7N:UQ7P:2AW6:BFQA:JCZD:MALZ:VAML:OV7U:CKQ7
#
# This admin cert will also work directly against Swarm and the individual
# engine proxies for troubleshooting.  After sourcing this env file, use
# "docker info" to discover the location of Swarm managers and engines.
# and use the --host option to override $DOCKER_HOST
#
# Run this command from within this directory to configure your shell:
# eval $(<env.sh)
