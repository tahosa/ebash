#!/bin/bash
# 
# Copyright 2012-2014, SolidFire, Inc. All rights reserved.
#

#-----------------------------------------------------------------------------
# PULL IN DEPENDENT PACKAGES
#-----------------------------------------------------------------------------
source "${BASHUTILS}/efuncs.sh"   || { echo "Failed to find efuncs.sh" ; exit 1; }

#
# Echo the URL to use to connect to a specified JENKINS instance. If JENKINS_URL
# has already been defined it will use this. Otherwise it will expect JENKINS
# and JENKINS_PORT to be defined.
#
jenkins_url()
{
    argcheck JENKINS JENKINS_PORT
    echo -n "http://${JENKINS}:${JENKINS_PORT}"
}

jenkins()
{
    if [[ -z ${JENKINS_CLI_JAR} || ! -r ${JENKINS_CLI_JAR} ]] ; then
        local tempDir=$(mktemp -d /tmp/jenkins.sh.tmp-XXXXXXXX)
        efetch "$(jenkins_url)/jnlpJars/jenkins-cli.jar" "${tempDir}" 2> $(edebug_out)
        export JENKINS_CLI_JAR="${tempDir}/jenkins-cli.jar"
        edebug "Downloaded jenkins-cli.jar: $(ls -l ${JENKINS_CLI_JAR})"
        trap_add "edebug \"Deleting ${JENKINS_CLI_JAR}.\" ; rm -rf \"${tempDir}\"" EXIT HUP INT QUIT BUS PIPE
    fi

    local cmd=("${@}")
    edebug "Sending jenkins command $(lval cmd JENKINS_CLI_JAR)"
    EFUNCS_FATAL=0 RETRIES=${JENKINS_RETRIES:-20} TIMEOUT=${JENKINS_TIMEOUT:-5s} WARN_EVERY=${JENKINS_WARN_EVERY:-5} eretry \
        java -jar "${JENKINS_CLI_JAR}" -s $(jenkins_url) \
        "${@}"
}

#
# Creates an item of the specified type on jenkins, or updates it if it exists
# and is different than what you would create.
#
# item_type:
#    node, view, or job
#
# template:
#    The filename (basename with extension only) of one of the templates stored
#    in scripts/jenkins_templates.
#
# You must also specify any parameters needed by that template as environment
# variables.  Look in the individual template files to determine what
# parameters are needed.
#
jenkins_update()
{
    local item_type=${1}
    local template=${2}
    local name=${3}
    argcheck item_type template name

    # Old versions of jenkins_update expected the template name to contain
    # .xml.  Drop the .xml if old clients provide it.
    template=${template%%.xml}

    [[ -d "scripts" ]] || die "jenkins_update must be run from repository root directory."
    [[ -d "scripts/jenkins_templates/${item_type}" ]] || die "jenkins_update cannot create ${item_type} items."

    local xmlTemplate="scripts/jenkins_templates/${item_type}/${template}.xml"
    [[ -r "${xmlTemplate}" ]] || die "No ${item_type} template named ${template} found."

    # Look for the optional script template
    local scriptFile scriptTemplate
    scriptTemplate="scripts/jenkins_templates/${item_type}/${template}.sh"

    [[ -r "${scriptTemplate}" ]] || scriptTemplate=""
    [[ -n ${scriptTemplate} ]] && scriptFile=$(mktemp "/tmp/jenkins_update_${item_type}_${template}_script_XXXX")
    local newConfig=$(mktemp "/tmp/jenkins_update_${item_type}_${template}_XXXX")
    local oldConfig=$(mktemp "/tmp/jenkins_update_${item_type}_${template}_old_XXXX")
    trap_add "erm ${scriptFile} ${newConfig} ${oldConfig}" EXIT

    # Expand parameters in the script (if one was found), and place its
    # contents into a variable so that it can be plunked into the XML file
    if [[ -n ${scriptTemplate} ]] ; then
        ecp "${scriptTemplate}" "${scriptFile}"
        setvars "${scriptFile}"
        export JENKINS_UPDATE_SCRIPT=$(cat "${scriptFile}")
    fi

    ecp "${xmlTemplate}" "${newConfig}"
    setvars "${newConfig}" setvars_escape_xml

    # Look to see if the item already exists on jenkins, with minimal retries
    # so we don't have to wait forever for new jobs
    local out=/dev/null ; edebug_enabled && out=/dev/stderr
    JENKINS_RETRIES=2 jenkins get-${item_type} "${name}" > "${oldConfig}" 2>${out}
    local foundExisting=$?

    local rc=0
    # If the request timed out OR if it timed out and then didn't respond to
    # requests so it got kill -9ed
    if [[ ${foundExisting} -eq 124 || ${foundExisting} -eq 137 ]] ; then
        die "Jenkins is not responding to API requests."

    # Other error codes would be from jenkins
    elif [[ ${foundExisting} -eq 0 ]] ; then

        # If it does, only update it if the new config differs from the old one
        diff --ignore-all-space --brief "${oldConfig}" "${newConfig}" &>/dev/null
        if [[ $? -ne 0 ]] ; then
            jenkins update-${item_type} "${name}" < "${newConfig}"
            rc=$?
        else
            edebug "jenkins_update: config matches.  No update required."
            rc=0
        fi

    else

        # If it does not, create it
        jenkins create-${item_type} "${name}" < "${newConfig}"
        rc=$?
    fi

    if [[ ${rc} -eq 0 ]] ; then
        edebug "Done updating $(lval item_type template name rc)"
    else
        ewarn "Error updating $(lval item_type template name rc foundExisting))"
        edebug_enabled && cat "${newConfig}"
    fi
    return ${rc}
}

# This is a setvars callback method that properly escapes raw data so that it
# can be inserted into an xml file
setvars_escape_xml()
{
    $(declare_args _ ?val)
    echo "${val}" | xmlstarlet esc
}

#
# Start a build on jenkins.
#
#     JENKINS: Jenkins server hostname or IP.
#     JENKINS_JOB: Name of a job on that jenkins.
#     BUILD_ARGS: Associative array containing names and values of the parameters that your jenkins job requires.
#
# This function echos the URL returned by jenkins, which points to the queue entry created for your job.  You might want
# to pass this as QUEUE_URL to jenkins_get_build_number.
#
# If unable to start the job, this function produces no output on stdout.
#
jenkins_start_build()
{
    argcheck JENKINS JENKINS_JOB

    # Skip jenkins' "quiet period"
    local args="-d delay=0sec "

    for arg in ${!BUILD_ARGS[@]} ; do
        args+="-d ${arg}=${BUILD_ARGS[$arg]} "
    done

    local url="$(jenkins_url)/job/${JENKINS_JOB}/buildWithParameters"

    local rc
    local queueUrl

    queueUrl=$(curl --silent --data-urlencode -H ${args} ${url} --include | awk '$1 == "Location:" {print $2}' | tr -d '\r' )
    rc=$?
    
    [[ ${rc} == 0 ]] && echo "${queueUrl}api/json"
}

#
# Given the JSON api URL for an item in the jenkins queue, this function will echo the build number for that item if it
# has started.  If it has not started yet, this function will produce no output.
#
#     QUEUE_URL: The URL of your build of interest in the queue.  (What was returned when you called
#                jenkins_start_build)
#
jenkins_get_build_number()
{
    argcheck 1
    local queueUrl=${1}

    local number rc

    number=$(curl --silent ${queueUrl} | jq -M ".executable.number")
    rc=$?

    [[ ${rc} == 0 && ${number} != "null" ]] && echo "${number}"
}

#
# Get the URL that provides information about a particular jenkins build.
#   JENKINS_JOB:   must be set to the name of your jenkins job (e.g. dtest_modell)
#   $1:            the build number within that job
#   $2 (optional): json or xml if you'd like the URL for data in that format
#
jenkins_build_url()
{
    argcheck JENKINS_JOB 1
    local buildNum=${1}

    echo -n "$(jenkins_url)/job/${JENKINS_JOB}/${buildNum}/"
    [[ $2 == "json" ]] && echo -n "api/json"
    [[ $2 == "xml" ]] && echo -n "api/xml"
    echo ""
}


#
# Retrieve the json data for a particular build, given its job and build number.
#    JENKINS_JOB:   should be set to the name of your jenkins job (e.g. dtest_modell)
#    $1:            the build number within that job (e.g. 12048)
#    $2 (optional): value of the jenkins tree parameter which can limit the json data returned from the server.
#
# See <jenkins>/api's information under "Controlling the amount of data you fetch" for how to use the tree
# parameter.  Basically, it allows you to select smaller portions of the tree of json data that jenkins would
# typically return.  For example, to get just the results field and the duration, you would use a tree value
# of
#     result,duration
# or to get all of the parameters you might say
#     actions.parameters
# 
# Sure, you can do this stuff with jq.  But this requires the jenkins server to collect and send back less data.
#
jenkins_build_json()
{
    argcheck JENKINS_JOB 1
    local buildNum=${1}
    local tree=${2}

    local url treeparm json rc

    url=$(jenkins_build_url ${buildNum} json)
    [[ -n ${tree} ]] && treeparm="-d tree=$tree"

    json=$(curl --silent ${treeparm} ${url})
    rc=$?
    
    [[ $rc -ne 0 ]] && { edebug "Error reading json on build for ${JENKINS_JOB} #${BUILD_NUMBER}" ; return 1 ; }
    [[ $rc -eq 0 ]] && echo "${json}"
}


#
# Writes one of the jenkins build status words to stdout once that status is
# known.  Note that this does NOT necessarily mean that the test is completed.
# Once a build status is known to jenkins, it can be retrieved here.
#
# The set of possible return values is determined by jenkins as these values
# come directly from it.  Here are the ones I have seen:
#
#   ABORTED
#   FAILURE
#   SUCCESS
#
jenkins_build_result()
{
    argcheck JENKINS_JOB 1
    local buildNum=${1}

    local json status rc

    json=$(jenkins_build_json ${buildNum} result)
    rc=$?

    status=$(echo "${json}" | jq --raw-output .result)

    [[ ${rc} == 0 && ${status} != "null" ]] && echo "${status}"
}

#
# Returns success if the specified build is still actively being processed by
# jenkins.  This is different than whether it was successful, or even it has
# been declared as aborted or failed.  Even in those states, it may still spend
# a while processing artifacts.
#
# Once this returns false, all processing is complete
#
jenkins_build_is_running()
{
    local buildNum=$1
    argcheck JENKINS_JOB buildNum

    local result rc
    result=$(jenkins_build_json ${buildNum} building | jq --raw-output '.building') # 2>/dev/null)
    [[ $? -eq 0 && ${result} == "true" ]] && return 0
    return 1
}

#
# Retrieves a list of artifacts associated with a particular jenkins build.
#
jenkins_list_artifacts()
{
    local buildNum=$1
    argcheck buildNum JENKINS_JOB

    local json rc url
    json=$(jenkins_build_json ${buildNum} 'artifacts[relativePath]')
    rc=$?

    url=$(jenkins_build_url ${buildNum})

    # Assuming we successfully got json data, pass it through jq to just get
    # the "relativePath" items out of it, and then prepend the jenkins build
    # url + artifacts directory onto it.
    [[ ${rc} -eq 0 ]] && \
        echo ${json} \
        | jq --raw-output '.artifacts[].relativePath'

    return ${rc}
}

jenkins_get_artifact()
{
    local buildNum=$1
    local artifact=$2
    argcheck JENKINS_JOB buildNum artifact

    curl --silent "$(jenkins_build_url ${buildNum})artifact/${artifact}"
}

jenkins_get_queue_size()
{
    local job=${1}

    if [[ -z $job ]] ; then
        echo "usage: $FUNCNAME <jenkins job name>"
        return 1
    fi

    curl --silent $(jenkins_url)/queue/api/json \
        | jq '.items[].task.name' \
        | wc -l
}

#
# Cancel queued builds whose DTEST_TITLE is equal to the one specified
#
jenkins_cancel_queue_jobs()
{
    local DTEST_TITLE=${1}

    if [[ -z $DTEST_TITLE ]] ; then
        echo "usage: $FUNCNAME <test bundle absolute filename>"
        return 1
    fi

    # NOTE: I'm ignoring a jq error here -- the select I'm using ignores the
    # fact that not all items in the .actions array have .parameters[] in them.
    # But I only care about the ones that do and I can't figure out how to
    # nicely tell jq to skip them.
    local ids=$(curl --silent $(jenkins_url)/queue/api/json \
                    | jq '.items[] | select( .actions[].parameters[].value == "'$1'" and .actions[].parameters[].name == "DTEST_TITLE")' 2> $(edebug_out) \
                    | jq .id \
                    | sed 's/"//g')

    edebug "Killing jenkins queued items $(lval ids)"
    for id in $ids ; do
        curl --data "id=${id}" $(jenkins_url)/queue/cancelItem
    done
}

jenkins_stop_build()
{
    local buildNum=${1}
    local job=${2:-${JENKINS_JOB}}

    argcheck buildNum job
    edebug "Stopping jenkins build ${job}/${buildNum} on ${JENKINS}."
    curl -X POST --silent "$(jenkins_url)/job/${job}/${buildNum}/stop"
}

#
# Stop a build given its default URL (e.g. http://bdr-distbox:8080/job/dtest_modell/3)
#
# NOTE: The job will be marked as "ABORTED" as soon as the POST is complete,
# but it may not be finished "building" yet, because jenkins still collects
# artifacts for aborted jobs.
#
jenkins_stop_build_by_url()
{
    local buildUrl=$1
    argcheck buildUrl

    edebug $(lval buildUrl)
    curl -X POST --silent "${buildUrl}/stop"
}

#
# Cancel _running_ builds whose DTEST_TITLE is equal to the one specified
#
jenkins_cancel_running_jobs()
{
    local DTEST_TITLE=${1}
    local JENKINS_JOB=${2:-${JENKINS_JOB}}

    argcheck DTEST_TITLE JENKINS_JOB

    curl --silent $(jenkins_url)/job/${JENKINS_JOB}/api/json

}


################################################################################
# Print out information about available slaves in tab-separated format.  The
# fields on each line are:
#
#    1: Jenkins slave name (e.g. distbox_odell-dev)
#    2: Hostname or IP where that slave can be reached
#    3: Port of available SSH service on that host
#    4: true = the slave is online, false = the slave is offline
#    5: Space-separated list of labels that jenkins has associated with that
#       slave.
#
jenkins_list_slaves()
{
    # Note: the = parameter to jenkins groovy causes it to use stdin as its script.
    jenkins groovy = <<-ENDGROOVY
	for (slave in jenkins.model.Jenkins.instance.slaves) {
		println (slave.name + "," 
					+ slave.launcher.host + ","
					+ slave.launcher.port + ","
					+ slave.computer.isOnline() + ","
					+ slave.getLabelString())
    }
	ENDGROOVY
}

#
# Writes the current status of the slave on jenkins (either online or offline) to stdout.
#
#    JENKINS_URL: http url to the root of jenkins (e.g. http://bdr-jenkins.eng.solidfire.net:8080)
#    JENKINS_SLAVE_NAME: The name of the slave you're interested in, according
#                        to jenkins (e.g. distbox_caprica)
#
jenkins_slave_status()
{
    argcheck JENKINS_SLAVE_NAME JENKINS_URL

    local offline rc
    offline=$(curl --silent -d tree=offline ${JENKINS_URL}/computer/${JENKINS_SLAVE_NAME}/api/json \
                 | jq --raw-output .offline 2> /dev/null)
    rc=$?

    # Assume offline if we were unable to get the slave's status
    [[ $rc -ne 0 ]] && { echo offline ; return 0 ; }
    [[ ${offline} == "false" ]] && echo online || echo offline
}

ssh_jenkins()
{
    argcheck JENKINS_PASSWORD
    argcheck JENKINS_USER
    argcheck JENKINS

    # Hide the "host key permanently added" warnings unless EDEBUG is set
    local hideWarnings
    edebug_enabled && hideWarnings="-o LogLevel=quiet"

    sshpass -p ${JENKINS_PASSWORD} \
        ssh -o PreferredAuthentications=password \
            -o UserKnownHostsFile=/dev/null \
            -o StrictHostKeyChecking=no \
            -x \
            ${hideWarnings} \
            ${JENKINS_USER}@${JENKINS} \
            "${@}"
}

################################################################################
# Files stored on jenkins via jenkins_put_file do not use a standard jenkins
# service.  Rather, at SolidFire we add a web service on the same machine _AT A
# DIFFERENT PORT_ that hosts files in /tmp, and then we can copy the files to
# that location via ssh.
#
# This function returns the url of a file stored in this way.
#
jenkins_file_url()
{
    local file=$1
    argcheck file JENKINS

    echo "http://${JENKINS}/tmp/${file}"
}


################################################################################
# Takes a specified file (or - for stdin) and writes it to jenkins where it may
# be retrieved by other processes.
#
#    $1   Name of the local file
#    $2   (optional) target filename on jenkins
#
jenkins_put_file()
{
    local file=$1
    argcheck file JENKINS
    outputFile=${2:-$(basename $file)}

    cat $file | ssh_jenkins 'cat > /tmp/'${outputFile}
}



################################################################################
# Retrieves a file from jenkins that was placed there via jenkins_put_file, and
# places it on stdin.
#
#     $1    Name of the file on jenkins
#
jenkins_read_file()
{
    local file=$1
    argcheck file

    curl --silent $(jenkins_file_url ${file})
}

################################################################################
# Retrieves a file from jenkins that was placed there with jenkins_put_file.
#
#    $1     Name of the file on jenkins
#    $2     (optional) target output file.
#
jenkins_get_file()
{
    local file=$1
    argcheck file
    local outputFile=${2:-$(basename $file)}

    jenkins_read_file ${file} > ${outputFile} 
}

################################################################################
# Delete any number of files from jenkins that were placed there via
# jenkins_put_file
#
#    ${@}    File name on jenkins
#
jenkins_delete_files()
{
    local allFiles=()
    for file in ${@} ; do
        allFiles+=("/tmp/${file}")
    done

    [[ ${#allFiles[@]} -gt 0 ]] && ssh_jenkins "rm -f ${allFiles[@]}"
}

return 0