$Env:DOCKER_TLS_VERIFY = "1"
$Env:DOCKER_CERT_PATH = $(Split-Path $script:MyInvocation.MyCommand.Path)
$Env:DOCKER_HOST = "tcp://192.241.177.103:443"
#
# Bundle for user admin
# UCP Instance ID FFLQ:RMIG:UHVE:JW3J:LLY3:V3KR:Q3IK:PM3A:NMMT:5M2Q:SVFO:UW7S
#
# This admin cert will also work directly against Swarm and the individual
# engine proxies for troubleshooting.  After sourcing this env file, use
# "docker info" to discover the location of Swarm managers and engines.
# and use the --host option to override $DOCKER_HOST
#
# Run this command from within this directory to configure your shell:
# Import-Module .\env.ps1
