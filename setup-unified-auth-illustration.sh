#!/bin/bash

# Copyright 2023-2024 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

EXAMPLE_NAME="unified-auth"
PROXY_NAMES=("example-proxy-1" "example-proxy-2" "example-oauth2-cc")
PRODUCT_NAME="Unified-Auth-Product"

create_apiproduct() {
    local product_name=$1
    local auth_variant=$2
    local ops_file="./configuration-data/operations-defn-${product_name}.json"
    if apigeecli products get --name "${product_name}" --org "$PROJECT" --token "$TOKEN" --disable-check >>/dev/null 2>&1; then
        printf "  The apiproduct %s already exists!\n" "${product_name}"
    else
        [[ ! -f "$ops_file" ]] && printf "missing operations definition file %s\n" "$ops_file" && exit 1
        apigeecli products create --name "${product_name}" --display-name "${product_name}" \
            --opgrp "$ops_file" \
            --attrs "required-auth-variant=${auth_variant}" \
            --envs "$APIGEE_ENV" --approval auto \
            --org "$PROJECT" --token "$TOKEN" --disable-check
    fi
}

create_app() {
    local product_name=$1
    local developer=$2
    local app_name="${EXAMPLE_NAME}-app-$3"
    local KEYPAIR

    local NUM_APPS
    NUM_APPS=$(apigeecli apps get --name "${app_name}" --org "$PROJECT" --token "$TOKEN" --disable-check | jq -r .'| length')
    if [[ $NUM_APPS -eq 0 ]]; then
        KEYPAIR=($(apigeecli apps create --name "${app_name}" --email "${developer}" \
            --prods "${product_name}" \
            --org "$PROJECT" --token "$TOKEN" --disable-check |
            jq -r ".credentials[0] | .consumerKey,.consumerSecret"))
    else
        # must not echo here, it corrupts the return value of the function.
        # printf "  The app %s already exists!\n" ${app_name}
        KEYPAIR=($(apigeecli apps get --name "${app_name}" \
            --org "$PROJECT" --token "$TOKEN" --disable-check |
            jq -r ".[0].credentials[0] | .consumerKey,.consumerSecret"))

    fi
    echo "${KEYPAIR[@]}"
}

maybe_import_and_deploy_sharedflow() {
    local sf_name=$1
    maybe_import_and_deploy "sharedflows" "$sf_name"
}

maybe_import_and_deploy_apiproxy() {
    local proxy_name=$1
    maybe_import_and_deploy "apis" "$proxy_name"
}

maybe_import_and_deploy() {
    local thing_type=$1
    local thing_name=$2
    local dir_name

    local REV
    local need_deploy=0
    local need_import=0

    if [[ "$thing_type" == "apis" ]]; then
        dir_name="apiproxy"
    else
        dir_name="sharedflowbundle"
    fi

    OUTFILE=$(mktemp /tmp/apigee-samples.apigeecli.out.XXXXXX)
    if apigeecli "$thing_type" get --name "$thing_name" --org "$PROJECT" --token "$TOKEN" --disable-check >"$OUTFILE" 2>&1; then
        LATESTREV=$(jq -r ".revision[-1]" "$OUTFILE")
        if [[ -z "${LATESTREV}" ]]; then
            need_import=1
        else
            if apigeecli "$thing_type" listdeploy --name "$thing_name" --org "$PROJECT" --token "$TOKEN" --disable-check >"$OUTFILE" 2>&1; then
                NUM_DEPLOYS=$(jq -r '.deployments | length' "$OUTFILE")
                if [[ $NUM_DEPLOYS -eq 0 ]]; then
                    need_deploy=1
                    REV=$LATESTREV
                fi
            else
                need_deploy=1
                REV=$LATESTREV
            fi
        fi
    else
        need_import=1
    fi

    if [[ ${need_import} -eq 1 ]]; then
        REV=$(apigeecli "$thing_type" create bundle -f "./${thing_type}/${thing_name}/${dir_name}" -n "$thing_name" --org "$PROJECT" --token "$TOKEN" --disable-check | jq ."revision" -r)
        need_deploy=1

    fi

    if [[ ${need_deploy} -eq 1 ]]; then
        apigeecli "$thing_type" deploy --name "$thing_name" --rev "$REV" \
            --org "$PROJECT" --env "$APIGEE_ENV" \
            --ovr --wait \
            --token "$TOKEN" \
            --disable-check
    fi
}

MISSING_ENV_VARS=()
[[ -z "$PROJECT" ]] && MISSING_ENV_VARS+=('PROJECT')
[[ -z "$APIGEE_ENV" ]] && MISSING_ENV_VARS+=('APIGEE_ENV')

[[ ${#MISSING_ENV_VARS[@]} -ne 0 ]] && {
    printf -v joined '%s,' "${MISSING_ENV_VARS[@]}"
    printf "You must set these environment variables: %s\n" "${joined%,}"
    exit 1
}

TOKEN=$(gcloud auth print-access-token)

printf "Importing and Deploying the Apigee sharedflow...\n"
maybe_import_and_deploy_sharedflow "apigeesample-unified-auth"

for pname in "${PROXY_NAMES[@]}"; do
    printf "Importing and Deploying the Apigee proxy [%s]...\n" "$pname"
    maybe_import_and_deploy_apiproxy "$pname" &
done
wait

echo "Checking and possibly Creating API Products..."
create_apiproduct "${PRODUCT_NAME}-1" "apikey"
create_apiproduct "${PRODUCT_NAME}-2" "token"

DEVELOPER_EMAIL="${EXAMPLE_NAME}-apigeesamples@acme.com"
printf "Checking and possibly Creating Developer %s ...\n" "${DEVELOPER_EMAIL}"
if apigeecli developers get --email "${DEVELOPER_EMAIL}" --org "$PROJECT" --token "$TOKEN" --disable-check >>/dev/null 2>&1; then
    printf "  The developer already exists.\n"
else
    apigeecli developers create --user "${DEVELOPER_EMAIL}" --email "${DEVELOPER_EMAIL}" \
        --first UnifiedAuth --last SampleDeveloper \
        --org "$PROJECT" --token "$TOKEN" --disable-check
fi

echo "Checking and possibly Creating Developer Apps..."

# shellcheck disable=SC2046,SC2162
APP1_CREDS=($(create_app "${PRODUCT_NAME}-1" "${DEVELOPER_EMAIL}" "apikey"))
APP2_CREDS=($(create_app "${PRODUCT_NAME}-2" "${DEVELOPER_EMAIL}" "token"))

echo " "
echo "All the Apigee artifacts are successfully created."
echo " "
echo "Credentials:"
echo " "
echo "  CLIENT_ID_FOR_APP1=${APP1_CREDS[0]}"
echo "  CLIENT_SECRET_FOR_APP1=${APP1_CREDS[1]}"
echo " "
echo "  CLIENT_ID_FOR_APP2=${APP2_CREDS[0]}"
echo "  CLIENT_SECRET_FOR_APP2=${APP2_CREDS[1]}"
echo " "
echo "Copy/paste the above, and then try: "
echo ""
echo " curl -i \$apigee/example-proxy-1/t1 \\"
echo "    -H \"X-apikey:\${CLIENT_ID_FOR_APP1}\" "
echo " "
echo " curl -i \$apigee/example-proxy-1/t1 \\"
echo "    -H \"X-apikey:\${CLIENT_ID_FOR_APP2}\" "
echo " "
echo " "
echo " curl -i \$apigee/example-oauth2-cc/token -d grant_type=client_credentials \\"
echo "    -u \"\${CLIENT_ID_FOR_APP2}:\${CLIENT_SECRET_FOR_APP2}\""
echo " access_token=...token-value-from-above..."
echo " curl -i \$apigee/example-proxy-1/t1 \\"
echo "    -H \"Authorization: Bearer \${access_token}\""
echo " "
echo " curl -i \$apigee/example-oauth2-cc/token -d grant_type=client_credentials \\"
echo "    -u \"\${CLIENT_ID_FOR_APP1}:\${CLIENT_SECRET_FOR_APP1}\""
echo " access_token=...token-value-from-above..."
echo " curl -i \$apigee/example-proxy-1/t1 \\"
echo "    -H \"Authorization: Bearer \${access_token}\""
echo " "
