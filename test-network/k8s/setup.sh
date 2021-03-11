minikube start --mount-string /home/kalogeropoulos/Projects/hlf/fabric-samples:/host  --mount
eval $(minikube -p minikube docker-env)
cd k8s

kubectl apply -f namespace.yaml

kubectl apply -f ca/

# Wait for pods to be created --> kubectl get pods --namespace hyperledger

cd ../
. organizations/fabric-ca/registerEnroll-k8s.sh
createOrg1
createOrg2
createOrderer

#Generate Consortium Genesis Block

export FABRIC_CFG_PATH=${PWD}/configtx
configtxgen -profile TwoOrgsOrdererGenesis -channelID system-channel -outputBlock ./system-genesis-block/genesis.block

cd k8s
#Bring Up Test Network Components
 kubectl apply -f orderer/
 kubectl apply -f org1/
 kubectl apply -f org2/
 
 # Wait for pods to be created --> kubectl get pods --namespace hyperledger

 cd ../

# Create channel transaction
export CHANNEL_NAME=mychannel
configtxgen -profile TwoOrgsChannel -outputCreateChannelTx ./channel-artifacts/${CHANNEL_NAME}.tx -channelID $CHANNEL_NAME

export FABRIC_CFG_PATH=${PWD}/configtx
. scripts/envVar.sh

# Create channel
export FABRIC_CFG_PATH=$PWD/../config/

#### setGlobals 1
export CORE_PEER_TLS_ENABLED=true
export ORDERER_CA=${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem

export PEER0_ORG1_CA=${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
export CORE_PEER_LOCALMSPID="Org1MSP"
export CORE_PEER_TLS_ROOTCERT_FILE=$PEER0_ORG1_CA
export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
export CORE_PEER_ADDRESS=192.168.49.2.nip.io:30005
####

peer channel create -o 192.168.49.2.nip.io:30004 -c $CHANNEL_NAME --ordererTLSHostnameOverride 192.168.49.2.nip.io -f ./channel-artifacts/${CHANNEL_NAME}.tx --outputBlock ./channel-artifacts/${CHANNEL_NAME}.block --tls --cafile $ORDERER_CA

# Join channel Org1
export CORE_PEER_LOCALMSPID="Org1MSP"
export PEER0_ORG1_CA=${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
export CORE_PEER_TLS_ROOTCERT_FILE=$PEER0_ORG1_CA
export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
export CORE_PEER_ADDRESS=192.168.49.2.nip.io:30005

export FABRIC_CFG_PATH=$PWD/../config/

peer channel join -b ./channel-artifacts/${CHANNEL_NAME}.block        

# Join channel Org2
export PEER0_ORG2_CA=${PWD}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt
export CORE_PEER_LOCALMSPID="Org2MSP"
export CORE_PEER_TLS_ROOTCERT_FILE=$PEER0_ORG2_CA
export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp
export CORE_PEER_ADDRESS=192.168.49.2.nip.io:30006
export FABRIC_CFG_PATH=$PWD/../config/
peer channel join -b ./channel-artifacts/${CHANNEL_NAME}.block  

# Set anchor peers Org1        
export CORE_PEER_LOCALMSPID="Org1MSP"
export PEER0_ORG1_CA=${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
export CORE_PEER_TLS_ROOTCERT_FILE=$PEER0_ORG1_CA
export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
export CORE_PEER_ADDRESS=192.168.49.2.nip.io:30005

# Fetching the most recent configuration block for the channel
peer channel fetch config config_block.pb -o 192.168.49.2.nip.io:30004 --ordererTLSHostnameOverride 192.168.49.2.nip.io -c $CHANNEL_NAME --tls --cafile $ORDERER_CA

# Decoding config block to JSON and isolating config to Org1MSPconfig.json
configtxlator proto_decode --input config_block.pb --type common.Block | jq .data.data[0].payload.data.config >"${CORE_PEER_LOCALMSPID}"config.json

export HOST="peer0-org1-example-com"
export PORT=7051

jq '.channel_group.groups.Application.groups.'${CORE_PEER_LOCALMSPID}'.values += {"AnchorPeers":{"mod_policy": "Admins","value":{"anchor_peers": [{"host": "'$HOST'","port": '$PORT'}]},"version": "0"}}' ${CORE_PEER_LOCALMSPID}config.json > ${CORE_PEER_LOCALMSPID}modified_config.json

configtxlator proto_encode --input "${CORE_PEER_LOCALMSPID}"config.json --type common.Config >original_config.pb

configtxlator proto_encode --input "${CORE_PEER_LOCALMSPID}"modified_config.json --type common.Config >modified_config.pb

configtxlator compute_update --channel_id "${CHANNEL_NAME}" --original original_config.pb --updated modified_config.pb >config_update.pb

configtxlator proto_decode --input config_update.pb --type common.ConfigUpdate >config_update.json

echo '{"payload":{"header":{"channel_header":{"channel_id":"'$CHANNEL_NAME'", "type":2}},"data":{"config_update":'$(cat config_update.json)'}}}' | jq . >config_update_in_envelope.json

configtxlator proto_encode --input config_update_in_envelope.json --type common.Envelope >"${CORE_PEER_LOCALMSPID}"anchors.tx


peer channel update -o 192.168.49.2.nip.io:30004 --ordererTLSHostnameOverride 192.168.49.2.nip.io -c $CHANNEL_NAME -f ${CORE_PEER_LOCALMSPID}anchors.tx --tls --cafile $ORDERER_CA


# Set Anchor peer Org2
export PEER0_ORG2_CA=${PWD}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt
export CORE_PEER_LOCALMSPID="Org2MSP"
export CORE_PEER_TLS_ROOTCERT_FILE=$PEER0_ORG2_CA
export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp
export CORE_PEER_ADDRESS=192.168.49.2.nip.io:30006

peer channel fetch config config_block.pb -o 192.168.49.2.nip.io:30004 --ordererTLSHostnameOverride 192.168.49.2.nip.io -c $CHANNEL_NAME --tls --cafile $ORDERER_CA
   
configtxlator proto_decode --input config_block.pb --type common.Block | jq .data.data[0].payload.data.config >"${CORE_PEER_LOCALMSPID}"config.json

export HOST="peer0-org2-example-com"
export PORT=9051

jq '.channel_group.groups.Application.groups.'${CORE_PEER_LOCALMSPID}'.values += {"AnchorPeers":{"mod_policy": "Admins","value":{"anchor_peers": [{"host": "'$HOST'","port": '$PORT'}]},"version": "0"}}' ${CORE_PEER_LOCALMSPID}config.json > ${CORE_PEER_LOCALMSPID}modified_config.json

configtxlator proto_encode --input "${CORE_PEER_LOCALMSPID}"config.json --type common.Config >original_config.pb

configtxlator proto_encode --input "${CORE_PEER_LOCALMSPID}"modified_config.json --type common.Config >modified_config.pb

configtxlator compute_update --channel_id "${CHANNEL_NAME}" --original original_config.pb --updated modified_config.pb >config_update.pb

configtxlator proto_decode --input config_update.pb --type common.ConfigUpdate >config_update.json

echo '{"payload":{"header":{"channel_header":{"channel_id":"'$CHANNEL_NAME'", "type":2}},"data":{"config_update":'$(cat config_update.json)'}}}' | jq . >config_update_in_envelope.json

configtxlator proto_encode --input config_update_in_envelope.json --type common.Envelope >"${CORE_PEER_LOCALMSPID}"anchors.tx


peer channel update -o 192.168.49.2.nip.io:30004 --ordererTLSHostnameOverride 192.168.49.2.nip.io -c $CHANNEL_NAME -f ${CORE_PEER_LOCALMSPID}anchors.tx --tls --cafile $ORDERER_CA



# Install external CC
(test-network)
setGlobals 1
peer lifecycle chaincode install ../asset-transfer-basic/chaincode-external/asset-transfer-basic.tgz

setGlobals 2

# Deploy CC
# export CHANNEL_NAME=mychannel

# # ./network.sh deployCC -ccn basic -ccp ../asset-transfer-basic/chaincode-go -ccl go

# . scripts/envVar.sh

# # packageChaincode
# export FABRIC_CFG_PATH=$PWD/../config/
# export CC_NAME=basic
# export CC_SRC_PATH=../asset-transfer-basic/chaincode-go
# export CC_RUNTIME_LANGUAGE=golang
# export CC_VERSION=1.0

# # if error: is explicitly required in go.mod, but not marked as explicit in vendor/modules.txt
# # then go to chaincode directory, e.g asset-transfer-basic/chaincode-go and run
# go mod vendor
# ##
# peer lifecycle chaincode package ${CC_NAME}.tar.gz --path ${CC_SRC_PATH} --lang ${CC_RUNTIME_LANGUAGE} --label ${CC_NAME}_${CC_VERSION}

# # install CC Org1
# export CORE_PEER_TLS_ENABLED=true
# export ORDERER_CA=${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem

# export PEER0_ORG1_CA=${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
# export CORE_PEER_LOCALMSPID="Org1MSP"
# export CORE_PEER_TLS_ROOTCERT_FILE=$PEER0_ORG1_CA
# export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
# export CORE_PEER_ADDRESS=192.168.49.2.nip.io:30005

# peer lifecycle chaincode install ${CC_NAME}.tar.gz
