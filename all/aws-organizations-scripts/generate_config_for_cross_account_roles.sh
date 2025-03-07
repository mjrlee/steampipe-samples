#!/bin/bash

#
# generate_config_for_cross_account_roles.sh
#
# Iterates across a list of AWS Accounts from `aws organizations list-accounts` to:
#   1. Generate an entry in the AWS_CONFIG_FILE specified on the command line
#   2. Generate an associated connection entry in the aws.spc file for steampipe CLI
#
# Note: you will need to execute this script with permissions form the AWS Organizations Management Account
# or any AWS account that is configured as a Delegated Administrator for an AWS Organizations
# service (like GuardDuty or IAM Access Analyzer)
#

set -e

COMMAND=$1
AUDITROLE=$2
AWS_CONFIG_FILE=$3
SOURCE_PROFILE=$4

usage () {
  echo "Usage: $0 [IMDS | ECS | LOCAL ] <AUDITROLE> <AWS_CONFIG_FILE> <SOURCE_PROFILE>"
  exit 1
}

if [ -z "$COMMAND" ] ; then
  echo "ERROR: Missing command"
  usage
fi

if [ $COMMAND != "IMDS" ] && [ $COMMAND != "ECS" ] && [ $COMMAND != "LOCAL" ] ; then
  echo "ERROR: Invalid Command: $COMMAND"
  usage
fi

if ( [ $COMMAND == "IMDS" ] || [ $COMMAND == "ECS" ] ) && [ -z $AWS_CONFIG_FILE ] ; then
  echo "ERROR: AWS config file not defined"
  usage
fi

if [ -z $SOURCE_PROFILE ] ; then
  if [ $COMMAND == "LOCAL" ] ; then
    echo "ERROR: Source profile not defined"
    usage
  else
    SOURCE_PROFILE="default"
  fi
fi

# STEAMPIPE_INSTALL_DIR overrides the default steampipe directory of ~/.steampipe
if [ -z $STEAMPIPE_INSTALL_DIR ] ; then
  echo "STEAMPIPE_INSTALL_DIR not defined. Using the default."
  export STEAMPIPE_INSTALL_DIR=~/.steampipe
fi

if [ ! -d $STEAMPIPE_INSTALL_DIR ] ; then
  echo "STEAMPIPE_INSTALL_DIR: $STEAMPIPE_INSTALL_DIR doesn't exist. Creating it."
  mkdir -p ${STEAMPIPE_INSTALL_DIR}/config/
fi

if [ -f $AWS_CONFIG_FILE ] ; then
  echo "$AWS_CONFIG_FILE exists. Aborting rather than overwriting a critical file."
  exit 1
fi

SP_CONFIG_FILE=${STEAMPIPE_INSTALL_DIR}/config/aws.spc
ALL_REGIONS='["*"]'

echo "Creating Steampipe Connections in $SP_CONFIG_FILE and AWS Profiles in $AWS_CONFIG_FILE"
echo "# Automatically Generated at `date`" > $SP_CONFIG_FILE
echo "# Steampipe profiles, Automatically Generated at `date`" > $AWS_CONFIG_FILE

if [ $COMMAND == "IMDS" ] || [ $COMMAND == "ECS" ] ; then
# Your AWS Config file needs a [default] section
cat <<EOF>>$AWS_CONFIG_FILE
[default]
region = us-east-1
EOF
fi

cat <<EOF>>$SP_CONFIG_FILE

# Create an aggregator of _all_ the accounts as the first entry in the search path.
connection "aws" {
  plugin = "aws"
  type        = "aggregator"
  connections = ["aws_*"]
}

EOF

# We now iterate across the `aws organizations list-accounts` command
while read line ; do

  # extract the values we need
  # print from first to NF-1 (except last two fields) replacing middle spaces by _
  ACCOUNT_NAME=`echo $line | awk '{for (i=1; i<NF-1; i++) printf $i " "}' | sed 's/ $//' | sed 's/ /_/g'`
  ACCOUNT_ID=`echo $line | awk '{print $(NF - 1)}'`

  # Steampipe doesn't like dashes, so we need to swap for underscores
  SP_NAME=`echo $ACCOUNT_NAME | sed s/-/_/g`

if [ $ACCOUNT_NAME == "$SOURCE_PROFILE" ] ; then
  # TODO: improve how the source profile is checked
  echo "Skipping $ACCOUNT_NAME as it is the source profile"
  continue
fi

if [ $COMMAND == "IMDS" ] ; then
# Append an entry to the AWS Creds file
cat <<EOF>>$AWS_CONFIG_FILE

[profile sp_${ACCOUNT_NAME}]
role_arn = arn:aws:iam::${ACCOUNT_ID}:role/${AUDITROLE}
credential_source = Ec2InstanceMetadata
role_session_name = steampipe
EOF

elif [ $COMMAND == "ECS" ] ; then
# Append an entry to the AWS Creds file
cat <<EOF>>$AWS_CONFIG_FILE

[profile sp_${ACCOUNT_NAME}]
role_arn = arn:aws:iam::${ACCOUNT_ID}:role/${AUDITROLE}
credential_source = EcsContainer
role_session_name = steampipe
EOF

else


cat <<EOF>>$AWS_CONFIG_FILE

[profile sp_${ACCOUNT_NAME}]
role_arn = arn:aws:iam::${ACCOUNT_ID}:role/${AUDITROLE}
source_profile = ${SOURCE_PROFILE}
role_session_name = steampipe
EOF
fi

# And append an entry to the Steampipe config file
cat <<EOF>>$SP_CONFIG_FILE
connection "aws_${SP_NAME}" {
  plugin  = "aws"
  profile = "sp_${ACCOUNT_NAME}"
  regions = ${ALL_REGIONS}
}

EOF

done < <(aws organizations list-accounts --query Accounts[].[Name,Id,Status] --output text --profile $SOURCE_PROFILE)

if [ $COMMAND == "LOCAL" ] ; then
  echo "Now append $AWS_CONFIG_FILE to your active config file where $SOURCE_PROFILE is defined"
fi

# All done!
exit 0
