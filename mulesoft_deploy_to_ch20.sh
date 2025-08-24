#!/bin/bash
set -eo pipefail

# Variables and Constants. If variables below are not given by the pipeline (in ENV section it means it is defined in GroupVariable loaded in the stage/job and is it not secret)
SCRIPT_VERSION='20240521_01'
REDIRECT_LOG=/var/log/ch20_deployment_script.log
CURL_WITH_PROXY="curl  --noproxy"
CURL_OPTS="-L -k -sS --connect-timeout 10 --retry 5 --retry-delay 15"
CURRENT_STEP=init
POM_VERSION=""
POM_ARTIFACT_ID=""
POM_GROUP_ID=""
ANYPOINT_RESPONSE_JSON_FILE="anypoint_response.json"
OAUTH_ACCESS_TOKEN=""
CH20_APP_ID_FOUND=""
MULE_KEY=$MULE_KEY
MULE_ENV=$MULE_ENV
MULE_ENV_ID=$MULE_ENV_ID
CONNECTED_APP_CLIENT_ID=$CONNECTED_APP_CLIENT_ID
CONNECTED_APP_CLIENT_SECRET=$CONNECTED_APP_CLIENT_SECRET
ANYPOINT_CLIENT_ID=$ANYPOINT_CLIENT_ID
ANYPOINT_CLIENT_SECRET=$ANYPOINT_CLIENT_SECRET
APP_NAME=$APP_NAME
DEPLOY_REPLICAS=$DEPLOY_REPLICAS
DEPLOY_VCORES=$DEPLOY_VCORES
DEPLOY_CLUSTERED=$(echo $DEPLOY_CLUSTERED | tr '[:upper:]' '[:lower:]') 
DEPLOY_GENERATE_DEFAULT_PUBLIC_URL=$(echo $DEPLOY_GENERATE_DEFAULT_PUBLIC_URL | tr '[:upper:]' '[:lower:]') 
DEPLOY_TRACING_ENABLED=$(echo $DEPLOY_TRACING_ENABLED | tr '[:upper:]' '[:lower:]') 
DEPLOY_PUBLIC_URL_BASE=$DEPLOY_PUBLIC_URL_BASE
DEPLOY_RUNTIME=$DEPLOY_RUNTIME
DEPLOY_RELEASE_CHANNEL=$DEPLOY_RELEASE_CHANNEL
DEPLOY_JAVA_VERSION=$DEPLOY_JAVA_VERSION
DEPLOY_PS_TARGET_ID=$DEPLOY_PS_TARGET_ID
DEPLOY_OUTBOUND_RULESET_ID=$DEPLOY_OUTBOUND_RULESET_ID
DEPLOY_SKIP_VERIFICATION=$(echo $DEPLOY_SKIP_VERIFICATION | tr '[:upper:]' '[:lower:]')
DEPLOYED_APP_ID=""

LINE="\n================================================"

# ADDITIONAL_ENV_VARS_PLACEHOLDER_DO_NOT_REMOVE


function on_exit {
  local trap_code=$?
  if [ $trap_code -ne 0 ] ; then
    local ANCHOR=$(echo $CURRENT_STEP | tr "_" "-")
    echo
    echo "***********************************************************"
    echo "** Your deployment has stopped due to an error. *********"
    echo "***********************************************************"
    echo
    echo "Additional information: Error code: $trap_code; Step: $CURRENT_STEP; Line: $TRAP_LINE;"
    echo

  fi
}

function on_error {
    TRAP_LINE=$1
}

trap 'on_error $LINENO' ERR
trap on_exit EXIT

function run_step() {
    CURRENT_STEP=$1
    local DESCRIPTION=$2
    (( CURRENT_STEP_NBR++ )) || true
    echo
    echo -e "$CURRENT_STEP_NBR / $STEP_COUNT: $DESCRIPTION$LINE"
    echo -e "Started - $(date)"
    eval $CURRENT_STEP
    echo -e "Done    - $(date).\n"
}

function install_required_packages() {
    CURRENT_STEP=$FUNCNAME
    echo "Installing Required Packages ..."
    #Install any required package to run the script
}

function load_properties() {
    CURRENT_STEP=$FUNCNAME

    echo "Searching pom.properties files on: $PIPELINE_WORKSPACE"
    for file in `find "$PIPELINE_WORKSPACE" -type f -name "pom.properties"`
    do 
        echo "Loading Properties from: $file";
        source "$file"; 
    done

    POM_GROUP_ID=$groupId
    POM_ARTIFACT_ID=$artifactId
    POM_VERSION=$version
}

function validate_variables_params() {
    CURRENT_STEP=$FUNCNAME

    if ([ -z $POM_GROUP_ID ] || [ -z $POM_ARTIFACT_ID ] || [ -z $POM_VERSION ]); then
        echo "The POM GAV (groupId, artifactId, version) must be loaded from pom.properties file."
        exit 1
    fi

    if ([ -z $CONNECTED_APP_CLIENT_ID ] || [ -z $CONNECTED_APP_CLIENT_SECRET ]); then
        echo "Anypoint ConnectedApp credentials are required."
        exit 1
    fi

    if ([ -z $ANYPOINT_CLIENT_ID ] || [ -z $ANYPOINT_CLIENT_SECRET ]); then
        echo "Anypoint credentials are required."
        exit 1
    fi

    if ([ -z $APP_NAME ] || [ -z $MULE_KEY ] || [ -z $MULE_ENV ]); then
        echo "APP_NAME, MULE_KEY, and MULE_ENV are required."
        exit 1
    fi
}

function fetch_access_token() {
    CURRENT_STEP=$FUNCNAME
    echo "Fetching Anypoint Acess Token..."

    OAUTH_ENDPOINT="https://anypoint.mulesoft.com/accounts/api/v2/oauth2/token"
    OAUTH_CREDENTIALS_FILE=oauth-credentials.json
    echo "Calling ENDPOINT: $OAUTH_ENDPOINT"
    
    COUNT=0
    while :
    do
        CODE=$($CURL_WITH_PROXY $CURL_OPTS -w "%{http_code}" --request POST $OAUTH_ENDPOINT -H "Content-Type: application/x-www-form-urlencoded" --data-urlencode "client_id=$CONNECTED_APP_CLIENT_ID" --data-urlencode "client_secret=$CONNECTED_APP_CLIENT_SECRET" --data-urlencode "grant_type=client_credentials" -o $OAUTH_CREDENTIALS_FILE || true)
        echo "Calling Anypoint Endpoint: $CURL_WITH_PROXY $CURL_OPTS -w %{http_code} --request POST $OAUTH_ENDPOINT -H Content-Type: application/x-www-form-urlencoded --data-urlencode client_id=$CONNECTED_APP_CLIENT_ID --data-urlencode client_secret=$CONNECTED_APP_CLIENT_SECRET --data-urlencode grant_type=client_credentials -o $OAUTH_CREDENTIALS_FILE || true"
        echo "Calling ENDPOINT using ConnectedApp. Returned HTTP CODE: $CODE" 

        if [ "$CODE" == "200" ]; then
            OAUTH_ACCESS_TOKEN=$(cat $OAUTH_CREDENTIALS_FILE | jq -r .access_token)
            break
        fi
        let COUNT=COUNT+1
        if [ $COUNT -ge 3 ]; then
            echo "Error: Failed to fetch $COUNT times, giving up."
            exit 1
        fi
        echo "Retrying in 3 seconds..."
        sleep 3
    done
 
    echo "Exiting. Access Token = $OAUTH_ACCESS_TOKEN"
    rm $OAUTH_CREDENTIALS_FILE
}

function verify_application_is_deployed() {
    CURRENT_STEP=$FUNCNAME
    echo "Fetching deployed applications information..."

    CH20_ENDPOINT="https://anypoint.mulesoft.com/amc/application-manager/api/v2/organizations/$POM_GROUP_ID/environments/$MULE_ENV_ID/deployments"
        
    COUNT=0
    while :
    do

        CODE=$($CURL_WITH_PROXY $CURL_OPTS -w "%{http_code}" --request GET $CH20_ENDPOINT -H "Content-Type: application/json" -H "Authorization: Bearer $OAUTH_ACCESS_TOKEN" -o $ANYPOINT_RESPONSE_JSON_FILE || true)
        echo "Calling Anypoint Endpoint: $CURL_WITH_PROXY $CURL_OPTS -w %{http_code} --request GET $CH20_ENDPOINT -H Content-Type: application/json -H Authorization: Bearer $OAUTH_ACCESS_TOKEN -o $ANYPOINT_RESPONSE_JSON_FILE || true"
        echo "Fetching deployed applications. Returned code: $CODE"
        if [ "$CODE" == "200" ]; then
            break
        fi
        let COUNT=COUNT+1
        if [ $COUNT -ge 3 ]; then
            echo "Error: Failed to fetch existing deployed applications $COUNT times, giving up."
            exit 1
        fi
        echo "Retrying in 3 seconds..."
        sleep 3
    done
    
    echo "Checking if the application $APP_NAME is deployed ..."
    APP_NAME_INSENSITIVE=$(echo "$APP_NAME" | tr '[:lower:]' '[:upper:]')

    CH20_APP_ID_FOUND=$(jq -r --arg APP_NAME_INSENSITIVE "$APP_NAME_INSENSITIVE" '.items | map(select(.name | ascii_upcase == $APP_NAME_INSENSITIVE)) | .[].id' $ANYPOINT_RESPONSE_JSON_FILE)
    
    if [ "$CH20_APP_ID_FOUND" != "" ]; then
        echo "Application $APP_NAME already deployed"
    else
        echo "Application $APP_NAME not deployed"
    fi
    rm $ANYPOINT_RESPONSE_JSON_FILE
}

function undeploy_application() {
    CURRENT_STEP=$FUNCNAME
    CH20_APP_ID_FOUND=$1
    CH20_ENDPOINT="https://anypoint.mulesoft.com/amc/application-manager/api/v2/organizations/$POM_GROUP_ID/environments/$MULE_ENV_ID/deployments/$CH20_APP_ID_FOUND"

    COUNT=0
    while :
    do

        CODE=$($CURL_WITH_PROXY $CURL_OPTS -w "%{http_code}" --request DELETE $CH20_ENDPOINT -H "Authorization: Bearer $OAUTH_ACCESS_TOKEN" -o $ANYPOINT_RESPONSE_JSON_FILE || true)
        echo "Undeploying application. Returned code: $CODE"
        if ([ "$CODE" == "200" ] || [ "$CODE" == "204" ]); then
            break
        fi
        let COUNT=COUNT+1
        if [ $COUNT -ge 3 ]; then
            echo "Error: Failed to fetch existing deployed applications $COUNT times, giving up."
            exit 1
        fi
        echo "Retrying in 3 seconds..."
        sleep 3
    done

    echo "Application ID: $CH20_APP_ID_FOUND undeployed."

    rm $ANYPOINT_RESPONSE_JSON_FILE    
}

function deploy_application() {
    CURRENT_STEP=$FUNCNAME

    verify_application_is_deployed

    echo "CH20_APP_ID_FOUND: $CH20_APP_ID_FOUND"
    echo "POM_VERSION: $POM_VERSION"

    #If application is already deployed and version is a SNAPSHOT, we need to remove the application before deploy it.
    if [[ $CH20_APP_ID_FOUND != "" && ("$POM_VERSION" == *"-SNAPSHOT" || "$POM_VERSION" == *"-snapshot") ]]; then
        echo "Snapshot version to be deployed. Existing application should be undeployed first."
        undeploy_application $CH20_APP_ID_FOUND
        CH20_APP_ID_FOUND=""
    fi

    CH20_ENDPOINT="https://anypoint.mulesoft.com/amc/application-manager/api/v2/organizations/$POM_GROUP_ID/environments/$MULE_ENV_ID/deployments"
    HTTP_METHOD="POST"

    CH20_DEPLOY_PAYLOAD=$(cat <<- EOF
    {
        "name": "$APP_NAME",
        "target": {
            "provider": "MC",
            "targetId": "$DEPLOY_PS_TARGET_ID",
            "deploymentSettings": {
                "clustered": $DEPLOY_CLUSTERED,
                "enforceDeployingReplicasAcrossNodes": true,
                "http": {
                    "inbound": {
                        "publicUrl": "$DEPLOY_PUBLIC_URL_BASE/$APP_NAME",
                        "forwardSslSession": false
                    }
                },
                "updateStrategy": "rolling",
                "forwardSslSession": false,
                "generateDefaultPublicUrl": $DEPLOY_GENERATE_DEFAULT_PUBLIC_URL,
                "runtime": {
                    "version": "$DEPLOY_RUNTIME",
                    "releaseChannel": "$DEPLOY_RELEASE_CHANNEL",
                    "java": "$DEPLOY_JAVA_VERSION"
                }
            },
            "replicas": $DEPLOY_REPLICAS
        },
        "application": {
            "desiredState": "STARTED",
            "ref": {
                "groupId": "$POM_GROUP_ID",
                "artifactId": "$POM_ARTIFACT_ID",
                "version": "$POM_VERSION",
                "packaging": "jar"
            },
            "configuration": {
                "mule.agent.application.properties.service": {
                    "properties": {
                        "anypoint.platform.config.analytics.agent.enabled": "true",
                        "mule.env": "$MULE_ENV"
                    },
                    "secureProperties": {
                        "mule.key": "$MULE_KEY",
                        "anypoint.platform.client_id": "$ANYPOINT_CLIENT_ID",
                        "anypoint.platform.client_secret": "$ANYPOINT_CLIENT_SECRET"
                    }
                }
            },
            "vCores": $DEPLOY_VCORES
        }
    }
EOF
)

    if [ "$CH20_APP_ID_FOUND" != "" ]; then
        CH20_ENDPOINT="https://anypoint.mulesoft.com/amc/application-manager/api/v2/organizations/$POM_GROUP_ID/environments/$MULE_ENV_ID/deployments/$CH20_APP_ID_FOUND"
        HTTP_METHOD="PATCH"
    fi

    echo "CH20_ENDPOINT: $CH20_ENDPOINT"
    echo "HTTP_METHOD: $HTTP_METHOD"
    echo "CH20_DEPLOY_PAYLOAD: $CH20_DEPLOY_PAYLOAD"

    COUNT=0
    while :
    do
        CODE=$($CURL_WITH_PROXY $CURL_OPTS -w "%{http_code}" --request $HTTP_METHOD $CH20_ENDPOINT -H "Content-Type: application/json" -H "Authorization: Bearer $OAUTH_ACCESS_TOKEN" --data-raw "$CH20_DEPLOY_PAYLOAD" -o $ANYPOINT_RESPONSE_JSON_FILE || true)
        echo "Deploying/Redeploying application. Returned code: $CODE"
        if ([ "$CODE" == "200" ] || [ "$CODE" == "201" ] || [ "$CODE" == "202" ] || [ "$CODE" == "204" ]); then
            DEPLOYED_APP_ID=$(cat $ANYPOINT_RESPONSE_JSON_FILE | jq -r .id)
            break
        fi
        echo "Error during deployment. Response: $(<$ANYPOINT_RESPONSE_JSON_FILE)"
        let COUNT=COUNT+1
        if [ $COUNT -ge 3 ]; then
            echo "Error: Failed to deploy/redeploy $COUNT times, giving up."
            exit 1
        fi
        echo "Retrying in 3 seconds..."
        sleep 3
    done    
    
    echo "Deployment request successful."

    rm $ANYPOINT_RESPONSE_JSON_FILE
}

function verify_deployment() {
    CURRENT_STEP=$FUNCNAME

    if [ "$DEPLOY_SKIP_VERIFICATION" == "true" ]; then
        echo "DEPLOY_SKIP_VERIFICATION variable set to TRUE, skipping deployment verification ..."
        
    else
        CH20_ENDPOINT="https://anypoint.mulesoft.com/amc/application-manager/api/v2/organizations/$POM_GROUP_ID/environments/$MULE_ENV_ID/deployments/$DEPLOYED_APP_ID"
        COUNT=0

        while :
        do

            CODE=$($CURL_WITH_PROXY $CURL_OPTS -w "%{http_code}" --request GET $CH20_ENDPOINT -H "Content-Type: application/json" -H "Authorization: Bearer $OAUTH_ACCESS_TOKEN" -o $ANYPOINT_RESPONSE_JSON_FILE || true)
            if [ "$CODE" == "200" ]; then
                APP_STATUS=$(cat $ANYPOINT_RESPONSE_JSON_FILE | jq -r .status)
                if [ "$APP_STATUS" == "APPLIED" ]; then
                    break
                fi            
            fi
            let COUNT=COUNT+1
            if [ $COUNT -ge 12 ]; then #12 attempts every 30 secs = 6 min timeout
                echo "Error: Application is not deployed after 360 seconds, giving up."
                exit 1
            fi
            echo "ATTEMPT $COUNT: Application still being deployed, retrying in 30 seconds..."
            sleep 30
        done

        echo "SUCCESS: Application has been deployed."
        rm $ANYPOINT_RESPONSE_JSON_FILE
    fi        
}

##########################################
# Entrypoint
##########################################

# Also log output to file
exec >& >(tee -a "$REDIRECT_LOG")


echo -e "Deployment Script version: $SCRIPT_VERSION started at: $(date)"

# Running required steps
STEP_COUNT=6

#Pre requirements steps - Start
run_step load_properties "Load required properties file from staging area"
run_step validate_variables_params "Validate Variables and parameters"
run_step install_required_packages "Install required packages"
#Pre requirements steps - End

#Deployment steps - Start
run_step fetch_access_token "Fetch Anypoint Access Token"
run_step deploy_application "Deploy Application"
#Deployment steps - End

#Post Deployment steps - Start
run_step verify_deployment "Verifying Deployment"
#Post Deployment steps - End

echo -e "Deployment Script completed at: $(date)"
