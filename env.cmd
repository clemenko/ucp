@echo off
set DOCKER_TLS_VERIFY=1
set DOCKER_CERT_PATH=%~dp0
set DOCKER_HOST=tcp://192.241.177.103:443
REM
REM Bundle for user admin
REM UCP Instance ID FFLQ:RMIG:UHVE:JW3J:LLY3:V3KR:Q3IK:PM3A:NMMT:5M2Q:SVFO:UW7S
REM
REM This admin cert will also work directly against Swarm and the individual
REM engine proxies for troubleshooting.  After sourcing this env file, use
REM "docker info" to discover the location of Swarm managers and engines.
REM and use the --host option to override $DOCKER_HOST
REM
REM Run this command from within this directory to configure your shell:
REM .\env.cmd
