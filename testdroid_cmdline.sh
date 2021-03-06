#!/bin/bash
# Start appium test on testdroid using
# "Parallel-test-runs"-API, aka "Server-side-appium-tests"
# Requires: jq (cmdline json parser)

# Configure statically
#PROJECT_NAME="Appium Server Side Demo"
TEST_RUN_NAME="Server Side cmdline Demo"

ios_start_script='run-tests-ios.sh'
android_start_script='run-tests-android.sh'
generic_start_script='run-tests.sh'

# Work from this directory
cd "$(dirname "$0")" || exit

# Consts
CLEANUP_FILES=(
  'node_modules'
  'screenshots'
  'TEST-all.xml'
  'logcat.log'
  'console.log'
  'syslog.log'
  'results'
)

TD_CLOUD_BASE_URL="https://cloud.bitbar.com"
TD_TOKEN_URL="${TD_CLOUD_BASE_URL}/oauth/token"
TD_PROJECTS_URL="${TD_CLOUD_BASE_URL}/api/v2/me/projects"
TD_UPLOAD_FILE_URL="${TD_CLOUD_BASE_URL}/api/v2/me/files"
TD_RUN_TEST_URL="${TD_CLOUD_BASE_URL}/api/v2/me/runs"
TD_USER_DEVICE_GROUPS_URL="${TD_CLOUD_BASE_URL}/api/v2/me/device-groups?limit=0"
TD_USER_FRAMEWORKS_URL="${TD_CLOUD_BASE_URL}/api/v2/me/available-frameworks?limit=0"
TD_TEST_RUNS_URL_TEMPLATE="${TD_CLOUD_BASE_URL}/api/v2/me/projects/<projectId>/runs"
TD_TEST_RUN_ITEM_URL_TEMPLATE="${TD_TEST_RUNS_URL_TEMPLATE}/<runId>"
TD_TEST_DEVICE_SESSION_URL_TEMPLATE="${TD_TEST_RUN_ITEM_URL_TEMPLATE}/device-sessions"
TD_TEST_RUN_ITEM_BROWSER_URL_TEMPLATE="${TD_CLOUD_BASE_URL}/#testing/test-run/<projectId>/<runId>"
TD_DEFAULT_HEADER="Accept: application/json"
TEST_ZIP_FILE='test.zip'
CURL_SILENT=" -s "
TOKEN_TMP_FILE="_token.json"
PLATFORM="NOT-SET"
SIMULATE=0
SCHEDULER="PARALLEL"
TEST_RESULTS_DIR="results"
PROJECT_TIMEOUT=600
TESTDROID_SSA_CLIENT_TIMEOUT=0
CONNECTION_FAILURES_LIMIT=20
PROJECT_LOCK_TIMEOUT=120
RESULT_LIMIT=0 # Limit for the result file count
LOCK_GRACE_PERIOD=5
INSTANCE="$(echo $HOSTNAME || tr -cd '[[:alnum:]]._-')-$RANDOM"

# Helper Functions
function usage(){
  echo -e "usage:\n   $0 OPTIONS"
  echo -e "Test run OPTIONS:"
  echo -e "\t -z\tThe tests-folder which will be archived and sent to testdroid (required)"
  echo -e "\t -b\tFramework id to be used (required)"
  echo -e "\t -o\tOsType to be used (required)"
  echo -e "\t -u\tUsername (required, can also use API-key here)"
  echo -e "\t -p\tPassword (required unless using API-key)"
  echo -e "\t -t\tTestdroid project name (required)"
  echo -e "\t -a\tApp build file to test (apk/ipa) (required, also selects platform)"
  echo -e "\t -r\tTestdroid test run name"
  echo -e "\t -d\tTestdroid deviceGroup ID to use (default: previous one)"
  echo -e "\t -l\tList Testdroid deviceGroups & frameworks"
  echo -e "\t -s\tSimulate (Upload tests and app and configure project. Don't actually run test)"
  echo -e "\t -c\tSet scheduler for test, options are [PARALLEL, SERIAL, SINGLE] (default: PARALLEL)"
  echo -e "\t -f\tSkip video files when downloading test results"
  echo -e "\t -i\tSet timeout value for project in seconds. Will use 600s (10min) unless specified"
  echo -e "\t -x\tSet timeout value for testdroid client run. There's no timeout by default."
  echo -e "\t -q\tSet counter for auto retrying failed devices. Default counter value is 3."
  echo -e "Project timeout vs. testdroid client timeout:"
  echo -e "\t Project timeout applies to a single device run, whereas testdroid client timeout sets"
  echo -e "\t maximum duration for the testdroid-client run. When the client timeout is reached,"
  echo -e "\t all the queued devices will be aborted, and the results from finished devices"
  echo -e "\t will be fetched."
  echo -e "After test run OPTIONS:"
  echo -e "\t -n\tSpecify a testRunId, client will only fetch those results and exit (numeric id, check test results URL)"
  echo -e "Misc OPTIONS"
  echo -e "\t -h\tShow this message"
  echo -e "\t -v\tVerbose"
  echo -e "Example:"
  echo -e "\t$0 -u you@yourdomain.com -p hunter2 -t \"Example test Project\" -r \"Nightly run, Monday\" -a path/to/build.apk -o \"ANDROID\" -f 248"
}

function verbose() {
  set -o xtrace
  CURL_SILENT=""
}

function get_full_path {
  echo "$( cd "$(dirname "$1")"; echo "$(pwd)/$(basename "$1")" )"
}

function prettyp {
  echo -e "[$(date +"%T")] $1"
}

function rational_to_percent {
  echo "$(echo "$1*100"|bc)"
}

function authenticate {
  # Get token for testdroid
  # Don't log in if using token (no password specified)
  if [ -n "$PASSWORD" ]; then
    auth_curl_data="client_id=testdroid-cloud-api&grant_type=password&username=${TD_USER}"
    auth_curl_data="${auth_curl_data}&password=${PASSWORD}"
    curl ${CURL_SILENT} -X POST -H "${TD_DEFAULT_HEADER}" -d "${auth_curl_data}" $TD_TOKEN_URL > "${TOKEN_TMP_FILE}"
    auth_error=$(jq '.error_description' "${TOKEN_TMP_FILE}")
    if [ "${auth_error}" != "null" ]; then echo "ERROR LOGGING IN! '${auth_error}'. Please check credentials" ; exit 1 ; fi
  fi
}

function get_token {
  if [ ! -f $TOKEN_TMP_FILE ]; then
    authenticate
  fi
  access_token=$(jq -r '.access_token' $TOKEN_TMP_FILE)
  refresh_token=$(jq -r '.refresh_token' $TOKEN_TMP_FILE)
  # token should be refreshed when it's half way done
  refresh_token_after=$(echo "$(date +"%s") + $(echo "$(jq '.expires_in' $TOKEN_TMP_FILE)/2" |bc)" |bc)

  # Refresh token if needed
  if [ "$(date +"%s")" -gt "$refresh_token_after" ]; then
    refresh_auth_curl_data="client_id=testdroid-cloud-api&grant_type=refresh_token&refresh_token=${refresh_token}"
    curl ${CURL_SILENT} -X POST -H "${TD_DEFAULT_HEADER}" -d "${refresh_auth_curl_data}" $TD_TOKEN_URL > "${TOKEN_TMP_FILE}"
    access_token=$(jq -r '.access_token' $TOKEN_TMP_FILE)
    refresh_token=$(jq -r '.refresh_token' $TOKEN_TMP_FILE)
    refresh_token_after=$(echo "$(date +"%s") + $(echo "$(jq '.expires_in' $TOKEN_TMP_FILE)/2" |bc)" |bc)
    if [ "$access_token" == "null" ]; then
      echo "Bad access token, check credentials: '${access_token}'"
      exit 3
    fi
  fi

  if [ "$access_token" == "null" ]; then
    prettyp "Bad access token, check credentials: '${access_token}'"
    exit 3
  fi
  echo "$access_token"
}

########################################
# Authenticates using either username + password
# OR API key and sets default values for curl-call
# Arguments:
#   Any additional curl switches and options
# Returns:
#   response (String)
#########################################

function auth_curl {
  if [ -n "$PASSWORD" ]; then
    project_listing_header="Authorization: Bearer $(get_token)"
    curl ${CURL_SILENT} -H "${TD_DEFAULT_HEADER}" -H "${project_listing_header}" "$@"
  else
    # Reason for ':' in -u flag: user:password but with password left empty
    curl ${CURL_SILENT} -H "${TD_DEFAULT_HEADER}" -u "${TD_USER}:" "$@"
  fi
}

########################################
# Create an url from an url template
# Globals:
#   PROJECT_ID
# Arguments:
#   test_run_id (optional)
# Returns:
#   url (String)
#########################################
function url_from_template {
  template=$1
  project_id=$PROJECT_ID
  if [ -z "${project_id}" ]; then
    project_id=$(get_project_id "$PROJECT_NAME")
  fi
  test_run_id=$2
  sed -e "s/<runId>/${test_run_id}/" -e "s/<projectId>/${project_id}/" <<< "${template}"
}

########################################
# Fetch project_id for defined project name
# Arguments:
#   project_name
# Returns:
#   project_id (sets PROJECT_ID env variable)
#########################################
function get_project_id {
  project_name=$1
  PROJECT_ID=$(auth_curl "${TD_PROJECTS_URL}?filter=s_name_eq_${project_name}" | jq ".data[0].id")
  if [ -z "${PROJECT_ID}" ]; then
    echo "Cannot read project_id for project '$project_name'"
    exit 88
  fi
  echo "$PROJECT_ID"
}

########################################
# Print TD device groups
# Globals:
#   PROJECT_ID
# Arguments:
#   None
# Returns:
#   Void (prints device groups)
#########################################
function list_device_groups_and_frameworks {
  prettyp "Device groups for user: $(auth_curl "${TD_USER_DEVICE_GROUPS_URL}" |jq "")"
  prettyp "Frameworks for user: $(auth_curl "${TD_USER_FRAMEWORKS_URL}" |jq "")"
}

########################################
# Upload file to cloud
# Arguments:
#   full_path
# Returns:
#   file_id
#########################################
function upload_file_to_cloud {
  full_path=$1
  response=$(auth_curl -POST -F file=@"${full_path}" "${TD_UPLOAD_FILE_URL}")
  file_upload_id=$(echo "$response" | jq '.id')
  if [ -z "$file_upload_id" ]; then
    prettyp "ERROR: Uploading of file failed. Response was: \"$response\""
    exit 4
  fi
  if [ "$file_upload_id" == "null" ]; then
    prettyp "ERROR: Uploading of file failed. Response was: \"$response\""
    exit 4
  fi
  echo "$file_upload_id"
}

########################################
# Start test run
# Arguments:
#   test_run_name
# Returns:
#   test_run_id
#########################################
function start_test_run {
  JSON_STRING='{"testRunName":"'"$TEST_RUN_NAME"'","osType":"'"$OS_TYPE"'","frameworkId":"'"$FRAMEWORK_ID"'","projectId":"'"$PROJECT_ID"'","timeout":"'"$PROJECT_TIMEOUT"'","scheduler":"'"$SCHEDULER"'","deviceGroupId":"'"$DEVICE_GROUP_ID"'","maxAutoRetriesCount":"'"$AUTO_RETRY_COUNT"'","files":[{"id":"'"$1"'"},{"id":"'"$2"'"}]}'
  test_runs_url=$(url_from_template "${TD_TEST_RUNS_URL_TEMPLATE}")
  response=$(auth_curl -POST -H "Content-Type: application/json" --data "$JSON_STRING" "$TD_RUN_TEST_URL")
  test_run_id=$(echo "$response" | jq '.id')
  if [ -z "$test_run_id" ]; then
    prettyp "Did not get a test_run_id. Maybe test didn't start? Response was $response"
    exit 6
  fi
  echo "$test_run_id"
}

########################################
# Get human readable name for device
# Arguments:
#   test_run_id
#   device_session_id
# Returns:
#   String (human readable device id (or device_session_id if failure))
#########################################
function get_device_human_name {
  test_run_id="$1"
  device_session_id="$2"
  device_info_json=$(get_device_info_json $test_run_id $device_session_id)
  human_name=$(echo "$device_info_json" |jq -r '.device.displayName + "-API\(.device.softwareVersion.apiLevel)"' |sed -e s/[^a-zA-Z0-9_-]/_/g)
  safe_human_name=$(sed -e s/[^a-zA-Z0-9_-]/_/g <<< "$human_name")
  safe_human_name=${safe_human_name:=$device_session_id}
  echo "$safe_human_name-$device_session_id"
}

########################################
# Get device_info_json
# Arguments:
#   test_run_id
#   device_session_id
# Returns:
#   String (json response for device_info)
#########################################
function get_device_info_json {
  test_run_id="$1"
  device_session_id="$2"
  test_run_item_url=$(url_from_template "${TD_TEST_RUN_ITEM_URL_TEMPLATE}" "${test_run_id}")
  device_info_url="$test_run_item_url/device-sessions/$device_session_id"
  device_info_json=$(auth_curl "$device_info_url" --fail)
  echo "$device_info_json"
}

########################################
# Check if device was excluded from testrun
# Arguments:
#   test_run_id
#   device_session_id
# Returns:
#   bool (0 for false, 1 for true)
#########################################
function was_device_excluded {
  test_run_id="$1"
  device_session_id="$2"
  device_info_json=$(get_device_info_json "$test_run_id" "$device_session_id")
  device_status=$(echo "$device_info_json" |jq -r '.state')
  if [ "$device_status" == "EXCLUDED" ]; then
    echo "1"
  else
    echo "0"
  fi
}

########################################
# Get all test results and files
# Arguments:
#   test_run_id
# Returns:
#   Void (writes files to subfolder TEST_RESULTS_DIR)
#########################################
function get_result_files {
  echo "let's do this"
  test_run_id=$1
  device_runs_url=$(url_from_template "${TD_TEST_DEVICE_SESSION_URL_TEMPLATE}" "${test_run_id}")
  response=$(auth_curl "${device_runs_url}")
  device_session_ids=$(echo "$response" | jq '.data[].id')
  rm -rf "${TEST_RESULTS_DIR:?}"
  mkdir -p $TEST_RESULTS_DIR
  for device_session_id in $device_session_ids; do
    if [ "$(was_device_excluded "$test_run_id" "$device_session_id")" == "0" ]; then
      device_human_name="$(get_device_human_name "$test_run_id" "$device_session_id")"
      get_device_result_files "$test_run_id" "$device_session_id" "$device_human_name"
      get_device_screenshots "$test_run_id" "$device_session_id" "$device_human_name"
    fi
  done

  if [ -z "$(ls -A ${TEST_RESULTS_DIR}/*.xml)" ]; then
    echo "no junit results files could be found"
    exit 140
  fi
}

########################################
# Checks if there are devices with RUNNING state in the test run
# Arguments:
#   test_run_id
# Returns:
#   bool (0 for false, 1 for true)
########################################
function are_devices_running {
  test_run_id=$1
  device_runs_url=$(url_from_template "${TD_TEST_DEVICE_SESSION_URL_TEMPLATE}" "${test_run_id}")
  response=$(auth_curl "${device_runs_url}")
  device_session_ids=$(echo "$response" | jq '.data[].id')
  devices_are_running="0"

  for device_session_id in $device_session_ids; do
    device_info_json=$(get_device_info_json "$test_run_id" "$device_session_id")
    device_status=$(echo "$device_info_json" |jq -r '.state')
    if [ "$device_status" == "RUNNING" ]; then
      devices_are_running="1"
      break
    fi
  done

  echo "$devices_are_running"
}

########################################
# Abort current test run
# Arguments:
#   None
# Returns:
#   Void (aborts run, prints response)
#########################################
function abort_run {
  test_run_url=$(url_from_template "${TD_TEST_RUN_ITEM_URL_TEMPLATE}" "${test_run_id}")
  status=$( auth_curl -X POST "${test_run_url}/abort" | jq ".state")
  echo "$status"
}


########################################
# Get all test results and files for the device
# Arguments:
#   test_run_id
#   device_session_id
#   device_human_name
# Returns:
#   Void (writes files to subfolder TEST_RESULTS_DIR)
#########################################
function get_device_result_files {
  test_run_id="$1"
  device_session_id="$2"
  device_human_name="$3"
  test_run_item_url=$(url_from_template "${TD_TEST_RUN_ITEM_URL_TEMPLATE}" "${test_run_id}")
  device_info_url="$test_run_item_url/device-sessions/$device_session_id"
  device_session_files_url="$test_run_item_url/device-sessions/$device_session_id/output-file-set/files?limit=${RESULT_LIMIT}"
  response=$(auth_curl "$device_session_files_url")
  device_file_ids=$(echo "$response" | jq '.data[] |"\(.id);\(.name)"')
  for file_specs in $device_file_ids; do
    get_device_result_file "$test_run_id" "$device_session_id" "$device_human_name" "$file_specs"
  done
}


########################################
# Count all errors and failures in junit xml results
# Returns:
#  Total count
########################################
function get_total_failures {
  errors=$(grep "errors=" ${TEST_RESULTS_DIR}/*.xml | sed s/.*errors=\"//g | sed s/\".*//g | awk '{ SUM += $1} END { print SUM }')
  errors=${errors:=0}
  failures=$(grep "failures=" ${TEST_RESULTS_DIR}/*.xml | sed s/.*failures=\"//g | sed s/\".*//g | awk '{ SUM += $1} END { print SUM }')
  failures=${failures:=0}

  if [[ $errors > 0 ]] && [[ $failures > 0 ]]; then
    echo $(($errors+$failures))
  elif [[ $errors > 0 ]]; then
    echo $errors
  elif [[ $failures > 0 ]]; then
    echo $failures
  else
    echo 0
  fi
}


########################################
# Get a device result file
# Arguments:
#   test_run_id
#   device_session_id
#   device_human_name
#   semicolon-separated string like "$file_id;$filename"
# Returns:
#   Void (writes files to subfolder TEST_RESULTS_DIR)
#########################################
function get_device_result_file {
  test_run_id="$1"
  device_session_id="$2"
  device_human_name="$3"
  file_id=$(sed -e 's/"//g' -e 's/;.*//g' <<< "$4")
  filename=$(sed -e 's/"//g' -e 's/.*;//g' <<< "$4")
  if [[ "$SKIP_VIDEO_RESULTS" == "1" ]] && [[ ${filename: -4} == ".mp4" ]];
  then
    return 0
  fi
  file_item_url="${TD_CLOUD_BASE_URL}/api/me/files/$file_id/file"
  auth_curl "$file_item_url" --fail --output "${TEST_RESULTS_DIR}/${device_session_id}_${device_human_name}_$filename"
}


########################################
# Get all screenshots for a device
# Arguments:
#   test_run_id
#   device_session_id
#   device_human_name
# Returns:
#   Void (writes files to subfolder TEST_RESULTS_DIR)
#########################################
function get_device_screenshots {
  test_run_id="$1"
  device_session_id="$2"
  device_human_name="$3"
  test_run_item_url=$(url_from_template "${TD_TEST_RUN_ITEM_URL_TEMPLATE}" "${test_run_id}")
  device_session_screenshots_url="$test_run_item_url/device-sessions/$device_session_id/screenshots"
  response=$(auth_curl "$device_session_screenshots_url")
  device_screenshot_ids=$(echo "$response" | jq '.data[] |"\(.id);\(.originalName)"')
  for screenshot_specs in $device_screenshot_ids; do
    get_device_screenshot_file "$test_run_id" "$device_session_id" "$device_human_name" "$screenshot_specs"
  done
}


########################################
# Get a device screenshot file
# Arguments:
#   test_run_id
#   device_session_id
#   device_human_name
#   semicolon-separated string like "$file_id;$filename"
# Returns:
#   Void (writes files to subfolder TEST_RESULTS_DIR)
#########################################
function get_device_screenshot_file {
  test_run_id="$1"
  device_session_id="$2"
  device_human_name="$3"
  file_id=$(sed -e 's/"//g' -e 's/;.*//g' <<< "$4")
  filename=$(sed -e 's/"//g' -e 's/.*;//g' <<< "$4")
  test_run_item_url=$(url_from_template "${TD_TEST_RUN_ITEM_URL_TEMPLATE}" "${test_run_id}")
  file_item_url="${test_run_item_url}/device-sessions/${device_session_id}/screenshots/${file_id}"
  screenshot_device_folder="${TEST_RESULTS_DIR}/screenshots/${device_human_name}"
  mkdir -p "${screenshot_device_folder}"
  auth_curl "$file_item_url" --fail --output "${screenshot_device_folder}/${filename}"
}


# Commandline arguments
while getopts hvslfu:p:t:r:a:d:c:i:z:n:x:q:b:o: OPTIONS; do
  case $OPTIONS in
    z ) TEST_ARCHIVE_FOLDER=$OPTARG ;;
    u ) TD_USER=$OPTARG ;;
    p ) PASSWORD=$OPTARG ;;
    t ) PROJECT_NAME=$OPTARG ;;
    r ) TEST_RUN_NAME=$OPTARG ;;
    a ) APP_PATH=$OPTARG ;;
    d ) DEVICE_GROUP_ID=$OPTARG ;;
    l ) LIST_DEVICES_AND_FRAMEWORKS_ONLY=1 ;;
    c ) SCHEDULER=$OPTARG ;;
    i ) PROJECT_TIMEOUT=$OPTARG ;;
    s ) SIMULATE=1 ;;
    h ) usage; exit ;;
    v ) verbose ;;
    f ) SKIP_VIDEO_RESULTS=1 ;;
    n ) RESULTS_RUN_ID=$OPTARG ;;
    x ) TESTDROID_SSA_CLIENT_TIMEOUT=$OPTARG ;;
    q ) AUTO_RETRY_COUNT=$OPTARG ;;
    b ) FRAMEWORK_ID=$OPTARG ;; # change the character to whatever suits you best
    o ) OS_TYPE=$OPTARG ;;
    \? ) echo "Unknown option -$OPTARG" >&2 ; exit 1;;
    : ) echo "Missing required argument for -$OPTARG" >&2 ; exit 1;;
  esac
done

# Check args
if [ -z "${TD_USER}" ]; then echo "Please specify username!" ; usage ; exit 1 ; fi
if [ -z "${PROJECT_NAME}" ]; then echo "Please specify testdroid project name!" ; usage ; exit 1 ; fi
if [ -z "${FRAMEWORK_ID}" ]; then echo "Please specify framework id!" ; usage ; exit 1 ; fi
if [ -z "${OS_TYPE}" ]; then echo "Please specify Os type!" ; usage ; exit 1 ; fi

if [ "${LIST_DEVICES_AND_FRAMEWORKS_ONLY}" == "1" ]; then
  # Check that we have jq installed, listing devices requires jq
  which jq
  if [ $? -ne 0 ]; then echo "Please install 'jq' before running script." ; usage ; exit 101; fi
  list_device_groups_and_frameworks ; exit 0 ;
fi

if [ -n "${RESULTS_RUN_ID}" ]; then
  get_result_files "$RESULTS_RUN_ID"
  exit
fi

if [[ ! "$TESTDROID_SSA_CLIENT_TIMEOUT" =~ ^[0-9]+$ ]]; then
    echo 'Testdroid client timeout must be an integer!' ; exit 1 ; fi

if [[ ! -z "$AUTO_RETRY_COUNT" && ! "$AUTO_RETRY_COUNT" =~ ^[0-9]+$ ]]; then
    echo 'Auto retry count must be an integer!' ; exit 1 ; fi

if [ -z "${APP_PATH}" ]; then echo "Please specify app path!" ; usage ; exit 1 ; fi
if [ -z "${TEST_ARCHIVE_FOLDER}" ]; then echo "Please specify the folder containing the tests!" ; usage ; exit 1 ; fi

# Check that test_application is given as parameter
if [ -z "$APP_PATH" ]; then
  echo "Please specify the test_application as an argument"
  echo -e "$(usage)"
  exit 1
else
  orgdir=$(pwd)
  FULL_APP_PATH=$(get_full_path "${APP_PATH}")
  cd "$orgdir" || exit 33
  extension=${FULL_APP_PATH##*.}
  case "${extension}" in
    "apk" )
      PLATFORM="android" ;;
    "ipa" )
      PLATFORM="ios" ;;
    * )
      prettyp "Cannot handle unexpected platform with extension ${extension}"
      exit 12 ;;
  esac
  if [ ! -f "${FULL_APP_PATH}" ]; then
    echo "App file '${APP_PATH}' does not exist!"
    exit 2
  fi
fi

# Check that test folder exists and is a folder
if [ ! -d "${TEST_ARCHIVE_FOLDER}" ]; then
  echo "Test folder does not exist! Gave path '${TEST_ARCHIVE_FOLDER}'"
  exit 13
fi

# Check dependencies
which jq
if [ $? -ne 0 ]; then echo "Please install 'jq' before running script." ; usage ; exit 101; fi
which zip
if [ $? -ne 0 ]; then echo "Please install 'zip' before running script." ; usage ; exit 102; fi
which curl
if [ $? -ne 0 ]; then echo "Please install 'curl' before running script." ; usage ; exit 103; fi
which bc
if [ $? -ne 0 ]; then echo "Please install 'bc' before running script." ; usage ; exit 104; fi

# Create test.zip
mv ${TEST_ZIP_FILE} test_previous.zip 2>/dev/null
zip_temp_dir="testzip"
rm -rf "${zip_temp_dir:?}"
cp -rf "${TEST_ARCHIVE_FOLDER:?}" "${zip_temp_dir:?}"
for i in "${CLEANUP_FILES[@]}"; do
  rm -rf "${zip_temp_dir:?}/${i:?}"
done

cd $zip_temp_dir || exit 34

if [ ! -f "$generic_start_script" ]; then
  case "${PLATFORM}" in
    "android")
      cp "../$android_start_script" "$generic_start_script" ;;
    "ios")
      cp "../$ios_start_script" "$generic_start_script" ;;
    *) prettyp "Unknown platform '$PLATFORM'" ; exit 14 ;;
  esac
fi

zip ${TEST_ZIP_FILE} -r ./*
mv ${TEST_ZIP_FILE} ..
cd ..

FULL_TEST_PATH=$(get_full_path $TEST_ZIP_FILE)

# Get PROJECT_ID
get_project_id "$PROJECT_NAME"

APP_ID=$(upload_file_to_cloud "$FULL_APP_PATH")
TEST_ID=$(upload_file_to_cloud "$FULL_TEST_PATH")

if [ "$SIMULATE" -eq "1" ]; then
  prettyp "Simulated run, not actually starting test"
  release_project_configuration_lock
  exit 0
fi

# Start test run
test_run_id=$(start_test_run "$APP_ID" "$TEST_ID")
echo "test_run_id='$test_run_id'"

# Get the test run device runs
device_runs_url=$(url_from_template "${TD_TEST_DEVICE_SESSION_URL_TEMPLATE}" "${test_run_id}")
response=$(auth_curl "${device_runs_url}")
device_count=$(echo "$response" | jq '.total')
prettyp "Device count for test: ${device_count}"

# Get Test run status
prettyp "Test is running"
test_run_status_tmp_file="_test_run_status.json"
test_run_url=$(url_from_template "${TD_TEST_RUN_ITEM_URL_TEMPLATE}" "${test_run_id}")
test_run_browser_url=$(url_from_template "${TD_TEST_RUN_ITEM_BROWSER_URL_TEMPLATE}" "${test_run_id}")
prettyp "Results are to be found at ${test_run_browser_url}"
test_status=""
connection_failures=0
start_time=$(date +%s)
timeout_time="$(( start_time + TESTDROID_SSA_CLIENT_TIMEOUT ))"
while [ 1 -ne 2 ]; do
  sleep 5

  auth_curl "${test_run_url}" > "${test_run_status_tmp_file}"
  test_status_new=$(jq '.state' $test_run_status_tmp_file |xargs)
  if [ "${test_status}" != "${test_status_new}" ]; then
    test_status=$test_status_new
    echo ; prettyp "Test status changed: $test_status"
  fi

  if [ "$TESTDROID_SSA_CLIENT_TIMEOUT" == "0" ]; then
    : #pass
  elif [ "$timeout_time" -gt "$(date +%s)" ]; then
    : #pass
  elif [ "$( are_devices_running ${test_run_id} )" -ne "0" ]; then
    : #pass
  else
    echo ; prettyp "Run execution timeouted! (timeout was ${TESTDROID_SSA_CLIENT_TIMEOUT}s)"
    test_status="$( abort_run )"
  fi

  case "$(echo "$test_status" |xargs)" in
    "FINISHED" )

      echo ; prettyp "Test Finished! Getting test jUnit xml results"
      get_result_files "$test_run_id"

      failures=$(get_total_failures)

      if [[ $((failures)) > 0 ]]; then
        prettyp "Total test failures: $failures"
        exit 150
      fi

      exit 0 ;;
    "WAITING" | "RUNNING" )
      printf "." ;;
    "null" )
      ((connection_failures+=1))
      echo ; prettyp "Error, cannot read test status, connection problem? (fail [$connection_failures/$CONNECTION_FAILURES_LIMIT])"
      if [ "$connection_failures" -gt "$CONNECTION_FAILURES_LIMIT" ]; then
        exit 7
      fi ;;
    * )
      ((connection_failures+=1))
      prettyp "Error, unexpected status for test run. Status was=\"$test_status\" (fail [$connection_failures/$CONNECTION_FAILURES_LIMIT])"
      if [ "$connection_failures" -gt "$CONNECTION_FAILURES_LIMIT" ]; then
        exit 8
      fi ;;
  esac
done
