@echo off
set DOCKER_TLS_VERIFY=1
set DOCKER_CERT_PATH=%~dp0
set DOCKER_HOST=tcp://10.0.141.58:443
REM
REM Bundle for user clemenko
REM UCP Instance ID MKPY:I7JK:Z2ZL:DL7N:UQ7P:2AW6:BFQA:JCZD:MALZ:VAML:OV7U:CKQ7
REM
REM This admin cert will also work directly against Swarm and the individual
REM engine proxies for troubleshooting.  After sourcing this env file, use
REM "docker info" to discover the location of Swarm managers and engines.
REM and use the --host option to override $DOCKER_HOST
REM
REM Run this command from within this directory to configure your shell:
REM .\env.cmd
