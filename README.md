# Deploy Hyperledger Fabric network on Kubernetes

This project describes step-by-step how to deploy the Fabric Certificate Authority, the Fabric Orderer, Fabric Peers and chaindode as an external service on Kubernetes using minikube.

The blockchain network will consist of a RAFT orderer service, 2 organizations that have a peer for each one (org1 and org2) and a CA for each organization.

### Prerequisites

* **A Kubernetes cluster**.  We are going to use [minikube](https://kubernetes.io/docs/tasks/tools/) (v1.17.1) as a single cluster. You will also need the tools to manage a Kubernetes cluster such as **kubectl** (v1.20.4).
* **Hyperledger Fabric 2.3.0 docker images**. The images will be pulled when launching the Kubernetes deployments.
* **Hyperledger Fabric 2.3.0 binaries**. The binaries will be used to create the configurations and channel artifacts for the network.




### Getting started

Download the Hyperledger Fabric binaries and place the `bin` directory under the project root directory.

Open a new terminal window (1) and go to the project-root directory.

#### Start minikube and mount host directory

***The host directory must be the directory outside the project directory***

```bash
minikube start --mount-string $PWD:/host  --mount
```

#### Cluster IP & Configurations

You can get the cluster IP by running the following command:

```bash
kubectl cluster-info

# Sample output
Kubernetes control plane is running at https://192.168.49.2:8443
KubeDNS is running at https://192.168.49.2:8443/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```
In the command above, the cluster IP is `192.168.49.2` .

The cluster IP will be combined with [nip.io](https://nip.io/) to map the IP with a hostname (FOR DEVELOPMENT PURPOSES ONLY). 

Perform the following necessary network configurations:

1. Modify the `CLUSTER_IP_HOSTNAME` variable in the `envVars.sh` file with your cluster IP. 
   Remember to put the `.nip.io` at the end of the IP.

```bash
# Sample
export CLUSTER_IP_HOSTNAME=192.168.49.2.nip.io
```

2. Replace **line 321** in the `config/fabric-ca-server-config.yaml` file with your cluster IP. Again, remember to put the `.nip.io` at the end of the IP.

   ```
   309:	csr:
   310:   		cn: fabric-ca-server
   311:   		keyrequest:
   312:     		algo: ecdsa
   313:     		size: 256
   314:   		names:
   315:      		- C: US
   316:        	ST: "North Carolina"
   317:        	L:
   318:        	O: Hyperledger
   319:        	OU: Fabric
   320:   		hosts:
   321:     		- CLUSTER_IP_HOSTNAME_HERE
   322:   		ca:
   323:      		expiry: 131400h
   324:      		pathlength: 1
   ```

3. Copy the `fabric-ca-server-config.yaml` under 
   * `network/organizations/fabric-ca/ordererOrg`
   * `network/organizations/fabric-ca/org1`
   * `network/organizations/fabric-ca/org2`



##### Configure docker cli to connect with minikube's docker daemon

```bash
eval $(minikube -p minikube docker-env)
```


Go to the `network` directory:

```bash
cd network
```

#### Create namespace

```bash
kubectl apply -f k8s/hyperledger-ns.yaml
```

Save the namespace for all subsequent kubectl commands in that context:

```bash
kubectl config set-context --current --namespace=hyperledger
```

#### Create CAs

```bash
kubectl apply -f k8s/ca/
```

Check that everything is running fine by using `kubectl get pods` command.

```bash
NAME                                      READY   STATUS    RESTARTS   AGE
ca-orderer-7859866d7b-87lsb               1/1     Running   0          4m
ca-org1-6979cdbb99-j2w2t                  1/1     Running   0          4m5s
ca-org2-57b7b7f848-2jhs4                  1/1     Running   0          4m15s
```



#### Import necessary environment variables

```bash
. envVars.sh
```

#### Enroll and register entities

```bash
. organizations/fabric-ca/registerEnroll.sh
createOrg1
createOrg2
createOrderer
```

#### Generate Orderer Genesis block

```bash
# from network folder
export FABRIC_CFG_PATH=${PWD}/configtx
configtxgen -profile TwoOrgsOrdererGenesis -channelID system-channel -outputBlock ./system-genesis-block/genesis.block
```

#### Bring network up

Create the **orderer**:

```bash
kubectl apply -f k8s/orderer/
```
Wait for the `orderer` to start running by using `kubectl get pods` command.

Now create the **org1** pods:

```bash
kubectl apply -f k8s/org1/
```

Wait for the `org1 peer` to start running by using `kubectl get pods` command.

Now create the **org2** pods:

```bash
kubectl apply -f k8s/org2/
```

Check that everything is running fine by using `kubectl get pods` command.

```bash
NAME                                      READY   STATUS    RESTARTS   AGE
ca-orderer-7859866d7b-87lsb               1/1     Running   0          5m15s
ca-org1-6979cdbb99-j2w2t                  1/1     Running   0          5m15s
ca-org2-57b7b7f848-2jhs4                  1/1     Running   0          5m15s
orderer-example-com-5478c49d59-fkl2x      1/1     Running   0          76s
peer0-org1-example-com-5f8f649974-2tvpr   1/1     Running   0          62s
peer0-org2-example-com-7579b95585-2h9sk   1/1     Running   0          50s
```



#### Create channel configuration transaction

```bash
configtxgen -profile TwoOrgsChannel -outputCreateChannelTx ./channel-artifacts/${CHANNEL_NAME}.tx -channelID $CHANNEL_NAME
```

#### Create channel using Org1

```bash
export FABRIC_CFG_PATH=$PWD/../config/

# requires ". envVars.sh"
setOrg1

peer channel create -o $CLUSTER_IP_HOSTNAME:30004 -c $CHANNEL_NAME --ordererTLSHostnameOverride $CLUSTER_IP_HOSTNAME -f ./channel-artifacts/${CHANNEL_NAME}.tx --outputBlock ./channel-artifacts/${CHANNEL_NAME}.block --tls --cafile $ORDERER_CA
```

#### Join Org1 in channel

```bash
# requires export FABRIC_CFG_PATH=$PWD/../config/
peer channel join -b ./channel-artifacts/${CHANNEL_NAME}.block
```

#### Join Org2 in channel

```bash
# requires ". envVars.sh"
setOrg2
# requires export FABRIC_CFG_PATH=$PWD/../config/
peer channel join -b ./channel-artifacts/${CHANNEL_NAME}.block 
```

#### Set anchor peers for Org1

```bash
# requires ". envVars.sh"
setOrg1

# Fetching the most recent configuration block for the channel
peer channel fetch config config_block.pb -o $CLUSTER_IP_HOSTNAME:30004 --ordererTLSHostnameOverride $CLUSTER_IP_HOSTNAME -c $CHANNEL_NAME --tls --cafile $ORDERER_CA

# Decoding config block to JSON and isolating config to Org1MSPconfig.json
configtxlator proto_decode --input config_block.pb --type common.Block | jq .data.data[0].payload.data.config >"${CORE_PEER_LOCALMSPID}"config.json

# Modify the configuration to append the anchor peer 
jq '.channel_group.groups.Application.groups.'${CORE_PEER_LOCALMSPID}'.values += {"AnchorPeers":{"mod_policy": "Admins","value":{"anchor_peers": [{"host": "'$HOST_ORG1'","port": '$PORT_ORG1'}]},"version": "0"}}' ${CORE_PEER_LOCALMSPID}config.json > ${CORE_PEER_LOCALMSPID}modified_config.json

configtxlator proto_encode --input "${CORE_PEER_LOCALMSPID}"config.json --type common.Config >original_config.pb

configtxlator proto_encode --input "${CORE_PEER_LOCALMSPID}"modified_config.json --type common.Config >modified_config.pb

configtxlator compute_update --channel_id "${CHANNEL_NAME}" --original original_config.pb --updated modified_config.pb >config_update.pb

configtxlator proto_decode --input config_update.pb --type common.ConfigUpdate >config_update.json

echo '{"payload":{"header":{"channel_header":{"channel_id":"'$CHANNEL_NAME'", "type":2}},"data":{"config_update":'$(cat config_update.json)'}}}' | jq . >config_update_in_envelope.json

configtxlator proto_encode --input config_update_in_envelope.json --type common.Envelope >"${CORE_PEER_LOCALMSPID}"anchors.tx


peer channel update -o $CLUSTER_IP_HOSTNAME:30004 --ordererTLSHostnameOverride $CLUSTER_IP_HOSTNAME -c $CHANNEL_NAME -f ${CORE_PEER_LOCALMSPID}anchors.tx --tls --cafile $ORDERER_CA
```



#### Set anchor peers for Org2

```bash
# requires ". envVars.sh"
setOrg2

# Fetching the most recent configuration block for the channel
peer channel fetch config config_block.pb -o $CLUSTER_IP_HOSTNAME:30004 --ordererTLSHostnameOverride $CLUSTER_IP_HOSTNAME -c $CHANNEL_NAME --tls --cafile $ORDERER_CA
   
# Decoding config block to JSON and isolating config to Org2MSPconfig.json
configtxlator proto_decode --input config_block.pb --type common.Block | jq .data.data[0].payload.data.config >"${CORE_PEER_LOCALMSPID}"config.json

# Modify the configuration to append the anchor peer 
jq '.channel_group.groups.Application.groups.'${CORE_PEER_LOCALMSPID}'.values += {"AnchorPeers":{"mod_policy": "Admins","value":{"anchor_peers": [{"host": "'$HOST_ORG2'","port": '$PORT_ORG2'}]},"version": "0"}}' ${CORE_PEER_LOCALMSPID}config.json > ${CORE_PEER_LOCALMSPID}modified_config.json

configtxlator proto_encode --input "${CORE_PEER_LOCALMSPID}"config.json --type common.Config >original_config.pb

configtxlator proto_encode --input "${CORE_PEER_LOCALMSPID}"modified_config.json --type common.Config >modified_config.pb

configtxlator compute_update --channel_id "${CHANNEL_NAME}" --original original_config.pb --updated modified_config.pb >config_update.pb

configtxlator proto_decode --input config_update.pb --type common.ConfigUpdate >config_update.json

echo '{"payload":{"header":{"channel_header":{"channel_id":"'$CHANNEL_NAME'", "type":2}},"data":{"config_update":'$(cat config_update.json)'}}}' | jq . >config_update_in_envelope.json

configtxlator proto_encode --input config_update_in_envelope.json --type common.Envelope >"${CORE_PEER_LOCALMSPID}"anchors.tx


peer channel update -o $CLUSTER_IP_HOSTNAME:30004 --ordererTLSHostnameOverride $CLUSTER_IP_HOSTNAME -c $CHANNEL_NAME -f ${CORE_PEER_LOCALMSPID}anchors.tx --tls --cafile $ORDERER_CA
```



### Install chaincode

#### Install chaincode on Org1

Open a new terminal window (2) and go to the chaincode directory (`asset-transfer-basic/chaincode-external`)

Configure docker cli to connect with minikube's docker daemon in the new terminal (2):

```bash
eval $(minikube -p minikube docker-env)
```

##### Modify all the necessary files for Org1

Modify the `connection.json` file that contains the information of the connection to the external chaincode server.

```json
# connection.json
{
  "address": "chaincode-asset-basic-org1:7052",
  "dial_timeout": "10s",
  "tls_required": false
}	
```

##### Package the chaincode 

```bash
tar cfz code.tar.gz connection.json
```

Now we need to repackage the chaincode with the metadata.json file which includes information about the type of chaincode to be processed and the label we want to give to the chaincode.

```json
# metadata.json
{
    "type": "external",
    "label": "basic"
}
```

##### Repackage the chaincode

```bash
tar cfz asset-transfer-basic-org1.tgz code.tar.gz metadata.json
```



Now we are going to install the chaincode on **org1**.

Go to the previous terminal window (1) and execute the following commands.

```bash
setOrg1
peer lifecycle chaincode install ../asset-transfer-basic/chaincode-external/asset-transfer-basic-org1.tgz
# Should print similar output
Chaincode code package identifier: basic:24a31ea81a62d302925f2d296c50d3e2df83062a216b62fdb4f2606852f7ee4d
```

Copy the chaincode code package identifier as we will need it later.

You can always retrieved it by executing the command:

```bash
peer lifecycle chaincode queryinstalled
```



#### Install chaincode on Org2

Execute the following commands from terminal window (2) from the chaincode directory (`asset-transfer-basic/chaincode-external`)

##### Modify all the necessary files for Org2

Modify the `connection.json` file that contains the information of the connection to the external chaincode server.

```json
# connection.json
{
  "address": "chaincode-asset-basic-org2:9052",
  "dial_timeout": "10s",
  "tls_required": false
}	
```

##### Package the chaincode 

```bash
tar cfz code.tar.gz connection.json
```

Now we need to repackage the chaincode with the metadata.json file which includes information about the type of chaincode to be processed and the label we want to give to the chaincode.

```json
# metadata.json
{
    "type": "external",
    "label": "basic"
}
```

##### Repackage the chaincode

```bash
tar cfz asset-transfer-basic-org2.tgz code.tar.gz metadata.json
```



Now we are going to repeat the same steps above for **org2** but with some modifications.

Go to the previous terminal window (1) and execute the following commands.

```bash
setOrg2
peer lifecycle chaincode install ../asset-transfer-basic/chaincode-external/asset-transfer-basic-org2.tgz
# Should print similar output
Chaincode code package identifier: basic:7055db8c355e98d0cad948f877e61569bc8e2317b7203bd11600d8d7078be6d2
```

Copy the chaincode code package identifier as we will need it later. It should be different from the org1.

You can always retrieved it by executing the command:

```bash
peer lifecycle chaincode queryinstalled
```



##### What happens behind the scenes

Peers define some external-builders that they get executed before launching the option of building the chaincode Docker container. 

More details can be found here: https://hyperledger-fabric.readthedocs.io/en/latest/cc_service.html?highlight=extenal%20chaincode



### Build and Deploy the external chaincode using Dockerfile

For more details how to write chaincode to run as an external service look [here ](https://hyperledger-fabric.readthedocs.io/en/latest/cc_service.html?#writing-chaincode-to-run-as-an-external-service).

Execute the following commands from terminal window (2) from the chaincode directory (`asset-transfer-basic/chaincode-external`)

```bash
docker build -t chaincode/basic:1.0 .
```

Once finished, you should have an image `chaincode/basic:1.0` ready to be deployed on k8s.



##### Deploy External chaincode on Kubernetes

Modify the chaincode deployment files (`k8s/chaincode/org1-chaincode-deployment.yaml` and `k8s/chaincode/org2-chaincode-deployment.yaml`) with the corresponding **CHAINCODE_ID** values you received after installing the chaincode on the peers.

```
#-------------- Chaincode Deployment Org1 --------------
env:
  - name: CHAINCODE_ID
    value: "basic:24a31ea81a62d302925f2d296c50d3e2df83062a216b62fdb4f2606852f7ee4d"
  - name: CHAINCODE_SERVER_ADDRESS
	value: "0.0.0.0:7052"
ports:
- containerPort: 7052
```

```
#-------------- Chaincode Deployment Org2 --------------
env:
  - name: CHAINCODE_ID
    value: "basic:7055db8c355e98d0cad948f877e61569bc8e2317b7203bd11600d8d7078be6d2"
  - name: CHAINCODE_SERVER_ADDRESS
	value: "0.0.0.0:9052"
ports:
- containerPort: 9052
```



After that, deploy from the terminal window (1):

```bash
kubectl apply -f k8s/chaincode/
```



##### Approve chaincode for Org1

```bash
# Export the chaincode ID into a variable
export PKGID_ORG1=basic:24a31ea81a62d302925f2d296c50d3e2df83062a216b62fdb4f2606852f7ee4d
setOrg1
peer lifecycle chaincode approveformyorg --channelID $CHANNEL_NAME --name basic --version 1.0 --init-required --package-id $PKGID_ORG1 --sequence 1 -o $CLUSTER_IP_HOSTNAME:30004 --tls --cafile $ORDERER_CA

# Should print similar output
txid [2b93f7b6cf2a9ad59f7657a5fd83d48a094fef39a92656aa048ed8f844d29f6d] committed with status (VALID) at 192.168.49.2.nip.io:30005
```

##### Check the approvals in the entire network

```bash
peer lifecycle chaincode checkcommitreadiness --channelID $CHANNEL_NAME --name basic --version 1.0 --init-required --sequence 1 -o $CLUSTER_IP_HOSTNAME:30004 --tls --cafile $ORDERER_CA

# Should print similar output
Chaincode definition for chaincode 'basic', version '1.0', sequence '1' on channel 'mychannel' approval status by org:
Org1MSP: true
Org2MSP: false
```



##### Approve chaincode for Org2

```bash
# Export the chaincode ID into a variable
export PKGID_ORG2=basic:7055db8c355e98d0cad948f877e61569bc8e2317b7203bd11600d8d7078be6d2
setOrg2
peer lifecycle chaincode approveformyorg --channelID $CHANNEL_NAME --name basic --version 1.0 --init-required --package-id $PKGID_ORG2 --sequence 1 -o $CLUSTER_IP_HOSTNAME:30004 --tls --cafile $ORDERER_CA

# Should print similar output
txid [3eb3d30504bdbe0c471455693eebe0e33e1b03bc8e2ef407aa392003718a74b6] committed with status (VALID) at 192.168.49.2.nip.io:30006
```

##### Check the approvals in the entire network

```bash
peer lifecycle chaincode checkcommitreadiness --channelID $CHANNEL_NAME --name basic --version 1.0 --init-required --sequence 1 -o $CLUSTER_IP_HOSTNAME:30004 --tls --cafile $ORDERER_CA

# Should print similar output
Chaincode definition for chaincode 'basic', version '1.0', sequence '1' on channel 'mychannel' approval status by org:
Org1MSP: true
Org2MSP: true
```

As you  can see, all the organizations have approved the chaincode.



##### Commit chaincode definition in the channel 

NOTE: *This step can be performed using any peer*

```bash
peer lifecycle chaincode commit -o $CLUSTER_IP_HOSTNAME:30004 --channelID $CHANNEL_NAME --name basic --version 1.0 --sequence 1 --init-required --tls true --cafile $ORDERER_CA --peerAddresses $CLUSTER_IP_HOSTNAME:30005 --tlsRootCertFiles organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt --peerAddresses $CLUSTER_IP_HOSTNAME:30006 --tlsRootCertFiles organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt

# Should print similar output
2021-03-10 12:17:05.893 CET [chaincodeCmd] ClientWait -> INFO 001 txid [ee519d243a6a041bfe824e2133b3a6e564828e47c606d20ec961da00bab889d1] committed with status (VALID) at 192.168.49.2.nip.io:30006
2021-03-10 12:17:05.896 CET [chaincodeCmd] ClientWait -> INFO 002 txid [ee519d243a6a041bfe824e2133b3a6e564828e47c606d20ec961da00bab889d1] committed with status (VALID) at 192.168.49.2.nip.io:30005
```

##### Query the committed chaincode

```bash
peer lifecycle chaincode querycommitted -o $CLUSTER_IP_HOSTNAME:30004 --channelID $CHANNEL_NAME --name basic --tls --cafile $ORDERER_CA --peerAddresses $CLUSTER_IP_HOSTNAME:30005 --tlsRootCertFiles organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt

# Should print similar output
Committed chaincode definition for chaincode 'basic' on channel 'mychannel':
Version: 1.0, Sequence: 1, Endorsement Plugin: escc, Validation Plugin: vscc, Approvals: [Org1MSP: true, Org2MSP: true]
```



#### Test the external chaincode

NOTE: *This step can be performed using any peer*

```bash
peer chaincode invoke -o $CLUSTER_IP_HOSTNAME:30004 --ordererTLSHostnameOverride $CLUSTER_IP_HOSTNAME --tls true --cafile $ORDERER_CA -C $CHANNEL_NAME -n basic --isInit --peerAddresses $CLUSTER_IP_HOSTNAME:30005 --tlsRootCertFiles organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt --peerAddresses $CLUSTER_IP_HOSTNAME:30006 --tlsRootCertFiles organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt -c '{"function":"InitLedger","Args":[]}' --waitForEvent

# Should print similar output
2021-03-10 12:25:47.541 CET [chaincodeCmd] ClientWait -> INFO 001 txid [423af33abc399d0a889faa683dc2a6669d5a8dbe51898fa2fb251fc32a8778cf] committed with status (VALID) at 192.168.49.2.nip.io:30006
2021-03-10 12:25:47.544 CET [chaincodeCmd] ClientWait -> INFO 002 txid [423af33abc399d0a889faa683dc2a6669d5a8dbe51898fa2fb251fc32a8778cf] committed with status (VALID) at 192.168.49.2.nip.io:30005
2021-03-10 12:25:47.545 CET [chaincodeCmd] chaincodeInvokeOrQuery -> INFO 003 Chaincode invoke successful. result: status:200 
```



##### Create a new *asset7*

```	bash
peer chaincode invoke -o $CLUSTER_IP_HOSTNAME:30004 --tls true --cafile $ORDERER_CA -C $CHANNEL_NAME -n basic --peerAddresses $CLUSTER_IP_HOSTNAME:30005 --tlsRootCertFiles organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt --peerAddresses $CLUSTER_IP_HOSTNAME:30006 --tlsRootCertFiles organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt -c '{"Args":["createAsset","asset7","purple","50","Yukie", "800"]}' --waitForEvent	

# Should print similar output
2021-03-10 12:29:04.476 CET [chaincodeCmd] ClientWait -> INFO 001 txid [2f671635e340aeb935329ee390285d817b863584002b12e39995c3953767dc9d] committed with status (VALID) at 192.168.49.2.nip.io:30005
2021-03-10 12:29:04.479 CET [chaincodeCmd] ClientWait -> INFO 002 txid [2f671635e340aeb935329ee390285d817b863584002b12e39995c3953767dc9d] committed with status (VALID) at 192.168.49.2.nip.io:30006
2021-03-10 12:29:04.479 CET [chaincodeCmd] chaincodeInvokeOrQuery -> INFO 003 Chaincode invoke successful. result: status:200 
```



##### Retrieve information from *asset7*

```bash
peer chaincode invoke -o $CLUSTER_IP_HOSTNAME:30004 --tls true --cafile $ORDERER_CA -C $CHANNEL_NAME -n basic --peerAddresses $CLUSTER_IP_HOSTNAME:30005 --tlsRootCertFiles organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt --peerAddresses $CLUSTER_IP_HOSTNAME:30006 --tlsRootCertFiles organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt -c '{"Args":["readAsset","asset7"]}' --waitForEvent

# Should print similar output
2021-03-10 12:30:36.993 CET [chaincodeCmd] ClientWait -> INFO 001 txid [4a1142641f8383f7e5d9438e0cc93920093d91fee9b928731d93097f61c75e6d] committed with status (VALID) at 192.168.49.2.nip.io:30005
2021-03-10 12:30:36.996 CET [chaincodeCmd] ClientWait -> INFO 002 txid [4a1142641f8383f7e5d9438e0cc93920093d91fee9b928731d93097f61c75e6d] committed with status (VALID) at 192.168.49.2.nip.io:30006
2021-03-10 12:30:36.996 CET [chaincodeCmd] chaincodeInvokeOrQuery -> INFO 003 Chaincode invoke successful. result: status:200 payload:"{\"ID\":\"asset7\",\"color\":\"purple\",\"size\":50,\"owner\":\"Yukie\",\"appraisedValue\":800}" 
```



#### Clean up

```bash
minikube delete

# if clean doesn't work, open a new terminal and execute again the command
sudo ./clean.sh
```



#### Port mapping - currently configured

```
org1-ca-service --> 30001 -> 7054 
org2-ca-service --> 30002 -> 8054
ca-orderer-service --> 30003 -> 9054

orderer-service --> 30004 -> 7050
peer0-org1-service --> 30005 -> 7051
peer0-org2-service --> 30006 -> 9051
```
