#!/bin/bash

# Fetch status tag of an ec2 instance
function get_status {
	echo $(aws ec2 describe-tags \
		--filters Name=resource-id,Values=$1 \
		Name=key,Values=Status \
		--query "Tags[0].Value" --output text)
}

# Delete s3 bucket and cfn stack
function cleanup {
	echo "- Cleaning up resources"
	aws s3 rb s3://$name --force
	aws cloudformation delete-stack --stack-name $name
}

# Custom response to sigint/sigterm
function handle_sig {
    cleanup
    trap - SIGINT SIGTERM # clear the trap
    kill -- -$$ # Sends SIGTERM to child/sub processes
}

trap cleanup SIGINT SIGTERM

# Check for snapcraft file
if [[ ! -f $(pwd)/snap/snapcraft.yaml ]]; then
  echo "[ERROR] Snapcraft config file not found!"
  exit -1
fi

# Create s3 bucket
uuid=$(head -c 16 /proc/sys/kernel/random/uuid)
name=aarch64-snap-$uuid
echo "- Creating S3 bucket"
aws s3 mb s3://$name

# Upload code files to bucket
echo "- Uploading source code to bucket"
aws s3 cp $(pwd)/src/ s3://$name/src --recursive
aws s3 cp $(pwd)/snap/ s3://$name/snap --recursive

# Initiate cfn stack
echo "- Setting up AWS resources"
stack_arn=$(aws cloudformation create-stack \
	--stack-name $name \
	--template-body file://$(pwd)/snap/aarch64_cfn.yaml \
	--parameters ParameterKey=UniqueName,ParameterValue=$name \
	--capabilities CAPABILITY_IAM \
	--query "StackId" --output text)

echo -e "\t- Stack Name: $name"
echo -e "\t- Stack ARN: $stack_arn"

# Wait for ec2 instance to launch
echo -e "- Spinning up EC2 instance\c"
ec2_id='None'

while [ "$ec2_id" == 'None' ]; do
	sleep 1
	echo -e '.\c'
	ec2_id=$(aws cloudformation describe-stacks \
		--stack-name $name \
		--query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
		--output text)
		
	status=$(aws cloudformation describe-stacks \
	    --stack-name $name \
	    --query "Stacks[0].StackStatus" \
	    --output text)
	if [ "$status" == 'ROLLBACK_COMPLETE' ]; then

		cleanup
		echo "[ERROR] Something went wrong with cloudformation creatation!"
		exit 1;
	fi
done

echo -e "\n\t- Instance ID: $ec2_id"
echo -e "- Installing AWS tools\c"

# Wait for ec2 status tag to be created
while [ "$(get_status $ec2_id)" == 'None' ]; do
	echo -e '.\c'
	sleep 1
done

# Install snap tools on ec2
echo -e "\n- Configuring machine\c"
while [ "$(get_status $ec2_id)" == "CONFIGURING" ]; do
	echo -e '.\c'
	sleep 1
done

echo -e "\nThe next step will take several minutes to complete. \c"
echo -e "Perfect opportunity for a stretch break!"

# Snap source code
echo -e "- Building snap\c"
while [ "$(get_status $ec2_id)" == "SNAPPING" ]; do
	echo -e '.\c'
	sleep 1
done

# Download snap from bucket
if [ "$(get_status $ec2_id)" == "COMPLETE" ]; then
	echo -e "\n- Retrieving snap"
	aws s3 cp s3://$name/$(aws s3 ls s3://$name/ | awk '{print $4}' | grep -i .snap) .
else
	cleanup
	echo "\n[ERROR] Something went wrong!"
	exit -2
fi

cleanup
echo 'Finished successfully!'