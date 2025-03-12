#!/bin/bash
export IMAGE_NAME=blockscout-backend

rm -rf output
rm -f ${IMAGE_NAME}.tar.gz
mkdir output
mkdir output/envs
mkdir output/proxy
mkdir output/services

export POSTGRES_STATS_DB=stats
export POSTGRES_STATS_USER=stats
export POSTGRES_STATS_PASSWORD=n0uejXPl61ci6ldCuE2gQU5Y
export POSTGRES_BLOCKSCOUT_DB=blockscout
export POSTGRES_BLOCKSCOUT_USER=blockscout
export POSTGRES_BLOCKSCOUT_PASSWORD=ceWb1MeLBEeOIfk65gU8EjF8
export ETHEREUM_JSONRPC_HTTP_URL=https://rpc.eightart.hk
export ETHEREUM_JSONRPC_TRACE_URL=https://rpc.eightart.hk
export CHAIN_ID=20200
export API_V2_ENABLED=true
envsubst < .env.template > ./output/.env

cp -r ../docker-compose/fisco.yml ./output/fisco.yml
cp -r ../docker-compose/envs/* ./output/envs
cp -r ../docker-compose/proxy/* ./output/proxy
cp -r ../docker-compose/services/*.yml ./output/services

docker compose -f ../docker-compose/fisco.yml build
docker save -o ./output/"${IMAGE_NAME}".tar blockscout/blockscout:latest

envsubst < start.sh.template > ./output/start.sh
envsubst < stop.sh.template > ./output/stop.sh
chmod +x ./output/stop.sh

tar -czf output.tar.gz -C ./output .