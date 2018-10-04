
#!/bin/bash

# This script is used as internalCustomStartupScript to setup the VM of the Azure Scale Set.
# This setup is for Debian 8 VM only, and involves:
# - setting up Docker and Docker-Compose
# - setting up ProActive Node service with PAMR
# - starting the ProActive Node service
# - install and setup the required packages/libs for the various script engine

# Be sure the variables below are OK for depending on your context

PROACTIVE_PAMR_ROUTER_IP="62.210.124.102"
# The URL from where to retrieve the JRE tarball
JRE_TARBALL_URL="https://s3.amazonaws.com/ci-materials/Latest_jre/jre-8u131-linux-x64.tar.gz"
# This repo hosts the required additional jar files for the various script engines
ADDITIONAL_JARS_REPO_URL="https://github.com/gheon/proactive-node-additional-jar.git"

set -x

###############################
# Bash function used by the VM to send debug messages to the dedicated Azure Queue
###############################
function debug {
DEBUGCONTENT=`echo $1 | base64 -w 0`
DEBUGMESSAGE="<QueueMessage><MessageText>$DEBUGCONTENT</MessageText></QueueMessage>"
curl -X POST -d "$DEBUGMESSAGE" "https://$STORAGEACCOUNT.queue.core.windows.net/debug/messages?$SASKEY"
}

# Prerequisites: Install Docker and Docker Compose, add 'activeeon' user to docker group
apt-get update
apt-get install -y \
apt-transport-https \
ca-certificates \
curl \
gnupg2 \
software-properties-common
curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | apt-key add -
add-apt-repository \
"deb [arch=amd64] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
$(lsb_release -cs) \
stable"
apt-get update
apt-get install -y docker-ce
groupadd docker
usermod -aG docker activeeon
curl -L https://github.com/docker/compose/releases/download/1.17.0/docker-compose-`uname -s`-`uname -m` -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

###############################
# Downloads and install ProActive Node as a Systemd service
###############################
mkdir -p /opt/proactive
cd /opt/proactive

# Install dependencies
apt-get update
if ! apt-get install -y wget curl jq; then
sleep 10
apt-get update
if ! apt-get install -y wget curl jq; then
>&2 echo "Fatal error: Unable to run apt-get"
halt
fi
fi

# Install Java 8
# [MODIFY] modify if needed the URL to get the JRE
wget --no-clobber $JRE_TARBALL_URL
tar zxf jre-8u131-linux-x64.tar.gz
ln -s /opt/proactive/jre1.8.0_131 /opt/proactive/java
# making Java 8 available system-wide
update-alternatives --install /usr/bin/java java /opt/proactive/java/bin/java 1
update-alternatives --set java /opt/proactive/java/bin/java

# Retrieve NS config
if [ -f /var/lib/waagent/CustomData ]; then
JSONCONFIG=`base64 -d /var/lib/waagent/CustomData`
elif [ -f /var/lib/waagent/ovf-env.xml ]; then
JSONCONFIG=`cat /var/lib/waagent/ovf-env.xml | grep CustomData | cut -d'>' -f4 | cut -d '<' -f1 | base64 -d`
elif [ -f /var/lib/cloud/instance/user-data.txt ]; then
JSONCONFIG=`base64 -d /var/lib/cloud/instance/user-data.txt`
else
JSONCONFIG=""
debug "Custom data not found in the system"
fi
echo $JSONCONFIG
export RMURL=`echo $JSONCONFIG | jq '.rmurl' -r`
export CREDVALUE=`echo $JSONCONFIG | jq '.credentials' -r`
export NODESOURCENAME=`echo $JSONCONFIG | jq '.nodesourcename' -r`
export STORAGEACCOUNT=`echo $JSONCONFIG | jq '.storageaccount' -r`
export SASKEY=`echo $JSONCONFIG | jq '.saskey' -r`
export USERCUSTOMSCRIPTURL=`echo $JSONCONFIG | jq '.usercustomscripturl' -r`
export EXTERNALSTORAGEACCOUNT=`echo $JSONCONFIG | jq '.externalstorageaccount' -r`

# debug
debug "$HOSTNAME INFO: CustomData read properly (as I can write this message)"

# Overidded custom script if specified
if [ ! -z "$USERCUSTOMSCRIPTURL" ]; then
curl -X GET "$USERCUSTOMSCRIPTURL" > user_custom_script.sh
./user_custom_script.sh
if [ $? -ne 0 ]; then
debug "$HOSTNAME FATAL: User custom script exited with error: $?"
halt #sleep 9999 #exit -1
fi
fi

# We want PAMR
PROPERTIES="-Dproactive.net.nolocal=true -Dproactive.communication.protocol=pamr -Dproactive.communication.protocols.order=pamr -Dproactive.pamr.router.address=${PROACTIVE_PAMR_ROUTER_IP}"

# Getting node.jar
curl -X GET "https://$STORAGEACCOUNT.blob.core.windows.net/nodefiles/node.jar?$SASKEY" > node.jar

# Read Azure Queue to get node name Deletion is performed on NS Side when nodes are properly registered
msg=$(curl "https://$STORAGEACCOUNT.queue.core.windows.net/nodeconfig/messages?visibilitytimeout=300&$SASKEY")
JSONMSG=`echo $msg | grep -oP '<MessageText>\K[^<]+' | base64 -d`
msgId=`echo $msg | grep -oP '<MessageId>\K[^<]+'`
popReceipt=`echo $msg | grep -oP '<PopReceipt>\K[^<]+'`
NODEBASENAME=`echo $JSONMSG | jq '.nodebasename' -r`
NODEINSTANCES=`echo $JSONMSG | jq '.nodeinstances' -r`
if [ -z "$NODEBASENAME" ]; then
debug "$HOSTNAME FATAL: Unable to retrieve node configuration from 'nodeconfig' queue"
halt #sleep 9999 #exit -1
fi

# debug
NOW=`date`
debug "$HOSTNAME INFO: Start filling the Table on $NOW"

# Immediately delete the message from queue.
# If the script fails then the node will be considered lost,
# this must be the default behaviour until Azure scaleSet provide
# automatic redeployment in case of failure.
curl -X DELETE "https://${STORAGEACCOUNT}.queue.core.windows.net/nodeconfig/messages/${msgId}?popreceipt=${popReceipt}&${SASKEY}"

# Retrieve instance metadata
INSTANCE_NAME=$(curl -H Metadata:true "http://169.254.169.254/metadata/instance/compute?api-version=2017-12-01" | jq .name | sed 's/"//g')
INSTANCE_ID=$(echo -n "$INSTANCE_NAME" | rev | cut -d'_' -f1 | rev)

# update Azure Table
ENTITY="{'PartitionKey':'$HOSTNAME','RowKey':'$NODEBASENAME', 'NodesCount':'$NODEINSTANCES', 'InstanceId': '$INSTANCE_ID'}"
curl -H "Content-Type: application/json" -d "$ENTITY" -X POST "https://$STORAGEACCOUNT.table.core.windows.net/nodesperhost?$SASKEY"
if [ $? -ne 0 ]; then
debug "$HOSTNAME FATAL: Unable to register the host into 'nodesperhost' table"
halt #sleep 9999 #exit -1
fi
NOW=`date`
debug "$HOSTNAME INFO: Terminated to fill the Table on $NOW"

# Generate proactive-node systemd service unit file
cat > /etc/systemd/system/proactive-node.service <<EOL
[Unit]
After=sshd.service

[Service]
ExecStart=/usr/bin/java -jar /opt/proactive/node.jar ${PROPERTIES} -v ${CREDVALUE} -w ${NODEINSTANCES} -r ${RMURL} -n ${NODEBASENAME} -s ${NODESOURCENAME}
User=activeeon

[Install]
WantedBy=default.target
EOL
chmod 664 /etc/systemd/system/proactive-node.service

# Install ProActive Node Service
systemctl daemon-reload
systemctl enable proactive-node.service
sysctl fs.inotify.max_user_watches=524288 # Support for large numnber of nodes

# Debug message posted on debug queue
IP=`hostname -i`
debug "$HOSTNAME INFO: Service is ready to start: $IP , $NODEBASENAME , $NODEINSTANCES"
###############################

###############################
# Prepare script engines
###############################

# Python
curl -O https://bootstrap.pypa.io/get-pip.py
python2 get-pip.py
python3 get-pip.py
python2 /usr/local/bin/pip install py4j
python2 /usr/local/bin/pip install numpy
python3 /usr/local/bin/pip install py4j
python3 /usr/local/bin/pip install numpy

# R
apt-get install -y libssl-dev libcurl4-openssl-dev
echo "deb http://cran.univ-paris1.fr/bin/linux/debian jessie-cran34/" >> /etc/apt/sources.list
apt-key adv --keyserver keys.gnupg.net --recv-key 'E19F5F87128899B192B1A2C2AD5F960A256A04AF'
apt-get install -y r-base r-cran-rjava
#Rscript --slave --no-save --no-restore-history -e "install.packages(c('gtools','stringr','devtools'), repos=c('http://www.freestatistics.org/cran/'))"

# Scilab
apt-get install -y scilab

# OpenMPI
apt-get install -y mpi-default-bin

# requirements for the ocr wf
pip install pdf2image
sudo apt install poppler-utils -y
pip install pillow
sudo pip install pytesseract
sudo pip install opencv-python
sudo apt install tesseract-ocr -y
sudo apt install libtesseract-dev -y

###############################
# Let's start the ProActive node service
###############################
systemctl start proactive-node.service

###############################
# Add additional jar required for script engines
###############################
# wait to be sure one-jar has done its job
sleep 120
cd /tmp
git clone $ADDITIONAL_JARS_REPO_URL
mv proactive-node-additional-jar/*.jar /tmp/node/lib/
