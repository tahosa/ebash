#!/bin/bash
#
# Copyright 2011-2015, SolidFire, Inc. All rights reserved.
#

#-----------------------------------------------------------------------------
# GLOBAL EFUNCS SETTINGS
#-----------------------------------------------------------------------------
set -o pipefail
set -o nounset
set -o functrace
set -o errtrace
shopt -s expand_aliases
shopt -s checkwinsize
shopt -s extglob

if [[ "${__BU_OS}" == Linux ]] ; then
    export LC_ALL="en_US.utf8"
    export LANG="en_US.utf8"
elif [[ "${__BU_OS}" == Darwin ]] ; then
    export LC_ALL="en_US.UTF-8"
    export LANG="en_US.UTF-8"
fi

#------------------------------------------------------------------------------
# LOGGING SETTINGS
#------------------------------------------------------------------------------

: ${EMSG_PREFIX:=}
: ${EMSG_COLOR:=all}

: ${COLOR_INFO:="bold green"}
: ${COLOR_DEBUG:="blue"}
: ${COLOR_TRACE:="yellow"}
: ${COLOR_WARN:="bold yellow"}
: ${COLOR_ERROR:="bold red"}
: ${COLOR_BRACKET:="bold blue"}
: ${COLOR_BANNER:="bold magenta"}

# Any functions whose names are "==" to this are exempt from ETRACE.  In other
# words, even if ETRACE=1, these functions actions will not be displayed in the
# output.
#
# By default, these are excluded:
#   - Any parts of opt_parse (plus string_trim because opt_parse uses it)
#   - Emsg and other message producing internals (but not the message
#     functions like edebug, einfo)
#   - Internals of die and stack generation (but leaving some parts of die
#     so it's more clear what is happening.)
#   - Signame, which does translations amongst signal names in various styles
#     and signal numbers.
: ${ETRACE_BLACKLIST:=@(opt_parse|opt_parse_setup|opt_parse_options|opt_parse_arguments|opt_parse_find_canonical|argcheck|ecolor|ecolor_internal|ecolor_code|einteractive|emsg|string_trim|print_value|lval|disable_signals|reenable_signals|eerror_internal|eerror_stacktrace|stacktrace|stacktrace_array|signame|array_size|array_empty|array_not_empty)}

#-----------------------------------------------------------------------------
# DEBUGGING
#-----------------------------------------------------------------------------

if [[ ${__BU_OS} == Linux ]] ; then
    BU_WORD_BEGIN='\<'
    BU_WORD_END='\>'
elif [[ ${__BU_OS} == Darwin ]] ; then
    BU_WORD_BEGIN='[[:<:]]'
    BU_WORD_END='[[:>:]]'
fi

alias enable_trace='[[ -n ${ETRACE:-} && ${ETRACE:-} != "0" ]] && trap etrace DEBUG || trap - DEBUG'

etrace()
{
    # This function returns as soon as it can decide that tracing should not
    # happen.  If it makes its way to the end, then it finally does the tracing
    # it must do.

    # Is tracing globally off?
    [[ ${ETRACE} == "" || ${ETRACE} == "0" ]] && return 0 || true


    # Is tracing enabled, but not globally (i.e. now we check function and
    # filenames)
    if [[ ${ETRACE} != "1" ]]; then

        local should_be_enabled=0

        local word
        for word in ${ETRACE}; do
            [[ ${BASH_SOURCE[1]:-} == *"${word}"*
                || ${FUNCNAME[1]:-} == *"${word}"* ]] && { should_be_enabled=1; break; }
        done

        [[ ${should_be_enabled} -eq 1 ]] || return 0
    fi


    # Whether we got here because ETRACE=1 or because a function was
    # specifically chosen, we still leave out blacklisted functions
    if [[ ${FUNCNAME[1]} == ${ETRACE_BLACKLIST} ]] ; then
        return 0
    fi

    {
        ecolor ${COLOR_TRACE}
        echo -n "[${BASH_SOURCE[1]##*/}:${BASH_LINENO[0]:-}:${FUNCNAME[1]:-}:${BASHPID}]"
        ecolor none
        echo "${BASH_COMMAND}"
    } >&2
}

edebug_enabled()
{
    [[ -n ${1:-} ]] && die "edebug_enabled does not support arguments."

    [[ ${EDEBUG:=}  == "1" || ${ETRACE:=}  == "1" ]] && return 0
    [[ ${EDEBUG:-0} == "0" && ${ETRACE:-0} == "0" ]] && return 1

    # Walk up the stack and pick the first function that isn't in our list of
    # function names skipped
    local index=1
    local caller=${FUNCNAME[$index]}
    local filename=${BASH_SOURCE[$index]}
    if [[ ${caller} == @(edebug|edebug_out|tryrc) ]] ; then
        (( index += 1 ))
        caller=${FUNCNAME[$index]}
        filename=${BASH_SOURCE[$index]}
    fi

    # If the edebug or etrace strings contain a word that matches the name of
    # the function or filename, then edebug is on.
    local word
    for word in ${EDEBUG:-} ${ETRACE:-} ; do
        [[ "${caller}"   == *"${word}"* ]] && return 0
        [[ "${filename}" == *"${word}"* ]] && return 0
    done

    # Otherwise, it's not.
    return 1
}

edebug_disabled()
{
    ! edebug_enabled
}

edebug()
{
    # Take input either from arguments or if no arguments were provided take input from
    # standard input.
    local msg=""
    if [[ $# -gt 0 ]]; then
        msg="${@}"
    else
        msg="$(cat)"
    fi
    
    # If debugging isn't enabled then simply return without writing anything.
    # NOTE: We can't return at the top of this function in the event the caller has
    # piped output into edebug. We have to consume their output so that they don't
    # get an error or block.
    edebug_enabled || return 0

    # Force caller to be in edebug output because it's helpful and if you
    # turned on edebug, you probably want to know anyway
    EMSG_PREFIX="${EMSG_PREFIX:-} caller" emsg "${COLOR_DEBUG}" "" "DEBUG" "${msg}"
}

edebug_out()
{
    edebug_enabled && echo -n "/dev/stderr" || echo -n "/dev/null"
}

#-----------------------------------------------------------------------------
# TRY / CATCH
#-----------------------------------------------------------------------------

DIE_MSG_KILLED='[Killed]'
DIE_MSG_CAUGHT='[ExceptionCaught pid=$BASHPID cmd=$(string_truncate -e 60 ${BASH_COMMAND})]'
DIE_MSG_UNHERR='[UnhandledError pid=$BASHPID cmd=$(string_truncate -e 60 ${BASH_COMMAND})]'


# The below aliases allow us to support rich error handling through the use
# of the try/catch idom typically found in higher level languages. Essentially
# the 'try' alias creates a subshell and then turns on implicit error handling
# through "die_on_error" (which essentially just enables 'set -e'). Since this
# runs in a subshell with fatal error handling enabled, the subshell will
# immediately exit on failure. The catch block which immediately follows the
# try block captures the exit status of the subshell and if it's not '0' it
# will invoke the catch block to handle the error.
#
# One clever trick employed here is to keep track of what level of the try/catch
# stack we are in so that the parent's ERR trap won't get triggered and cause
# the process to exit. Because we WANT the try subshell to exit and allow the
# failure to be handled inside the catch block.
__BU_DIE_ON_ERROR_TRAP_STACK=()
alias try="
    __BU_DIE_ON_ERROR_TRAP=\"\$(trap -p ERR | sed -e 's|trap -- ||' -e 's| ERR||' -e \"s|^'||\" -e \"s|'$||\" || true)\"
    : \${__BU_DIE_ON_ERROR_TRAP:=-}
    __BU_DIE_ON_ERROR_TRAP_STACK+=( \"\${__BU_DIE_ON_ERROR_TRAP}\" )
    nodie_on_error
    (
        __BU_INSIDE_TRY=1
        declare __BU_DISABLE_DIE_PARENT_PID=\${BASHPID}
        enable_trace
        die_on_abort
        trap 'die -r=\$? ${DIE_MSG_CAUGHT}' ERR
    "


# Catch block attached to a preceeding try block. This is a rather complex
# alias and it's probably not readily obvious why it jumps through the hoops
# it is jumping through but trust me they are all important. A few important
# notes about this alias:
#
# (1) Note that the ");" ends the preceeding subshell created by the "try"
#     block. Which means that a try block on it's own will be invalid syntax
#     to try to force try/catch to always be used properly.
#
# (2) All of the "|| true" stuff in this alias is extremely important. Without
#     it the implicit error handling will kick in and the process will be
#     terminated immediately instead of allowing the catch() block to handle
#     the error.
#
# (3) It's often really convenient for the catch block to know what the error
#     code was inside the try block. But that's actually kinda of hard to get
#     right. So here we capture the error code, and then we employ a curious
#     "( exit $rc; ) ||" to create a NEW subshell which exits with the original
#     try block's status. If it was 0 this will do nothing. Otherwise it will
#     call the catch block handling code. If we didn't care about the nesting
#     levels this wouldn't be necessary and we could just simplify the catch
#     alias to "); ||". But knowing the nesting level is really important.
#
# (4) The dangling "||" here requries the caller to put something after the
#     catch block which sufficiently handles the error or the code won't be
#     valid.
alias catch=" );
    __BU_TRY_CATCH_RC=\$?
    __BU_DIE_ON_ERROR_TRAP=\"\${__BU_DIE_ON_ERROR_TRAP_STACK[@]:(-1)}\"
    unset __BU_DIE_ON_ERROR_TRAP_STACK[\${#__BU_DIE_ON_ERROR_TRAP_STACK[@]}-1]
    trap \"\${__BU_DIE_ON_ERROR_TRAP}\" ERR
    ( exit \${__BU_TRY_CATCH_RC} ) || "

# Throw is just a simple wrapper around exit but it looks a little nicer inside
# a 'try' block to see 'throw' instead of 'exit'.
throw()
{
    exit $1
}

# Returns true (0) if the current code is executing inside a try/catch block
# and false otherwise.
#
inside_try()
{
    [[ ${__BU_INSIDE_TRY:-0} -eq 1 ]]
}

# die_on_error registers a trap handler for ERR. It is extremely important that
# we use this mechanism instead of the expected 'set -e' so that we have
# control over how the process exit is handled by calling our own internal
# 'die' handler. This allows us to either exit or kill the entire process tree
# as needed.
#
# NOTE: This is extremely unobvious, but setting a trap on ERR implicitly
# enables 'set -e'.
die_on_error()
{
    trap "die ${DIE_MSG_UNHERR}" ERR
}

# disable the bashutils ERR trap handler.  Calling this is akin to calling 'set
# +e'.  Bashutils will no longer detect errors for you in this shell.
#
nodie_on_error()
{
    trap - ERR
}

# Prevent an error or other die call in the _current_ shell from killing its
# parent.  By default with bashutils, errors propagate to the parent by sending
# the parent a sigterm.
#
# You might want to use this in shells that you put in the background if you
# don't want an error in them to cause you to be notified via sigterm.
#
alias disable_die_parent="declare __BU_DISABLE_DIE_PARENT_PID=\${BASHPID}"

# Convert stream names (e.g. 'stdout') to cannonical file descriptor numbers:
#
# stdin=0
# stdout=1
# stderr=2
#
# Any other names will result in an error.
get_stream_fd()
{
    case "$1" in
        stdin ) echo "0"; return 0 ;;
        stdout) echo "1"; return 0 ;;
        stderr) echo "2"; return 0 ;;

        *) die "Unsupported stream=$1"
    esac
}

# Close file descriptors that are currently open.  This can be important
# because child processes inherit all of their parent's file descriptors, but
# frequently don't need access to them.  Sometimes the fact that those
# descriptors are still open can even cause problems (e.g. if a FIFO has more
# writers than expected, its reader may not get the EOF it is expecting.)
#
# This function closes all open file descriptors EXCEPT stdin (0),
# stdout (1), and stderr (2).  Technically, you can close those on your own if
# you want via syntax like this:
#    exec 0>&- 1>&- 2>&-
#
# But practically speaking, it's likely to cause problems.  For instance, hangs
# or errors when something tries to write to or read from one of those.  It's a
# better idea to do this intead if you really don't want your
# stdin/stdout/stderr inherited:
#
#   exec 0</dev/null 1>/dev/null 2>/dev/null
#
# We also never close fd 255.  Bash considers that its own.  For instance,
# sometimes that's open to the script you're currently executing.
#
close_fds()
{
    # Note grab file descriptors for the current process, not the one inside
    # the command substitution ls here.
    local pid=$BASHPID
    local fds=( $(ls $(fd_path)/ | grep -vP '^(0|1|2|255)$' | tr '\n' ' ') )

    array_empty fds && return 0

    local fd
    for fd in "${fds[@]}"; do
        eval "exec $fd>&-"
    done
}

fd_path()
{
    if [[ ${__BU_OS} == Linux ]] ; then
        echo /proc/self/fd

    elif [[ ${__BU_OS} == Darwin ]] ; then
        echo /dev/fd

    else
        die "Unsupported OS $(lval __BU_OS)"
    fi
}

# Helper method to read from a pipe until we see EOF.
pipe_read()
{
    $(opt_parse "pipe")
    local line
    
    # Read returns an error when it reaches EOF. But we still want to emit that
    # last line. So if we failed to read due to EOF but saw a partial line we
    # still want to echo it.
    #
    # NOTE: IFS='' and "-r" flag are critical here to ensure we don't lose
    # whitespace or try to interpret anything.
    while IFS= read -r line || [[ -n "${line}" ]]; do
        echo "${line}"
    done <${pipe}
}

# Helper method to read from a pipe until we see EOF and then also 
# intelligently quote the output in a way that can be reused as shell input
# via "printf %q". This will allow us to safely eval the input without fear
# of anything being exectued.
#
# NOTE: This method will echo "" instead of using printf if the output is an
#       empty string to avoid causing various test failures where we'd
#       expect an empty string ("") instead of a string with literl quotes
#       in it ("''").
pipe_read_quote()
{
    $(opt_parse "pipe")
    local output=$(pipe_read ${pipe})
    if [[ -n ${output} ]]; then
        printf %q "$(printf "%q" "${output}")"
    else
        echo -n ""
    fi
}

# tryrc is a convenience wrapper around try/catch that makes it really easy to
# execute a given command and capture the command's return code, stdout and stderr
# into local variables. We created this idiom because if you handle the failure 
# of a command in any way then bash effectively disables set -e that command
# invocation REGARDLESS OF DEPTH. "Handling the failure" includes putting it in
# a while or until loop, part of an if/else statement or part of a command 
# executed in a && or ||.
#
# Consider a function call chain such as:
#
# foo->bar->zap
#
# and you want to get the return value from foo, you might (wrongly) think you
# could safely use this and safely bypass set -e explosion:
#
# foo || rc=$?
#
# The problem is bash effectively disables "set -e" for this command when used
# in this context. That means even if zap encounteres an unhandled error die()
# will NOT get implicitly called (explicit calls to die would still get called
# of course).
# 
# Here's the insidious documentation from 'man bash' regarding this obscene
# behavior:
#
# "The ERR trap is not executed if the failed command is part of the command
#  list immediately following a while or until keyword, part of the test in
#  an if statement, part of a command executed in a && or ||  list  except 
#  the command following the final && or ||, any command in a pipeline but
#  the last, or if the command's return value is being inverted using !."
#
# What's not obvious from that statement is that this applies to the entire
# expression including any functions it may call not just the top-level 
# expression that had an error. Ick.
#
# Thus we created tryrc to allow safely capturing the return code, stdout
# and stderr of a function call WITHOUT bypassing set -e safety!
#
# This is invoked using the "eval command invocation string" idiom so that it
# is invoked in the caller's envionment. For example: $(tryrc some-command)
#
# OPTIONS:
# -r=VAR The variable to assign the return code to (OPTIONAL, defaults to 'rc').
# -o=VAR The variable to assign STDOUT to (OPTIONAL). If not provided STDOUT
#        will go to /dev/stdout as normal. This is BUFFERED and not displayed
#        until the call completes.
# -e=VAR The variable to assign STDERR to (OPTIONAL). If not provided STDERR
#        will go to /dev/stderr as normal. This is NOT BUFFERED and will display
#        to /dev/stderr in real-time.
# -g     Make variables global even if called in a local context.
tryrc()
{
    $(opt_parse \
        ":rc r=rc  | Variable to assign the return code to." \
        ":stdout o | Write stdout to the specified variable rather than letting it go to stdout." \
        ":stderr e | Write stderr to the specified variable rather than letting it go to stderr." \
        "+global g | Make variables created global rather than local")

    local cmd=("$@")

    # Determine flags to pass into declare
    local dflags=""
    [[ ${global} -eq 1 ]] && dflags="-g"

    # Temporary directory to hold stdout and stderr
    local tmpdir=$(mktemp --tmpdir --directory tryrc-XXXXXX)
    trap_add "rm --recursive --force ${tmpdir}"

    # Create temporary file for stdout and stderr
    local stdout_file="${tmpdir}/stdout" stderr_file="${tmpdir}/stderr"

    # We're creating an "eval command string" inside the command substitution
    # that the caller is supposed to wrap around tryrc.
    #
    # Command substitution really can only run one big command.  In other
    # words, everything after the first command inside it is passed as an
    # argument to the first command.  But you can separate multiple commands by
    # semicolons inside an eval, so we put an eval around the entire output of
    # tryrc.
    #
    # Later you'll see we also put eval around the inside commands.  We
    # basically quote everything twice and then make up for it by eval-ing
    # everything twice in order to convince everything to keep whitespace as it
    # is.
    echo eval

    # Need to first make sure we've emitted code to set our output variables in the
    # event we are interrupted
    echo eval "declare ${dflags} ${rc}=1;"
    [[ -n ${stdout} ]] && echo eval "declare ${dflags} ${stdout}="";"
    [[ -n ${stderr} ]] && echo eval "declare ${dflags} ${stderr}="";"

    # Execute actual command in try/catch so that any fatal errors in the command
    # properly terminate execution of the command then capture off the return code
    # in the catch block. Send all stdout and stderr to respective pipes which will
    # be read in by the above background processes.
    local actual_rc=0
    try
    {
        if [[ -n "${cmd[@]:-}" ]]; then

            # Redirect subshell's STDOUT and STDERR to requested locations
            exec >${stdout_file}
            [[ -n ${stderr} ]] && exec 2>${stderr_file}

            # Run command
            quote_eval "${cmd[@]}"
        fi
    }
    catch
    {
        actual_rc=$?
    }

    # Emit commands to assign return code 
    echo eval "declare ${dflags} ${rc}=${actual_rc};"

    # Emit commands to assign stdout but ONLY if a stdout file was actually created.
    # This is because the file is only created on first write. And we don't want this
    # to fail if the command didn't write any stdout. This is also SAFE because we
    # initialize stdout and stderr above to empty strings.
    if [[ -s ${stdout_file} ]]; then
        local actual_stdout="$(pipe_read_quote ${stdout_file})"
        if [[ -n ${stdout} ]]; then
            echo eval "declare ${dflags} ${stdout}=${actual_stdout};"
        else
            echo eval "echo ${actual_stdout} >&1;"
        fi
    fi

    # Emit commands to assign stderr
    if [[ -n ${stderr} && -s ${stderr_file} ]]; then
        local actual_stderr="$(pipe_read_quote ${stderr_file})"
        echo eval "declare ${dflags} ${stderr}=${actual_stderr};"
    fi

    # Remote temporary directory
    rm --recursive --force ${tmpdir}
}

#-----------------------------------------------------------------------------
# TRAPS / DIE / STACKTRACE
#-----------------------------------------------------------------------------

# Print stacktrace to stdout. Each frame of the stacktrace is separated by a
# newline. Allows you to optionally pass in a starting frame to start the
# stacktrace at. 0 is the top of the stack and counts up. See also stacktrace
# and error_stacktrace.
#
# OPTIONS:
# -f=N Frame number to start at.
stacktrace()
{
    $(opt_parse ":frame f=0 | Frame number to start at if not the current one")

    while caller ${frame}; do
        (( frame+=1 ))
    done
}

# Populate an array with the frames of the current stacktrace. Allows you
# to optionally pass in a starting frame to start the stacktrace at. 0 is
# the top of the stack and counts up. See also stacktrace and eerror_stacktrace
#
# OPTIONS:
# -f=N Frame number to start at (defaults to 1 to skip lower level stacktrace
#      frame that this function calls.)
stacktrace_array()
{
    $(opt_parse \
        ":frame f=1 | Frame number to start at" \
        "array")

    array_init_nl ${array} "$(stacktrace -f=${frame})"
}

# Print the trap command associated with a given signal (if any). This
# essentially parses trap -p in order to extract the command from that
# trap for use in other functions such as call_die_traps and trap_add.
trap_get()
{
    $(opt_parse "sig | Signal name to print traps for.")

    # Normalize the signal description (which might be a name or a number) into
    # the form trap produces
    sig="$(signame -s "${sig}")"

    local existing=$(trap -p "${sig}")
    existing=${existing##trap -- \'}
    existing=${existing%%\' ${sig}}

    echo -n "${existing}"
}

# Replace normal exit function with our own internal exit function so we can
# detect abnormal exit conditions through an EXIT trap which we setup to ensure
# die() is called on exit if it didn't go through our own internal exit mechanism.
# 
# The primary use case for this trickery is to detect and catch unset variables.
# With "set -u" turned on, bash immediately exits the program -- NOT by calling
# bash exit function but by calling the C exit(2) function. The problem is that 
# even though it exits, it does NOT call the ERR trap. Thus die() doesn't get 
# invoked even though there was a fatal error causing abnormal termination. We
# can catch this scenario by setting up an EXIT trap and invoking die() if exit
# was invoked outside of our internal exit function.
#
# The other advantage to this approach is that if someone calls exit directly
# inside bash code sourcing bashutils in order to gracefully exit they probably
# do NOT want to see a stacktrace and have die() get invoked. This mechanism
# will ensure that works properly b/c they will go through our internal exit
# function and that will bypass die().
#
exit()
{
    local exit_code=$?
    # Mark that this was an internal exit so that in our die mechanism we
    # won't call die if it already went through our internal exit function.
    __BU_INTERNAL_EXIT=1
    builtin exit ${1:-${exit_code}}
}

# die is our central error handling function for all bashutils code which is
# called on any unhandled error or via the ERR trap. It is responsible for
# printing a stacktrace to STDERR indicating the source of the fatal error
# and then killing our process tree and finally signalling our parent process
# that we died via SIGTERM. With this careful setup, we do not need to do any
# error checking in our bash scripts. Instead we rely on the ERR trap getting
# invoked for any unhandled error which will call die(). At that point we 
# take extra care to ensure that process and all its children exit with error.
die()
{
    # Capture off our BASHPID into a local variable so we can use it in subsequent
    # commands which cannot use BASHPID directly because they are in subshells and
    # the value of BASHPID would be altered by their context. 
    # WARNING: Do NOT use PPID instead of the $(ps) command because PPID is the
    #          parent of $$ not necessarily the parent of ${BASHPID}!
    local pid=${BASHPID}
    local parent=$(process_parent ${pid})

    # Disable traps for any signal during most of die.  We'll reset the traps
    # to existing state prior to exiting so that the exit trap will honor them.
    disable_signals

    if [[ ${__BU_DIE_IN_PROGRESS:=0} -ne 0 ]] ; then
        exit ${__BU_DIE_IN_PROGRESS}
    fi
    
    $(opt_parse \
        ":return_code rc r=1 | Return code that die will eventually exit with." \
        ":signal s           | Signal that caused this die to occur." \
        ":color c            | DEPRECATED OPTION -- no longer has any effect." \
        ":frames f=3         | Number of stack frames to skip.")

    __BU_DIE_IN_PROGRESS=${return_code}
    : ${__BU_DIE_BY_SIGNAL:=${signal}}

    if inside_try ; then
        # Don't print a stack trace for errors that were caught
        true

    else
        echo "" >&2
        eerror_internal   -c="${COLOR_ERROR}" "${@}"
        eerror_stacktrace -c="${COLOR_ERROR}" -f=${frames} -s
    fi

    reenable_signals

    # If we're in a subshell signal our parent SIGTERM and then exit. This will
    # allow the parent process to gracefully perform any cleanup before the
    # process ultimately exits.
    if [[ $$ != ${BASHPID} ]]; then
        
        # Kill the parent shell.  This is how we detect failures inside command
        # substituion shells.  Bash would typically ignore them, but this
        # causes the shell calling the command substitution to fail and call die.
        #
        # Note: The shell that makes up the "try" body of a try/catch is
        # special.  We don't want to kill the try, we want to let the catch
        # handle things.
        #
        if [[ ${__BU_DISABLE_DIE_PARENT_PID:-0} != ${pid} ]] ; then
            edebug "Sending kill to parent $(lval parent pid __BU_DISABLE_DIE_PARENT_PID)"
            ekill -s=SIGTERM ${parent}
        fi

        # Then kill all children of the current process (but not the current process)
        edebug "Killing children of ${pid}"
        ekilltree -s=SIGTERM -k=2s -x=${pid} ${pid}

        # Last, finish up the current process. 
        if [[ -n "${__BU_DIE_BY_SIGNAL}" ]] ; then
            # When a process dies as the result of a SIGINT or other tty
            # signals, the proper thing to do is not to exit but to kill self
            # with that same signal.
            # 
            # See http://www.cons.org/cracauer/sigint.html and
            # http://mywiki.wooledge.org/SignalTrap
            #
            if array_contains TTY_SIGNALS "${__BU_DIE_BY_SIGNAL}" ; then
                trap - ${__BU_DIE_BY_SIGNAL}
                ekill -s=${__BU_DIE_BY_SIGNAL} ${BASHPID}
            else
                exit $(sigexitcode "${__BU_DIE_BY_SIGNAL}")
            fi
        else
            exit ${__BU_DIE_IN_PROGRESS}
        fi
    else
        if declare -f die_handler &>/dev/null; then
            die_handler -r=${__BU_DIE_IN_PROGRESS} "${@}"
            __BU_DIE_IN_PROGRESS=0
        else
            ekilltree -s=SIGTERM -k=2s $$
            exit ${__BU_DIE_IN_PROGRESS}
        fi
    fi
}

# Save off the current state of signal-based traps and disable them.  You may
# be interested in doing this if you're very concerned that a short bit of code
# should not be interrupted by a signal.  Be _SURE_ to call renable signals
# when you're done.
#
disable_signals()
{
    declare -Ag _BASHUTILS_SAVED_TRAPS
    _BASHUTILS_SAVED_TRAPS[$BASHPID]=$(trap -p "${DIE_SIGNALS[@]}")
    trap "" "${DIE_SIGNALS[@]}"
}

reenable_signals()
{
    eval "${_BASHUTILS_SAVED_TRAPS[$BASHPID]}"
}

# Appends a command to a trap. By default this will use the default list of
# signals: ${DIE_SIGNALS[@]}, ERR and EXIT so that this trap gets called
# by default for any signal that would cause termination. If that's not the
# desired behavior then simply pass in an explicit list of signals to trap.
#
# Options:
# $1: body of trap to be appended
# $@: Optional list of signals to trap (or default to DIE_SIGNALS and EXIT).
#
trap_add()
{
    $(opt_parse "?cmd")
    local signals=( "${@}" )
    [[ ${#signals[@]} -gt 0 ]] || signals=( EXIT )

    local sig
    for sig in "${signals[@]}"; do
        sig=$(signame -s ${sig})

        # If we're at the same shell level where we have set any trap, then
        # it's safe to append to the existing trap.  If we haven't set any trap
        # in this shell level, bash will show us the parent shell's traps
        # instead and we don't want to copy those into this shell.
        local existing=""
        if [[ ${__BU_TRAP_LEVEL:-0} -eq ${BASH_SUBSHELL} ]]; then
            existing="$(trap_get ${sig})"

            # Strip off our bashutils internal cleanup from the trap, because
            # we'll add it back in later.
            existing=${existing%%; _bashutils_on_exit_end}
            existing=${existing##_bashutils_on_exit_start; }

            # __BU_TRAP_LEVEL is owned and updated by our trap() function.
            # It'll update it soon.
        fi

        local complete_trap
        [[ ${sig} == "EXIT" ]] && complete_trap+="_bashutils_on_exit_start; "
        [[ -n "${cmd}"      ]] && complete_trap+="${cmd}; "
        [[ -n "${existing}" ]] && complete_trap+="${existing}; "
        [[ ${sig} == "EXIT" ]] && complete_trap+="_bashutils_on_exit_end"
        trap -- "${complete_trap}" "${sig}"

    done
}


# Bashutils asks bash to let the ERR and DEBUG traps be inherited from shell to
# subshell by setting appropriate shell options.  Unfortunately, its method of
# enforcing that inheritance is somewhat limited.  It only lasts until someone
# sets any other trap.  At that point, the inhertied trap is erased.
#
# To workaround this behavior, bashutils overrides "trap" such that it will do
# the normal work that you expect trap to do, but it will also make sure that
# the ERR and DEBUG traps are truly inherited from shell to shell and persist
# regardless of whether other traps are created.
#
trap()
{
    # If trap received any options, don't do anything special.  Only -l and -p
    # are supported by bash's trap and they don't affect the current set of
    # traps.
    if [[ "$1" == "--" || "$1" != -* ]] ; then

        # __BU_TRAP_LEVEL is the ${BASH_SUBSHELL} value that was used the last time
        # trap was called.  BASH_SUBSHELL is incremented for each nested subshell.
        # At the top level, that is 0
        if [[ ${__BU_TRAP_LEVEL:=0} -lt ${BASH_SUBSHELL} ]] ; then

            local trapsToSave="$(builtin trap -p ERR DEBUG)"

            # Call "builtin trap" rather than "trap" because we don't want to
            # recurse infinitely.  Note, the backslashes before the hyphens in
            # this pattern are superfluous to bash, but they make vim's syntax
            # highlighting much happier.
            trapsToSave="${trapsToSave//trap --/builtin trap \-\-}"

            # Call the trap builtin to set those ERR and DEBUG traps first
            eval "${trapsToSave}"

            __BU_TRAP_LEVEL=${BASH_SUBSHELL}
        fi

    fi

    builtin trap "${@}"
}


_bashutils_on_exit_start()
{
    # Save off the exit code the fist time the exit trap is called -- it can be
    # reinvoked multiple times in the process of the shell going down.
    #
    local exit_code=$?
    if [[ ! -v __BU_EXIT_CODE ]] ; then
        # Store off the exit code. This is used at the end of the exit trap inside _bashutils_on_exit_end.
        __BU_EXIT_CODE=${exit_code}
        disable_signals
    fi
}

_bashutils_on_exit_end()
{
    reenable_signals

    # If we're exiting with non-zero exit code, make sure that it occurred
    # through our custom exit function.  The only reason we currently believe
    # that it will _not_ go through that path is if bash dies due to an unset
    # variable.
    #
    # Then we execute die to try to make it more clear where things went crazy.
    if [[ ${__BU_INTERNAL_EXIT:-0} != "1" && ${__BU_EXIT_CODE:-} != "0" ]]; then
        eval "die ${DIE_MSG_UNHERR}"
    fi
}

# Set the trace attribute for trap_add function. This is required to modify
# DEBUG or RETURN traps because functions don't inherit them unless the trace
# attribute is set.
declare -f -t trap_add

# List of signals which will cause die() to be called. These signals are the ones
# which by default bash uses to cause a program to terminate or abort. It may seem
# odd to register traps for things like SIGKILL since you can't IGNORE signals like
# that. However, you can still register a trap instead of the default handler bash
# uses and do something BEFORE you are terminated. If you don't register new traps
# for these signals then you get really annoying error messages whenever a process
# is killed or aborted.
#
# NOTE: We use this list below in die_on_abort and nodie_on_abort which we call
# shortly below this as our global default traps. Additionally, it is very important
# to call die_on_abort at the start of any command substitution which you want to be
# interruptible.
DIE_SIGNALS=( SIGHUP    SIGINT   SIGQUIT   SIGILL   SIGABRT   SIGFPE   SIGKILL
              SIGSEGV   SIGPIPE  SIGALRM   SIGTERM  SIGUSR1   SIGUSR2  SIGBUS
              SIGIO     SIGPROF  SIGSYS    SIGTRAP  SIGVTALRM SIGXCPU  SIGXFSZ
            )

# These signals are typically generated by the TTY when the person at the
# terminal hits a key.  Typical terminals have them configured to be SIGINT on
# Ctrl-C, SIGQUIT on Ctrl-\, and SIGTSTP on Ctrl-Z.
#
# The funny thing about the way the TTY sends the signals is that they go to
# the whole process group at once, rather than just, say, the foreground
# process.
#
TTY_SIGNALS=( SIGINT SIGQUIT SIGTSTP )

# Enable default traps for all DIE_SIGNALS to call die().
die_on_abort()
{
    export __BU_DIE_ON_ABORT_ENABLED=1

    local signal
    for signal in "${DIE_SIGNALS[@]}" ; do
        trap "die -s=${signal} \"[Caught ${signal} pid=\${BASHPID} cmd=\$(string_truncate -e 60 \${BASH_COMMAND})\"]" ${signal}
    done
}

# Disable default traps for all DIE_SIGNALS.
nodie_on_abort()
{
    export __BU_DIE_ON_ABORT_ENABLED=0

    local signals=( "${@}" )
    [[ ${#signals[@]} -gt 0 ]] || signals=( ${DIE_SIGNALS[@]} )
    trap - ${signals[@]}
}

#-----------------------------------------------------------------------------
# FANCY I/O ROUTINES
#-----------------------------------------------------------------------------

# Check if we are "interactive" or not. For our purposes, we are interactive
# if STDERR is attached to a terminal or not. This is checked via the bash
# idiom "[[ -t 2 ]]" where "2" is STDERR. But we can override this default
# check with the global variable EINTERACTIVE=1.
einteractive()
{
    [[ ${EINTERACTIVE:-0} -eq 1 ]] && return 0
    [[ -t 2 ]]
}

ecolor_code()
{
   case $1 in

        # Primary
        black)            echo 0     ;;
        red)              echo 1     ;;
        green)            echo 2     ;;
        yellow)           echo 3     ;;
        blue)             echo 4     ;;
        magenta)          echo 5     ;;
        cyan)             echo 6     ;;
        white)            echo 7     ;;

        # Derivatives
        grey0)            echo 16     ;;
        navyblue)         echo 17     ;;
        darkgreen)        echo 22     ;;
        deepskyblue)      echo 24     ;;
        dodgerblue)       echo 26     ;;
        springgreen)      echo 35     ;;
        darkturqouise)    echo 44     ;;
        turquoise)        echo 45     ;;
        blueviolet)       echo 57     ;;
        orange)           echo 58     ;;
        slateblue)        echo 62     ;;
        paleturquoise)    echo 66     ;;
        steelblue)        echo 67     ;;
        cornflowerblue)   echo 69     ;;
        aquamarine)       echo 79     ;;
        darkred)          echo 88     ;;
        darkmagenta)      echo 90     ;;
        plum)             echo 96     ;;
        wheat)            echo 101    ;;
        lightslategrey)   echo 103    ;;
        darkseagreen)     echo 108    ;;
        darkviolet)       echo 128    ;;
        darkorange)       echo 130    ;;
        hotpink)          echo 132    ;;
        mediumorchid)     echo 134    ;;
        lightsalmon)      echo 137    ;;
        gold)             echo 142    ;;
        darkkhaki)        echo 143    ;;
        indianred)        echo 167    ;;
        orchid)           echo 170    ;;
        violet)           echo 177    ;;
        tan)              echo 180    ;;
        lightyellow)      echo 185    ;;
        honeydew)         echo 194    ;;
        salmon)           echo 209    ;;
        pink)             echo 218    ;;
        thistle)          echo 225    ;;

        # Lots of grey
        grey100)          echo 231    ;;
        grey3)            echo 232    ;;
        grey7)            echo 233    ;;
        grey11)           echo 234    ;;
        grey15)           echo 235    ;;
        grey19)           echo 236    ;;
        grey23)           echo 237    ;;
        grey27)           echo 238    ;;
        grey30)           echo 239    ;;
        grey35)           echo 240    ;;
        grey39)           echo 241    ;;
        grey42)           echo 242    ;;
        grey46)           echo 243    ;;
        grey50)           echo 244    ;;
        grey54)           echo 245    ;;
        grey58)           echo 246    ;;
        grey62)           echo 247    ;;
        grey66)           echo 248    ;;
        grey70)           echo 249    ;;
        grey74)           echo 250    ;;
        grey78)           echo 251    ;;
        grey82)           echo 252    ;;
        grey85)           echo 253    ;;
        grey89)           echo 254    ;;
        grey93)           echo 255    ;;

        # Unknown color code
        *)                die "Unknown color: $1" ;;
   esac

   return 0
}

ecolor()
{
    ## If EFUNCS_COLOR is empty then set it based on if STDERR is attached to a console
    local efuncs_color=${EFUNCS_COLOR:=}
    [[ -z ${efuncs_color} ]] && einteractive && efuncs_color=1
    [[ ${efuncs_color} -eq 1 ]] || return 0

    declare -Ag __BU_COLOR_CACHE
    local index=$*
    if [[ ! -v "__BU_COLOR_CACHE[$index]" ]] ; then
        __BU_COLOR_CACHE[$index]=$(ecolor_internal "${index}")
    fi

    echo -n "${__BU_COLOR_CACHE[$index]}"
}

ecolor_internal()
{
    local c=""
    for c in $@; do
        case ${c} in
            dim)            echo -en "\033[2m"                 ;;
            invert)         tput rev                           ;;
            bold)           tput bold                          ;;
            underline)      tput smul                          ;;
            reset|none|off) echo -en "\033[0m"                 ;;
            b:*)            tput setab $(ecolor_code ${c#b:})  ;;
            *)              tput setaf $(ecolor_code ${c})     ;;
        esac
    done
}

eclear()
{
    tput clear >&2
}

etimestamp()
{
    echo -en "$(date '+%b %d %T.%3N')"
}

# Display a very prominent banner with a provided message which may be multi-line
# and an optional timestamp as well as the ability to provide any number of extra
# arguments which will be included in the banner in a pretty printed tag=value
# format. All of this is implemented with print_value to give consistency in how
# we log and present information.
ebanner()
{
    {
        local cols lines entries

        echo ""
        cols=${COLUMNS:-80}
        cols=$((cols-2))
        eval "local str=\$(printf -- '-%.0s' {1..${cols}})"
        ecolor ${COLOR_BANNER}
        echo -e "+${str}+"
        echo -e "|"

        # Print the first message honoring any newlines
        array_init_nl lines "${1}"; shift
        for line in "${lines[@]}"; do
            echo -e "| ${line}"
        done

        # Iterate over all other arguments and stick them into an associative array
        # If a custom key was requested via "key=value" format then use the provided
        # key and lookup value via print_value.
        declare -A __details

        local entries=("${@}")
        for k in "${entries[@]:-}"; do
            [[ -z ${k} ]] && continue

            local _ktag="${k%%=*}";
            : ${_ktag:=${k}}
            local _kval="${k#*=}";
            _ktag=${_ktag#+}
            __details[${_ktag}]=$(print_value ${_kval})

        done

        # Now output all the details (if any)
        if [[ -n ${__details[@]:-} ]]; then
            echo -e "|"

            # Sort the keys and store into an array
            local keys
            keys=( $(for key in ${!__details[@]}; do echo "${key}"; done | sort) )

            # Figure out the longest key
            local longest=0
            for key in ${keys[@]}; do
                local len=${#key}
                (( len > longest )) && longest=$len
            done

            # Iterate over the keys of the associative array and print out the values
            for key in ${keys[@]}; do
                local pad=$((longest-${#key}+1))
                printf "| • %s%${pad}s :: %s\n" ${key} " " "${__details[$key]}"
            done
        fi

        # Close the banner
        echo -e "|"
        echo -en "+${str}+"
        ecolor none
        echo ""

    } >&2

    return 0
}

emsg()
{
    {
        local color=$1 ; shift
        local header=$1 ; shift
        local level=$1 ; shift
        local msg="$*"

        local informative_header=0
        if [[ ${EMSG_PREFIX} =~ ${BU_WORD_BEGIN}(time|times|level|caller|pid|all)${BU_WORD_END} ]] ; then
            informative_header=1
        fi

        # Print the "informative header" containing things like timestamp, calling
        # function, etc.  We choose which ones to print based on the contents of
        # EMSG_PREFIX and which ones to color based on the value of EMSG_COLOR
        if [[ ${informative_header} == 1 && ${level} != @(INFOS|WARNS) ]] ; then
            ecolor $color
            echo -n "["
            ecolor reset

            local field first_printed=0
            for field in time level caller pid ; do

                # If the field is one selected by EMSG_PREFIX...
                if [[ ${EMSG_PREFIX} =~ ${BU_WORD_BEGIN}(all|${field})${BU_WORD_END} ]] ; then

                    # Separator if this isn't the first field to print
                    [[ ${first_printed} -eq 1 ]] && { ecolor reset ; echo -n "|" ; }

                    # Start color if appropriate
                    [[ ${EMSG_COLOR} =~ ${BU_WORD_BEGIN}(all|${field})${BU_WORD_END} ]] && ecolor $color

                    # Print the individual field
                    case ${field} in
                        time|times)
                            etimestamp
                            ;;
                        level)
                            echo -n "${level}"
                            ;;
                        caller)
                            # First field is filename with path info stripped off
                            echo -n "${BASH_SOURCE[2]##*/}:${BASH_LINENO[1]}:${FUNCNAME[2]:-}"
                            ;;
                        pid)
                            echo -n "${BASHPID}"
                            ;;
                        *)
                            die "Internal error."
                            ;;
                    esac

                    first_printed=1
                    ecolor reset
                fi
        
            done

            ecolor $color
            echo -n "] "

        else
            # If not the informative header, just use the message-type-specific
            # header passed as an argument to emsg
            ecolor $color
            echo -n "${header} "
        fi

        # If EMSG_COLOR doesn't say to color the message turn off color before
        # we start printing it
        [[ ! ${EMSG_COLOR} =~ ${BU_WORD_BEGIN}(all|msg)${BU_WORD_END} ]] && ecolor reset

        # Also, only print colored messages for certain levels
        [[ ${level} != @(DEBUG|WARN|WARNS|ERROR) ]] && ecolor reset

        echo -n "${msg}"
        ecolor reset
        echo ""
    } >&2
}

einfo()
{
    emsg "${COLOR_INFO}" ">>" "INFO" "$@"
}

einfos()
{
    emsg "${COLOR_INFO}" "   -" "INFOS" "$@"
}

ewarn()
{
    emsg "${COLOR_WARN}" ">>" "WARN" "$@"
}

ewarns()
{
    emsg "${COLOR_WARN}" "   -" "WARNS" "$@"
}

eerror_internal()
{
    $(opt_parse ":color c=${COLOR_ERROR} | Color to print the message in.")
    emsg "${color}" ">>" "ERROR" "$@"
}

eerror()
{
    emsg "${COLOR_ERROR}" ">>" "ERROR" "$@"
}

# Print an error stacktrace to stderr.  This is like stacktrace only it pretty prints
# the entire stacktrace as a bright red error message with the funct and file:line
# number nicely formatted for easily display of fatal errors.
#
# Allows you to optionally pass in a starting frame to start the stacktrace at. 0 is
# the top of the stack and counts up. See also stacktrace and eerror_stacktrace.
#
# OPTIONS:
# -f=N
#   Frame number to start at (defaults to 2 to skip the top frames with
#   eerror_stacktrace and stacktrace_array).
#
# -s=(0|1)
#   Skip the initial error message (e.g. b/c the caller already displayed it).
#
# -c=(color)
#   Use the specified color for output messages.  Defaults to red.  Supports
#   any color that is supported by ecolor.
#
eerror_stacktrace()
{
    $(opt_parse \
        ":frame f=2              | Frame number to start at.  Defaults to 2, which skips this function and its caller." \
        "+skip s                 | Skip the initial error message.  Useful if the caller already displayed it." \
        ":color c=${COLOR_ERROR} | Use the specified color for output messages.")

    if [[ ${skip} -eq 0 ]]; then 
        echo "" >&2
        eerror_internal -c="${color}" "$@"
    fi

    local frames=() frame
    stacktrace_array -f=${frame} frames

    array_empty frames ||
    for frame in "${frames[@]}"; do
        local line=$(echo ${frame} | awk '{print $1}')
        local func=$(echo ${frame} | awk '{print $2}')
        local file=$(basename $(echo ${frame} | awk '{print $3}'))

        [[ ${file} == "efuncs.sh" && ${func} == ${FUNCNAME} ]] && break

        printf "$(ecolor ${color})   :: %-20s | ${func}$(ecolor none)\n" "${file}:${line}" >&2
    done
}

# etable("col1|col2|col3", "r1c1|r1c2|r1c3"...)
etable()
{
    $(opt_parse "columns")
    local lengths=()
    local parts=()
    local idx=0

    for line in "${columns}" "$@"; do
        array_init parts "${line}" "|"
        idx=0
        for p in "${parts[@]}"; do
            mlen=${#p}
            [[ ${mlen} -gt ${lengths[$idx]:-} ]] && lengths[$idx]=${mlen}
            idx=$((idx+1))
        done
    done

    divider="+"
    array_init parts "${columns}" "|"
    idx=0
    for p in "${parts[@]}"; do
        len=$((lengths[$idx]+2))
        s=$(printf "%${len}s+")
        divider+=$(echo -n "${s// /-}")
        idx=$((idx+1))
    done

    printf "%s\n" ${divider}

    lnum=0
    for line in "${columns}" "$@"; do
        array_init parts "${line}" "|"
        idx=0
        printf "|"
        for p in "${parts[@]}"; do
            pad=$((lengths[$idx]-${#p}+1))
            printf " %s%${pad}s|" "${p}" " "
            idx=$((idx+1))
        done
        printf $'\n'
        lnum=$((lnum+1))
        if [[ ${lnum} -eq 1 || ${lnum} -eq $(( $# + 1 )) ]]; then
            printf "%s\n" ${divider}
        else
            [[ ${ETABLE_ROW_LINES:-1} -eq 1 ]] && printf "%s\n" ${divider//+/|}
        fi
    done
}

eprompt()
{
    echo -en "$(ecolor bold) * $@: $(ecolor none)" >&2
    local result=""

    read result < /dev/stdin

    echo -en "${result}"
}

# eprompt_with_options allows the caller to specify what options are valid
# responses to the provided question. The caller can also optionally provide
# a list of "secret" options which will not be displayed in the prompt to the
# user but will be accepted as a valid response.
eprompt_with_options()
{
    $(opt_parse "msg" "opt" "?secret")
    local valid="$(echo ${opt},${secret} | tr ',' '\n' | sort --ignore-case --unique)"
    msg+=" (${opt})"

    ## Keep reading input until a valid response is given
    while true; do
        response=$(eprompt "${msg}")
        matches=( $(echo "${valid}" | grep -io "^${response}\S*" || true) )
        edebug "$(lval response opt secret matches valid)"
        [[ ${#matches[@]} -eq 1 ]] && { echo -en "${matches[0]}"; return 0; }

        eerror "Invalid response=[${response}] -- use a unique prefix from options=[${opt}]"
    done
}

epromptyn()
{
    $(opt_parse "msg")
    eprompt_with_options "${msg}" "Yes,No"
}

string_trim()
{
    local text=$*
    text=${text%%+([[:space:]])}
    text=${text##+([[:space:]])}
    printf -- "%s" "${text}"
}

# Truncate a specified string to fit within the specified number of characters.
# If the ellipsis option is specified, truncation will result in an ellipses
# where the removed characters were (and the total string will still fit within
# length characters)
#
# Any arguments after the length will be considered part of the text to
# string_truncate
#
string_truncate()
{
    $(opt_parse \
        "+ellipsis e | If set, an elilipsis (...) will replace any removed text." \
        "length      | Desired maximum length for text." )

    local text=$*

    if [[ ${#text} -gt ${length} && ${ellipsis} -eq 1 ]] ; then
        printf -- "%s" "${text:0:$((length-3))}..."
    else
        printf -- "%s" "${text:0:${length}}"
    fi
}

# Collapse grouped whitespace in the specified string to single spaces.
string_collapse()
{
    local output=$(echo -en "$@" | tr -s "[:space:]" " ")
    echo -en "${output}"
}

eend()
{
    local rc=${1:-0}

    if einteractive; then
        # Terminal magic that:
        #    1) Gets the number of columns on the screen, minus 6 because that's
        #       how many we're about to output
        #    2) Moves up a line
        #    3) Moves right the number of columns from #1
        local columns=$(tput cols)
        local startcol=$(( columns - 6 ))
        [[ ${startcol} -gt 0 ]] && echo -en "$(tput cuu1)$(tput cuf ${startcol} 2>/dev/null)" >&2
    fi

    if [[ ${rc} -eq 0 ]]; then
        echo -e "$(ecolor ${COLOR_BRACKET})[$(ecolor ${COLOR_INFO}) ok $(ecolor ${COLOR_BRACKET})]$(ecolor none)" >&2
    else
        echo -e "$(ecolor ${COLOR_BRACKET})[$(ecolor ${COLOR_ERROR}) !! $(ecolor ${COLOR_BRACKET})]$(ecolor none)" >&2
    fi
}

spinout()
{
    local char="$1"
    echo -n -e "\b${char}" >&2
    sleep 0.10
}

do_eprogress()
{
    # Automatically detect if we should use ticker based on if we are interactive or not.
    if ! einteractive; then
        while true; do
            echo -n "." >&2
            sleep 1
        done
        return 0
    fi

    # Sentinal for breaking out of the loop on signal from eprogress_kill
    local done=0
    trap "done=1" ${DIE_SIGNALS[@]}

    local start=${SECONDS}
    while [[ ${done} -ne 1 ]]; do
        local now="${SECONDS}"
        local diff=$(( ${now} - ${start} ))

        ecolor bold >&2
        printf " [%02d:%02d:%02d]  " $(( ${diff} / 3600 )) $(( (${diff} % 3600) / 60 )) $(( ${diff} % 60 )) >&2
        ecolor none >&2

        spinout "/"
        spinout "-"
        spinout "\\"
        spinout "|"
        spinout "/"
        spinout "-"
        spinout "\\"
        spinout "|"

        # If we're terminating delete whatever character was lost displayed and print a blank space over it
        # then return immediately instead of resetting for next loop
        [[ ${done} -eq 1 ]] && { echo -en "\b " >&2; return 0; }

        echo -en "\b\b\b\b\b\b\b\b\b\b\b\b\b" >&2
    done
}

eprogress()
{
    echo -en "$(emsg "${COLOR_INFO}" ">>" "INFO" "$@" 2>&1)" >&2

    # Allow caller to opt-out of eprogress entirely via EPROGRESS=0
    [[ ${EPROGRESS:-1} -eq 0 ]] && return 0

    # Prepend this new eprogress pid to the front of our list of eprogress PIDs
    # Add a trap to ensure we kill this backgrounded process in the event we
    # die before calling eprogress_kill.
    ( close_fds ; do_eprogress ) &
    __BU_EPROGRESS_PIDS+=( $! )
    trap_add "eprogress_kill -r=1 $!"
}

# Kill the most recent eprogress in the event multiple ones are queued up.
# Can optionally pass in a specific list of eprogress pids to kill.
#
# Options:
# -r Return code to use (defaults to 0)
# -a Kill all eprogress pids.
eprogress_kill()
{
    $(opt_parse \
        ":rc return_code r=0  | Should this eprogress show a mark for success or failure?" \
        "+all a               | If set, kill ALL known eprogress processes, not just the current one")

    # Allow caller to opt-out of eprogress entirely via EPROGRESS=0
    if [[ ${EPROGRESS:-1} -eq 0 ]] ; then
        einteractive && echo "" >&2
        eend ${rc}
        return 0
    fi

    # If given a list of pids, kill each one. Otherwise kill most recent.
    # If there's nothing to kill just return.
    local pids=()
    if [[ $# -gt 0 ]]; then
        pids=( ${@} )
    elif array_not_empty __BU_EPROGRESS_PIDS; then 
        if [[ ${all} -eq 1 ]] ; then
            pids=( "${__BU_EPROGRESS_PIDS[@]}" )
        else
            pids=( "${__BU_EPROGRESS_PIDS[-1]}" )
        fi
    else
        return 0
    fi

    # Kill requested eprogress pids
    local pid
    for pid in ${pids[@]}; do

        # Don't kill the pid if it's not running or it's not an eprogress pid.
        # This catches potentially disasterous errors where someone would do
        # "eprogress_kill ${rc}" when they really meant "eprogress_kill -r=${rc}"
        if process_not_running ${pid} || ! array_contains __BU_EPROGRESS_PIDS ${pid}; then
            continue
        fi

        # Kill process and wait for it to complete
        ekill ${pid} &>/dev/null
        wait ${pid} &>/dev/null || true
        array_remove __BU_EPROGRESS_PIDS ${pid}

        # Output
        einteractive && echo "" >&2
        eend ${rc}
    done

    return 0
}

#-----------------------------------------------------------------------------
# SIGNAL FUNCTIONS
#-----------------------------------------------------------------------------

# Given a name or number, echo the signal name associated with it.
#
signum()
{
    if [[ "$1" =~ ^[[:digit:]]$ ]] ; then
        echo "$1"

    # For a complete list of bash pseudo-signals, see help trap (this is the
    # complete list at time of writing)
    elif [[ "$1" == "EXIT" || "$1" == "ERR" || "$1" == "DEBUG" || "$1" == "RETURN" ]] ; then
        die "Bash pseudo signal $1 does not have a signal number."

    else
        kill -l "$1"
    fi
    return 0
}

# Given a signal name or number, echo the signal number associated with it.
#
# With the --include-sig option, SIG will be part of the name for signals where
# that is appropriate.  For instance, SIGTERM or SIGABRT rather than TERM or
# ABRT.  Note that bash pseudo signals never use SIG.  This function treats
# those appropriately (i.e. even with --include sig will return EXIT rather
# than SIGEXIT)
# 
signame()
{
    $(opt_parse \
        "+include_sig s | Get the form of the signal name that includes SIG.")

    local prefix=""
    if [[ ${include_sig} -eq 1 ]] ; then
        prefix="SIG"
    fi

    if [[ "$1" =~ ^[[:digit:]]+$ ]] ; then
        echo "${prefix}$(kill -l "$1")"

    elif [[ "${1^^}" == "EXIT" || "${1^^}" == "SIGEXIT" ]]; then
        echo "EXIT"

    elif [[ "${1^^}" == "ERR" || "${1^^}" == "SIGERR" ]]; then
        echo "ERR"

    elif [[ "${1^^}" == "DEBUG" || "${1^^}" == "SIGDEBUG" ]]; then
        echo "DEBUG"

    else
        # Find the associated number, and then get the name that bash believes
        # is associated with that number
        echo "${prefix}$(kill -l "$(kill -l "$1")")"
    fi
    return 0
}

# Given a signal name or number, echo the exit code that a bash process
# would produce if it died due to the specified signal.
sigexitcode()
{
    echo "$(( 128 + $(signum $1) ))"
    return 0
}


#-----------------------------------------------------------------------------
# PROCESS FUNCTIONS
#-----------------------------------------------------------------------------

# This is a simple override of the linux pstree command.  The trouble with that
# command is that it likes to segfault.  It's buggy.  So here, we simply ignore
# the error codes that would come from it.
#
if [[ ${__BU_OS} == Linux ]] ; then
    pstree()
    {
        (
            ulimit -c 0
            command pstree "${@}" || true
        )
    }
fi

# Check if a given process is running. Returns success (0) if all of the
# specified processes are running and failure (1) otherwise.
process_running()
{
    local pid
    for pid in "${@}" ; do
        if ! ps -p ${pid} &>/dev/null ; then
            return 1
        fi
    done
    return 0
}

# Check if a given process is NOT running. Returns success (0) if all of the
# specified processes are not running and failure (1) otherwise.
process_not_running()
{
    local pid
    for pid in "${@}" ; do
        if ps -p ${pid} &>/dev/null ; then
            return 1
        fi
    done
    return 0
}

# Generate a depth first recursive listing of entire process tree beneath a given PID.
# If the pid does not exist this will produce an empty string.
#
process_tree()
{
    $(opt_parse \
        ":ps_all | Pre-prepared output of \"ps -eo ppid,pid\" so I can avoid calling ps repeatedly")
    : ${ps_all:=$(ps -eo ppid,pid)}


    # Assume current process if none is specified
    if [[ ! $# -gt 0 ]] ; then
        set -- ${BASHPID}
    fi

    local parent
    for parent in ${@} ; do

        echo ${parent}

        local children=$(process_children --ps-all "${ps_all}" ${parent})
        local child
        for child in ${children} ; do
            process_tree --ps-all "${ps_all}" "${child}"
        done

    done
}

# Print the pids of all children of the specified list of processes.  If no
# processes were specified, default to ${BASHPID}.
#
# Note, this doesn't print grandchildren and other descendants.  Just children.
# See process_tree for a recursive tree of descendants.
#
process_children()
{
    $(opt_parse \
        ":ps_all | The contents of \"ps -eo ppid,pid\", produced ahead of time to avoid calling ps over and over")
    : ${ps_all:=$(ps -eo ppid,pid)}

    # If nothing was specified, assume the current process
    if [[ ! $# -gt 0 ]] ; then
        set -- ${BASHPID}
    fi

    local parent
    local children=()
    for parent in "${@}" ; do
        children+=( $(echo "${ps_all}" | awk '$1 == '${parent}' {print $2}') )
    done

    echo "${children[@]:-}"
}

# Print the pid of the parent of the specified process, or of $BASHPID if none
# is specified.
#
process_parent()
{
    $(opt_parse "?child | pid of child process")
    [[ $# -gt 0 ]] && die "process_parent only accepts one child to check."

    : ${child:=${BASHPID}}

    ps -eo ppid,pid | awk '$2 == '${child}' {print $1}'
}

# Print pids of all ancestores of the specified list of processes, up to and
# including init (pid 1).  If no processes are specified as arguments, defaults
# to ${BASHPID}
#
process_ancestors()
{
    $(opt_parse "?child | pid of process whose ancestors will be printed.")
    [[ $# -gt 0 ]] && die "process_ancestors only accepts one child to check."

    [[ -z ${child} ]] && child=${BASHPID}

    local ps_all=$(ps -eo ppid,pid)

    local parent=${child}
    local ancestors=()
    while [[ ${parent} != 1 ]] ; do
        parent=$(echo "${ps_all}" | awk '$2 == '${parent}' {print $1}')
        ancestors+=( ${parent} )
    done

    echo "${ancestors[@]}"
}

# Kill all pids provided as arguments to this function using the specified signal.
# This function is best effort only. It makes every effort to kill all the specified
# pids but ignores any errors while calling kill. This is largely due to the fact
# that processes can exit before we get a chance to kill them. If you really care
# about processes being gone consider using process_not_running or cgroups.
#
# Options:
# -s=SIGNAL The signal to send to the pids (defaults to SIGTERM).
# -k=duration 
#   Elevate to SIGKILL after waiting for the specified duration after sending
#   the initial signal.  If unspecified, ekill does not elevate.
ekill()
{
    $(opt_parse \
        ":signal sig s=SIGTERM | The signal to send to specified processes, either as a number or a signal name." \
        ":kill_after k         | Elevate to SIGKILL after waiting for this duration after sending the initial signal.  Accepts any duration that sleep would accept.")

    # Determine what signal to send to the processes
    local processes=( $@ )

    # Don't kill init, unless init has been replaced by our parent bash script
    # in which case we really do want to kill it.
    if [[ $$ != "1" ]] ; then
        array_remove processes 1
        array_empty processes && { edebug "nothing besides init to kill." ; return 0 ; }
    fi


    # When debugging, display the full list of processes to kill
    if edebug_enabled ; then
        edebug "killing $(lval signal processes kill_after) BASHPID=${BASHPID}"

        # Print some process info for any processes that are still alive
        ps -o "pid,user,start,command" -p $(array_join processes ',') | tail -n +2 >&2 || true
    fi

    # Kill all requested PIDs using requested signal.
    kill -${signal} ${processes[@]} &>/dev/null || true

    if [[ -n ${kill_after} && $(signame ${signal}) != "KILL" ]] ; then
        # Note: double fork here in order to keep ekilltree from paying any
        # attention to these processes.
        (
            :
            (
                close_fds
                disable_die_parent

                sleep ${kill_after}
                kill -SIGKILL ${processes[@]} &>/dev/null || true
            ) &
        ) &
    fi
}

# Kill entire process tree for each provided pid by doing a depth first search to find
# all the descendents of each pid and kill all leaf nodes in the process tree first.
# Then it walks back up and kills the parent pids as it traverses back up the tree.
# Like ekill(), this function is best effort only. If you want more robust guarantees
# consider process_not_running or cgroups.
#
# Note that ekilltree will never kill the current process or ancestors of the
# current process, as that would cause ekilltree to be unable to succeed.

# Options:
# -s=SIGNAL 
#       The signal to send to the pids (defaults to SIGTERM).
# -x="pids"
#       Pids to exclude from killing.  Ancestors of the current process are
#       _ALWAYS_ excluded (because if not, it would likely prevent ekilltree
#       from succeeding)
# -k=duration 
#       Elevate to SIGKILL after waiting for the specified duration after
#       sending the initial signal.  If unspecified, ekilltree does not
#       elevate.
#
ekilltree()
{
    $(opt_parse \
        ":signal sig s=SIGTERM | The signal to send to the process tree, either as a number or a name." \
        ":exclude x            | Processes to exclude from being killed." \
        ":kill_after k         | Elevate to SIGKILL after this duration if the processes haven't died.")

    # Determine what signal to send to the processes
    local excluded="$(process_ancestors ${BASHPID}) ${exclude}"

    local processes=( $(process_tree ${@}) )
    array_remove -a processes ${excluded}

    edebug "Killing $(lval processes signal kill_after excluded)"
    if array_not_empty processes ; then
        ekill -s=${signal} -k=${kill_after} "${processes[@]}"
    fi

    return 0
}

#-----------------------------------------------------------------------------
# LOGGING
#-----------------------------------------------------------------------------

# Print the value for the corresponding variable using a slightly modified
# version of what is returned by declare -p. This is the lower level function
# called by lval in order to easily print tag=value for the provided arguments
# to lval. The type of the variable will dictate the delimiter used around the
# value portion. Wherever possible this is meant to generally mimic how the
# types are declared and defined.
#
# Specifically:
#
# - Strings: delimited by double quotes.
# - Arrays and associative arrays: Delimited by ( ).
# - Packs: You must preceed the pack name with a percent sign (i.e. %pack)
#
# Examples:
# String: "value1"
# Arrays: ("value1" "value2 with spaces" "another")
# Associative Arrays: ([key1]="value1" [key2]="value2 with spaces" )
print_value()
{
    local __input=${1:-}
    [[ -z ${__input} ]] && return 0

    # Special handling for packs, as long as their name is specified with a
    # '%' character in front of it
    if [[ "${__input:0:1}" == '%' ]] ; then
        pack_print "${__input:1}"
        return 0
    fi

    local decl=$(declare -p ${__input} 2>/dev/null || true)
    local val=$(echo "${decl}")
    val=${val#*=}

    # Deal with properly declared variables which are empty
    [[ -z ${val} ]] && val='""'

    # Special handling for arrays and associative arrays
    regex="declare -[aA]"
    [[ ${decl} =~ ${regex} ]] && { val=$(declare -p ${__input} | sed -e "s/[^=]*='(\(.*\))'/(\1)/" -e "s/[[[:digit:]]\+]=//g"); }

    echo -n "${val}"
}

# Log a list of variable in tag="value" form similar to our C++ logging idiom.
# This function is variadic (takes variable number of arguments) and will log
# the tag="value" for each of them. If multiple arguments are given, they will
# be separated by a space, as in: tag="value" tag2="value2" tag3="value3"
#
# This is implemented via calling print_value on each entry in the argument
# list. The one other really handy thing this does is understand our C++
# LVAL2 idiom where you want to log something with a _different_ key. So
# you can say nice things like:
#
# $(lval PWD=$(pwd) VARS=myuglylocalvariablename)
lval()
{
    local __lval_pre=""
    for __arg in "${@}"; do

        # Tag provided?
        local __arg_tag=${__arg%%=*}; [[ -z ${__arg_tag} ]] && __arg_tag=${__arg}
        local __arg_val=${__arg#*=}
        __arg_tag=${__arg_tag#%}
        __arg_val=$(print_value "${__arg_val}")

        echo -n "${__lval_pre}${__arg_tag}=${__arg_val}"
        __lval_pre=" "
    done
}


#-----------------------------------------------------------------------------
# FILESYSTEM HELPERS
#-----------------------------------------------------------------------------

pushd()
{
    builtin pushd "${@}" >/dev/null
}

popd()
{
    builtin popd "${@}" >/dev/null
}

# chmod + chown
echmodown()
{
    [[ $# -ge 3 ]] || die "echmodown requires 3 or more parameters. Called with $# parameters (chmodown $@)."
    $(opt_parse mode owner)

    chmod ${mode} $@
    chown ${owner} $@
}

# Recursively unmount the named directories and remove them (if they exist) then create new ones.
# NOTE: Unlike earlier implementations, this handles multiple arguments properly.
efreshdir()
{
    local mnt
    for mnt in "${@}"; do
        
        [[ -z "${mnt}" ]] && continue

        eunmount -a -r -d "${mnt}"
        mkdir -p ${mnt}
    
    done
}

# Copies the given file to *.bak if it doesn't already exist
ebackup()
{
    $(opt_parse src)

    [[ -e "${src}" && ! -e "${src}.bak" ]] && cp -arL "${src}" "${src}.bak" || true
}

erestore()
{
    $(opt_parse src)

    [[ -e "${src}.bak" ]] && mv "${src}.bak" "${src}"
}

# elogrotate rotates all the log files with a given basename similar to what
# happens with logrotate. It will always touch an empty non-versioned file
# just log logrotate.
#
# For example, if you pass in the pathname '/var/log/foo' and ask to keep a
# max of 5, it will do the following:
#   /var/log/foo.4 -> /var/log/foo.5
#   /var/log/foo.3 -> /var/log/foo.4
#   /var/log/foo.2 -> /var/log/foo.3
#   /var/log/foo.1 -> /var/log/foo.2
#   /var/log/foo   -> /var/log/foo.1
#   touch /var/log/foo
#
# OPTIONS
# -c=NUM
#   Maximum count of logs to keep (defaults to 5).
#
# -s=SIZE
#   Rotate logfiles if the size of most recent file is greater than SIZE.
#   SIZE can be expressed using syntax accepted by find(1) --size option.
#   Specifically, you add a suffix to denote the units:
#   c for bytes
#   w for two-byte words
#   k for kilobytes
#   M for Megabytes
#   G for gigabytes
#
elogrotate()
{
    $(opt_parse \
        ":count c=5 | Maximum number of logs to keep" \
        ":size s=0  | If specified, rotate logs at this specified size rather than each call to elogrotate" \
        "name       | Base name to use for the logfile.")

    # Ensure we don't try to rotate non-files
    [[ -f $(readlink -f "${name}") ]] 

    # Find log files by exactly this name that are of the size that should be rotated
    local files="$(find "$(dirname "${name}")" -maxdepth 1          \
                   -type f                                          \
                   -a -name "$(basename "${name}")"                 \
                   -a \( -size ${size} -o -size +${size} \) )"

    edebug "$(lval name files count size)"

    # If log file exists and is smaller than size threshold just return
    if [[ -z "${files}"  ]]; then
        return 0
    fi

    local log_idx next
    for (( log_idx=${count}; log_idx > 0; log_idx-- )); do
        next=$(( log_idx+1 ))
        [[ -e ${name}.${log_idx} ]] && mv -f ${name}.${log_idx} ${name}.${next}
    done

    # Move non-versioned one over and create empty new file
    [[ -e ${name} ]] && mv -f ${name} ${name}.1
    mkdir -p $(dirname ${name})
    touch ${name}

    # Remove any log files greater than our retention count
    find "$(dirname "${name}")" -maxdepth 1                 \
               -type f -name "$(basename "${name}")"        \
            -o -type f -name "$(basename "${name}").[0-9]*" \
        | sort --version-sort | awk "NR>${count}" | xargs rm -f
}

# elogfile provides the ability to duplicate the calling processes STDOUT
# and STDERR and send them both to a list of files while simultaneously displaying
# them to the console. Using this function is much preferred over manually doing this
# with tee and named pipe redirection as we take special care to ensure STDOUT and
# STDERR pipes are kept separate to avoid problems with logfiles getting truncated.
#
# OPTIONS
#
# -e=(0|1)
#   Redirect STDERR (defaults to 1)
#
# -o=(0|1)
#   Redirect STDOUT (defaults to 1)
#
# -r=NUM
#   Rotate logfile via elogrotate and keep maximum of NUM logs (defaults to 0
#   which is disabled).
#
# -s=SIZE
#   Rotate logfiles via elogrotate if the size of most recent file is greater
#   than SIZE. SIZE can be expressed using syntax accepted by find(1) --size
#   option. Specifically, you add a suffix to denote the units:
#   c for bytes, w for two-byte words, k for kilobytes, M for Megabytes, and
#   G for gigabytes.
#
# -t=(0|1)
#   Tail the output (defaults to 1)
#
# -m=(0|1)
#   Merge STDOUT and STDERR output streams into a single stream on STDOUT.
#
elogfile()
{
    $(opt_parse \
        "+stderr e=1       | Whether to redirect stderr to the logfile." \
        "+stdout o=1       | Whether to redirect stdout to the logfile." \
        ":rotate_count r=0 | When rotating log files, keep this number of log files." \
        ":rotate_size s=0  | Rotate log files when they reach this size. Units as accepted by find." \
        "+tail t=1         | Whether to continue to display output on local stdout and stderr." \
        "+merge m          | Whether to merge stdout and stderr into a single stream on stdout.")

    edebug "$(lval stdout stderr tail rotate_count rotate_size merge)"

    # Return if nothing to do
    if [[ ${stdout} -eq 0 && ${stderr} -eq 0 ]] || [[ -z "$*" ]]; then
        return 0
    fi

    # Rotate logs as necessary but only if they are regular files
    if [[ ${rotate_count} -gt 0 ]]; then
        local name
        for name in "${@}"; do
            [[ -f $(readlink -f "${name}") ]] || continue
            elogrotate -c=${rotate_count} -s=${rotate_size} "${name}"
        done
    fi

    # Setup EINTERACTIVE so our output formats properly even though stderr
    # won't be connected to a console anymore.
    if [[ ! -v EINTERACTIVE ]]; then
        [[ -t 2 ]] && export EINTERACTIVE=1 || export EINTERACTIVE=0
    fi

    # Export COLUMNS properly so that eend and eprogress output properly
    # even though stderr won't be connected to a console anymore.
    if [[ ! -v COLUMNS ]]; then
        export COLUMNS=$(tput cols)
    fi

    # Temporary directory to hold our FIFOs
    local tmpdir=$(mktemp --tmpdir --directory elogfile-XXXXXX)
    trap_add "rm --recursive --force ${tmpdir}"
    local pid_pipe="${tmpdir}/pids"
    mkfifo "${pid_pipe}"
 
    # Internal function to avoid code duplication in setting up the pipes
    # and redirection for stdout and stderr.
    elogfile_redirect()
    {
        $(opt_parse name)

        # If we're not redirecting the requested stream then just return success
        [[ ${!name} -eq 1 ]] || return 0

        # Create pipe
        local pipe="${tmpdir}/${name}"
        mkfifo "${pipe}"
        edebug "$(lval name pipe)"

        # Double fork so that the process doing the tee won't be one of our children
        # processes anymore. The purose of this is to ensure when we kill our process
        # tree that we won't kill the tee process. If we allowed tee to get killed
        # then any future output would HANG indefinitely because there wouldn't be
        # a reader attached to the pipe. Without a reader attached to the pipe all
        # writes block indefinitely. Since this is blocking in the kernel the process
        # essentially becomes unkillable once in this state.
        (
            disable_die_parent
            close_fds
            ( 
                # If we are in a cgroup, move the tee process out of that
                # cgroup so that we do not kill the tee.  It will nicely
                # terminate on its own once the process dies.
                if cgroup_supported && [[ ${EUID} -eq 0 && -n "$(cgroup_current)" ]] ; then
                    edebug "Moving tee process out of cgroup"
                    cgroup_move "/" ${BASHPID}
                fi

                # Ignore signals that came from the TTY for these special
                # processes.
                #
                # This will keep them alive long enough to display our error
                # output and such.  SIGPIPE will take care of them, and the
                # kill -9 below will make double sure.
                #
                trap "" ${TTY_SIGNALS[@]}
                echo "${BASHPID}" >${pid_pipe}

                # Past this point, we hand control to the tee processes which
                # we expect to die in their own time.  We no longer want to be
                # notified if something goes wrong (such as the tee being
                # killed)
                nodie_on_error

                if [[ ${tail} -eq 1 ]]; then
                    tee -a "${@}" <${pipe} >&$(get_stream_fd ${name}) 2>/dev/null
                else
                    tee -a "${@}" <${pipe} >/dev/null 2>&1
                fi
            ) &
        ) &

        # Grab the pid of the backgrounded pipe process and setup a trap to ensure
        # we kill it when we exit for any reason.
        local pid=$(cat ${pid_pipe})
        trap_add "kill -9 ${pid} 2>/dev/null || true"

        # Finally re-exec so that our output stream(s) are redirected to the pipe.
        # NOTE: If we're merging stdout+stderr we redirect both streams into the pipe
        if [[ ${merge} -eq 1 ]]; then
            eval "exec &>${pipe}"
        else
            eval "exec $(get_stream_fd ${name})>${pipe}"
        fi
    }

    # Redirect stdout and stderr as requested to the provided list of files.
    if [[ ${merge} -eq 1 ]]; then
        elogfile_redirect stdout "${@}"
    else
        elogfile_redirect stdout "${@}"
        elogfile_redirect stderr "${@}"
    fi
}

# Wrapper around computing the md5sum of a file to output just the filename
# instead of the full path to the filename. This is a departure from normal
# md5sum for good reason. If you download an md5 file with a path embedded into
# it then the md5sum can only be validated if you put it in the exact same path.
# This function will die on failure.
emd5sum()
{
    $(opt_parse path)

    local dname=$(dirname  "${path}")
    local fname=$(basename "${path}")

    pushd "${dname}"
    md5sum "${fname}"
    popd
}

# Wrapper around checking an md5sum file by pushd into the directory that contains
# the md5 file so that paths to the file don't affect the md5sum check. This
# assumes that the md5 file is a sibling next to the source file with the suffix
# 'md5'. This method will die on failure.
emd5sum_check()
{
    $(opt_parse path)

    local fname=$(basename "${path}")
    local dname=$(dirname  "${path}")

    pushd "${dname}"
    md5sum -c "${fname}.md5" | edebug
    popd
}

# Output checksum information for the given file to STDOUT. Specifically output
# the following:
#
# Filename=foo
# MD5=864ec6157c1eea88acfef44d0f34d219
# Size=2192793069
# SHA1=75490a32967169452c10c937784163126c4e9753
# SHA256=8297aefe5bb7319ab5827169fce2e664fe9cd7b88c9b31c40658ab55fcae3bfe
#
# Options:
#
# -p=PathToPrivateKey:  In addition to above checksums also output Base64 encoded
#    PGPSignature. The reason it is Base64 encoded is to properly deal with the
#    required header and footers before the actual signature body.
#
# -k=keyphrase: Optional keyphrase for the PGP Private Key
emetadata()
{
    $(opt_parse \
        ":private_key p | Also check the PGP signature based on this private key." \
        ":keyphrase k   | The keyphrase to use for the specified private key." \
        "path")
    [[ -e ${path} ]] || die "${path} does not exist"

    echo "Filename=$(basename ${path})"
    echo "Size=$(stat --printf="%s" "${path}")"

    # Now output MD5, SHA1, and SHA256
    local ctype
    for ctype in MD5 SHA1 SHA256; do
        echo "${ctype}=$(eval ${ctype,,}sum "${path}" | awk '{print $1}')"
    done

    # If PGP signature is NOT requested we can simply return
    [[ -n ${private_key} ]] || return 0

    # Import that into temporary secret keyring
    local keyring="" keyring_command=""
    keyring=$(mktemp --tmpdir emetadata-keyring-XXXXXX)
    keyring_command="--no-default-keyring --secret-keyring ${keyring}"
    trap_add "rm --force ${keyring}"
    gpg ${keyring_command} --import ${private_key} |& edebug

    # Get optional keyphrase
    local keyphrase_command=""
    [[ -z ${keyphrase} ]] || keyphrase_command="--batch --passphrase ${keyphrase}"

    # Output PGPSignature encoded in base64
    echo "PGPKey=$(basename ${private_key})"
    echo "PGPSignature=$(gpg --no-tty --yes ${keyring_command} --sign --detach-sign --armor ${keyphrase_command} --output - ${path} 2>/dev/null | base64 --wrap 0)"
}

# Validate an exiting source file against a companion *.meta file which contains
# various checksum fields. The list of checksums is optional but at present the
# supported fields we inspect are: Filename, Size, MD5, SHA1, SHA256, PGPSignature.
# 
# For each of the above fields, if they are present in the .meta file, validate 
# it against the source file. If any of them fail this function returns non-zero.
# If NO validators are present in the info file, this function returns non-zero.
#
# Options:
# -q=(0|1) Quiet mode (default=0)
# -p=PathToPublicKey: Use provided PGP Public Key for PGP validation (if PGPSignature
#                     is present in .meta file).
emetadata_check()
{
    $(opt_parse \
        "+quiet q      | If specified, produce no output.  Return code reflects whether check was good or bad." \
        ":public_key p | Path to a PGP public key that can be used to validate PGPSignature in .meta file."     \
        "path")

    local meta="${path}.meta"
    [[ -e ${path} ]] || die "${path} does not exist"
    [[ -e ${meta} ]] || die "${meta} does not exist"

    fail()
    {
        emsg "${COLOR_ERROR}" "   -" "ERROR" "$@"
        exit 1
    }

    local metapack="" digests=() validated=() expect="" actual="" ctype="" rc=0
    pack_set metapack $(cat "${meta}")
    local pgpsignature=$(pack_get metapack PGPSignature | base64 --decode)

    # Figure out what digests we're going to validate
    for ctype in Size MD5 SHA1 SHA256; do
        pack_contains metapack "${ctype}" && digests+=( "${ctype}" )
    done
    [[ -n ${public_key} && -n ${pgpsignature} ]] && digests+=( "PGP" )

    [[ ${quiet} -eq 1 ]] || eprogress "Verifying integrity of $(lval path metadata=digests)"
    pack_print metapack |& edebug
    local pids=()

    # Validate size
    if pack_contains metapack "Size"; then
        (
            expect=$(pack_get metapack Size)
            actual=$(stat --printf="%s" "${path}")
            [[ ${expect} -eq ${actual} ]] || fail "Size mismatch: $(lval path expect actual)"
        ) &

        pids+=( $! )
    fi

    # Now validated MD5, SHA1, and SHA256 (if present)
    for ctype in MD5 SHA1 SHA256; do
        if pack_contains metapack "${ctype}"; then
            (
                expect=$(pack_get metapack ${ctype})
                actual=$(eval ${ctype,,}sum ${path} | awk '{print $1}')
                [[ ${expect} == ${actual} ]] || fail "${ctype} mismatch: $(lval path expect actual)"
            ) &

            pids+=( $! )
        fi
    done

    # If Public Key was provied and PGPSignature is present validate PGP signature
    if [[ -n ${public_key} && -n ${pgpsignature} ]]; then
        (
            local keyring=$(mktemp --tmpdir emetadata-keyring-XXXXXX)
            trap_add "rm --force ${keyring}"
            gpg --no-default-keyring --secret-keyring ${keyring} --import ${public_key} |& edebug
            echo "${pgpsignature}" | gpg --verify - "${path}" |& edebug || fail "PGP verification failure: $(lval path)"
        ) &

        pids+=( $! )
    fi

    # Wait for all pids
    wait ${pids[@]} && rc=0 || rc=$?
    [[ ${quiet} -eq 1 ]] || eprogress_kill -r=${rc}
    return ${rc}
}

# Check if a directory is empty
directory_empty()
{
    $(opt_parse dir)
    ! find "${dir}" -mindepth 1 -print -quit | grep -q .
}

# Check if a directory is not empty
directory_not_empty()
{
    $(opt_parse dir)
    find "${dir}" -mindepth 1 -print -quit | grep -q .
}

#-----------------------------------------------------------------------------
# MOUNT / UMOUNT UTILS
#-----------------------------------------------------------------------------

# Helper method to take care of resolving a given path or mount point to its
# realpath as well as remove any errant '\040(deleted)' which may be suffixed
# on the path. This can happen if a device's source mount point is deleted
# while the destination path is still mounted.
emount_realpath()
{
    $(opt_parse path)
    path="${path//\\040\(deleted\)/}"
    echo -n "$(readlink -m ${path} 2>/dev/null || true)"
}

# Echo the emount regex for a given path
emount_regex()
{
    $(opt_parse path)
    echo -n "(^| )${path}(\\\\040\\(deleted\\))* "
}

# Echo the number of times a given directory is mounted.
emount_count()
{
    $(opt_parse path)
    path=$(emount_realpath ${path})
    local num_mounts=$(list_mounts | grep --count --perl-regexp "$(emount_regex ${path})" || true)
    echo -n ${num_mounts}
}

# Get the mount type of a given mount point.
emount_type()
{
    $(opt_parse path)
    path=$(emount_realpath ${path})
    list_mounts | grep --perl-regexp "$(emount_regex ${path})" | sort --unique | awk '{print $3}'
}

emounted()
{
    $(opt_parse path)
    path=$(emount_realpath ${path})
    [[ -z ${path} ]] && { edebug "Unable to resolve $(lval path) to check if mounted"; return 1; }

    [[ $(emount_count "${path}") -gt 0 ]]
}

# Bind mount $1 over the top of $2.  Ebindmount works to ensure that all of
# your mounts are private so that we don't see different behavior between
# systemd machines (where shared mounts are the default) and everywhere else
# (where private mounts are the default)
#
# Source and destination MUST be the first two parameters of this function.
# You may specify any other mount options after them.
#
ebindmount()
{
    $(opt_parse src dest)

    # The make-private commands are best effort.  We'll try to mark them as
    # private so that nothing, for example, inside a chroot can mess up the
    # machine outside that chroot.
    #
    # NOTE: Redirect all output from make-private to avoid spewing confusing messages
    # [efuncs.sh:2390:ebindmount] mount: /dest is not mountpoint or bad option
    mount --make-rprivate "${src}"  &> /dev/null || true
    emount --rbind "${@}" "${src}" "${dest}"
    mount --make-rprivate "${dest}" &> /dev/null || true
}

# Mount a filesystem.
#
# WARNING: Do not use opt_parse in this function as then we don't properly pass
#          the options into mount itself. Since this is just a passthrough
#          operation into mount you should see mount(8) manpage for usage.
emount()
{
    if edebug_enabled || [[ "${@}" =~ (^| )(-v|--verbose)( |$) ]]; then
        einfos "Mounting $@"
    fi
    
    mount "${@}"
}

eunmount_internal()
{
    $(opt_parse \
        "+verbose v | Verbose output.")

    local mnt
    for mnt in $@; do

        # Skip if not mounted.
        emounted "${mnt}" || continue

        local mnt_type=$(emount_type ${mnt})
        [[ ${verbose} -eq 1 ]] && einfo "Unmounting ${mnt} (${mnt_type})"
        
        # OVERLAYFS: Redirect unmount operation to overlayfs_unmount so all layers unmounted
        if [[ ${mnt_type} =~ overlay ]]; then
            overlayfs_unmount "${mnt}"
        else
            umount -l "$(emount_realpath "${mnt}")"
        fi
    done
}

# Recursively unmount a list of mount points. This function iterates over the 
# provided argument list and will unmount each provided mount point if it is
# mounted. It is not an error to try to unmount something which is already
# unmounted as we're already in the desired state and this is more useful in
# cleanup code. 
#
# OPTIONS:
# -r=0|1    Optionally recursively unmount everything beneath the mount point.
#           (defaults to 0)
#
# -d=0|1    Optionally delete the mount points (with -r this is recursive)
#           (defaults to 0).
#
# -a=0|1    Unmount ALL copies of requested mount points instead of a single
#           instance (defaults to 0).
#
# -v=0|1    Show verbose output (defaults to 0)
eunmount()
{
    $(opt_parse \
        "+verbose v   | Verbose output." \
        "+recursive r | Recursively unmount everything beneath mount points." \
        "+delete d    | Delete mount points after unmounting." \
        "+all a       | Unmount all copies of mount points instead of a single instance.")

    if edebug_enabled; then
        verbose=1
    fi

    local mnt
    for mnt in $@; do
      
        # If empty string just skip it
        [[ -z "${mnt}" ]] && continue

        edebug "Unmounting $(lval mnt recursive delete all)"
        
        # WHILE loop to **optionally** continue unmounting until no more matching
        # mounts are detected. The body of the while loop will break out when 
        # there are no more mounts to unmount. If -a=0 was passed in, then this
        # will always break after only a single iteration.
        while true; do

            # NOT RECURSIVE
            if [[ ${recursive} -eq 0 ]]; then

                # If it's not mounted break out of the loop otherwise unmount it.
                emounted "${mnt}" || break

                opt_forward eunmount_internal verbose -- "${mnt}"
        
            # RECURSIVE 
            else

                # If this path is directly mounted or anything BENEATH it is mounted then proceed
                local matches=( $(efindmnt "${mnt}" | sort --unique --reverse) )
                array_empty matches && break
                
                # Optionally log what is being unmounted
                local nmatches=$(echo "${matches[@]}" | wc -l)
                [[ ${verbose} -eq 1 ]] && einfo "Recursively unmounting ${mnt} (${nmatches})"
                edebug "$(lval matches nmatches)"

                # Lazily unmount all mounts
                local match
                for match in ${matches[@]}; do
                    opt_forward eunmount_internal verbose -- "${match}"
                done
            fi

            # If we're only unmounting a single instance BREAK out of the while loop.
            [[ ${all} -eq 0 ]] && break

        done

        # Optionally delete the mount point
        if [[ ${delete} -eq 1 && -e ${mnt} ]]; then

            [[ ${verbose} -eq 1 ]] && einfo "Deleting $(lval mnt recursive)"

            # Verify there are no mounts beneath this directory
            local mounts=( $(efindmnt "${mnt}") )
            if ! array_empty mounts; then
                die "Cannot remove $(lval directory=mnt) with mounted filesystems:\n$(array_join_nl mounts)"
            fi

            local rm_opts="--force"
            [[ ${recursive} -eq 1 ]] && rm_opts+=" --recursive"

            rm ${rm_opts} "${mnt}"
        fi

    done
}

# Platform agnostic mechanism for listing mounts.
list_mounts()
{
    if [[ ${__BU_OS} == Linux ]] ; then
        cat /proc/mounts

    elif [[ ${__BU_OS} == Darwin ]] ; then
        mount

    else
        die "Cannot list mounts for unsupported OS $(lval __BU_OS)"
    fi
}

# Recursively find all mount points beneath a given root.
# This is like findmnt with a few additional enhancements:
# (1) Automatically recusrive
# (2) findmnt doesn't find mount points beneath a non-root directory
efindmnt()
{
    $(opt_parse path)
    path=$(emount_realpath ${path})

    # First check if the requested path itself is mounted
    emounted "${path}" && echo "${path}" || true

    # Now look for anything beneath that directory
    list_mounts | grep --perl-regexp "(^| )${path}[/ ]" | awk '{print $2}' | sed '/^$/d' || true
}

#-----------------------------------------------------------------------------
# DISTRO-SPECIFIC
#-----------------------------------------------------------------------------

edistro()
{
    lsb_release -is
}

isubuntu()
{
    [[ "Ubuntu" == $(edistro) ]]
}

isgentoo()
{
    [[ "Gentoo" == $(edistro) ]]
}

isfedora()
{
    [[ "Fedora" == $(edistro) ]]
}

#-----------------------------------------------------------------------------
# COMPARISON FUNCTIONS
#-----------------------------------------------------------------------------

# Generic comparison function using awk which doesn't suffer from bash stupidity
# with regards to having to do use separate comparison operators for integers and
# strings and even worse being completely incapable of comparing floats.
compare()
{
    $(opt_parse "?lh" "op" "?rh")

    ## =~
    if [[ ${op} == "=~" ]]; then
        [[ ${lh} =~ ${rh} ]] && return 0
        return 1
    fi
    if [[ ${op} == "!~" ]]; then
        [[ ! ${lh} =~ ${rh} ]] && return 0
        return 1
    fi

    ## Escape a few special characters that trip up awk
    lh=${lh//[@()]/_}
    rh=${rh//[@()]/_}
    awk -v lh="${lh}" -v rh="${rh}" "BEGIN { if ( lh ${op} rh ) exit(0) ; else exit(1) ; }" && return 0 || return 1
}

# Specialized comparision helper to properly compare versions
compare_version()
{
    local lh=${1}
    local op=${2}
    local rh=${3}

    ## EQUALS
    [[ ${op} == "!=" ]] && [[ ${lh} != ${rh} ]] && return 0
    [[ ${op} == "==" || ${op} == "<=" || ${op} == ">=" ]] && [[ ${lh} == ${rh} ]] && return 0
    [[ ${op} == "<"  || ${op} == ">" ]] && [[ ${lh} == ${rh} ]] && return 1
    op=${op/<=/<}
    op=${op/>=/>}

    [[ ${op} == "<"  ]] && [[ ${lh} == $(printf "${lh}\n${rh}" | sort -V | head -n1) ]] && return 0
    [[ ${op} == ">"  ]] && [[ ${lh} == $(printf "${lh}\n${rh}" | sort -V | tail -n1) ]] && return 0

    return 1
}

#-----------------------------------------------------------------------------
# ARGUMENT HELPERS
#-----------------------------------------------------------------------------

# Check to ensure all the provided arguments are non-empty
argcheck()
{
    local _argcheck_arg
    for _argcheck_arg in $@; do
        [[ -z "${!_argcheck_arg:-}" ]] && die "Missing argument '${_argcheck_arg}'" || true
    done
}

: <<'END'
opt_parse
============

Terminology
-----------

First a quick bit of background on the terminology used for bashutils parameter
parsing.  Different well-meaning folks use different terms for the same things,
but these are the definitions as they apply within bashutils documentation.

First, here's an example command line you might use to search for lines that do
not contain "alpha" within a file named "somefile".

    grep --word-regexp -v alpha somefile

In this case --word-regexp and -v are _options_.  That is to say, they're
optional flags to the command whose names start with hyphens.  Options follow
the GNU style in that single character options have one hyphen before their
name, while long options have two hyphens before their name.

Typically, a single functionality within a tool can be controlled by the
caller's choice of either a long option or a short option.  For instance, grep
considers -v and --invert to be equivalent options.

_Arguments_ are the positional things that must occur on the command line
following all of the options.  If you're ever concerned that there could be
ambiguity, you can explicitly separate the two with a pair of hyphens on their
own.  The following is equivalent to the first example.

    grep --word-regex -v -- alpha somefile


To add to the confusing terminology, some options accept their own arguments.
For example, grep can limit the number of matches with the --max-count option.
This will print the first line in somefile that matches alpha.

    grep --max-count 1 alpha somefile.

So we say that if --max-count is specified, it requires an _argument_.


Arguments
---------

The simplest functions frequently just take an argument or two.  We discovered
early in the life of bashutils a frequent pattern:

    foo()
    {
        local arg1=$1
        local arg2=$2
        shift 2
        argcheck arg1 arg2
    
        # Do some stuff here with ${arg1} and ${arg2}
    }

But we wanted to make it more concise. Enter opt_parse.  This is equivalent
to those four lines of argument handling code in `foo()`.  That is, it creates
two local variables (`arg1` and `arg2`) and then verifies that both of them are
non-empty by calling `argcheck` on them.

    $(opt_parse arg1 arg2)

As a best practice, we suggest documenting said arguments within the opt_parse
declaration.  Note that each quoted string passed to opt_parse creates a single
argument or option.  Pipe characters separate sections, and whitespace near the
pipe characters is discarded. This, too, is equivalent.

    $(opt_parse \
        "arg1 | This is what arg1 means." \
        "arg2 | This is what arg2 means.")

Note that `argcheck` in the original example ensures that your function will blow
up if either `arg1` or `arg2` is empty.  This is pretty handy for bash functions,
but not always what you want.  You can specify that a given argument _may_ be
empty by putting a question mark before its name.

    $(opt_parse \
        "arg1  | This argument must contain at least a character." \
        "?arg2 | This argument may be empty.")

You may also specify a default value for an argument.

    $(opt_parse \
        "file=filename.json | This argument defaults to filename.json")

Note that having a default value is a separate concern from the check that
verifies that the value is non-empty.

    $(opt_parse \
        "a    | Default is empty, blows up if it is called with no value" \
        "?b   | Default is empty, doesn't mind being called with no value" \
        "c=1  | Default is 1, if called with '', will blow up" \
        "?d=1 | Default is 1, will still be happy if '' is specified")


Options
--------

Options are specified in a similar form to arguments.  The biggest difference
is that options may have multiple names.  Both short and long options are
supported.

    $(opt_parse \
        "+word_regex w | if specified, match only complete words" \
        "+invert v     | if specified, match only lines that do NOT contain the regex.")

    [[ ${word_regex} -eq 1 ]] && # do stuff for words
    [[ ${invert}     -eq 1 ]] && # do stuff for inverting

 
As with arguments, `opt_parse` creates a local variable for each option.  The
name of that variable is always the _first_ name given.

This means that -w and --word-regex are equivalent, and so are --invert and -v.
Note that there's a translation here in the name of the option. By convention,
words are separated with hyphens in option names, but hyphens are not allowed
to be characters in bash variables, so we use underscores in the variable name
and automatically translate that to a hyphen in the option name.

At present, bashutils supports two different types of options: boolean and
string.


Boolean Options
---------------

Word_regex and invert in the example above are both boolean options.  That is,
they're either on the command line (in which case opt_parse assigns 1 to the
variable) or not on the command line (in which case opt_parse assigns 0 to the
variable).

You can also be explicit about the value you'd like to choose for an option by
specifying =0 or =1 at the end of the option.  For instance, these are
equivalent and would enable the word_regex option and disable the invert
option.

    cmd --invert=0 --word-regex=1
    cmd -i=0 -w=1

Note that these two options are considered to be boolean.  Either they were
specified on the command line or they were not.  When specified, the value of
the variable will be 1, when not specified it will be zero.

The long option versions of boolean options also implicitly support a negation
by prepending the option name with no-.  For example, this is also equivalent
to the above examples.

    cmd --no-invert --word-regex


String Options
--------------

Opt_parse also supports options whose value is a string.  When specified on the
command line, these _require_ an argument, even if it is an empty string.  In
order to get a string option, you prepend its name with a colon character.

    func()
    {
        $(opt_parse ":string s")
        echo "STRING: X${string}X"
    }

    func --string "alpha"
    # output -- STRING: XalphaX
    func --string ""
    # output -- STRING: XX

    func --string=alpha
    # output -- STRING: XalphaX
    func --string=
    # output -- STRING: XX


Default Values
--------------

By default, the value of boolean options is false and string options are an
empty string, but you can specify a default in your definition just as you
would with arguments.

    $(opt_parse \
        "+boolean b=1        | Boolean option that defaults to true" \
        ":string s=something | String option that defaults to "something")

END
opt_parse()
{
    # An interesting but non-obvious trick is being played here.
    # Opt_parse_setup is called during the opt_parse call, and it sets up some
    # variables (such as __BU_OPT and __BU_ARG).  Since they're already
    # created, when we eval the calls to opt_parse_options and
    # opt_parse_arguments, we can modify those variables and pass them amongst
    # the internals of opt_parse.  This makes it easier to write the more
    # complicated stuff in literal functions.  Then we can limit the size of
    # the blocks of code that have to be "echo"-ed out for the caller to
    # execute.  Much simpler to get them to call a function (but of course that
    # function can't create local variables for them).
    echo "eval "
    opt_parse_setup "${@}"

    # __BU_FULL_ARGS is the list of arguments as initially passed to
    # opt_parse. Opt_parse_options will modifiy __BU_ARGS to be whatever was
    # left to be processed after it is finished. Note: here $@ is quoted so it
    # refers to the caller's arguments
    echo 'declare __BU_FULL_ARGS=("$@") ; '
    echo 'declare __BU_ARGS=("$@") ; '
    echo "opt_parse_options ; "

    # Process options
    echo 'declare opt ; '
    echo 'if [[ ${#__BU_OPT[@]} -gt 0 ]] ; then '
        echo 'for opt in "${!__BU_OPT[@]}" ; do'
            echo 'declare "${opt//-/_}=${__BU_OPT[$opt]}" ; '
        echo 'done ; '
    echo 'fi ; '

    # Process arguments
    echo 'opt_parse_arguments ; '
    echo 'if [[ ${#__BU_ARG[@]} -gt 0 ]] ; then '
        echo 'for index in "${!__BU_ARG[@]}" ; do '
            echo '[[ -n ${index} ]] || continue ; '
            echo '[[ ${__BU_ARG_NAMES[$index]} != _ ]] && declare "${__BU_ARG_NAMES[$index]}=${__BU_ARG[$index]}" ; '
        echo 'done ; '
    echo 'fi ; '
    echo 'argcheck "${__BU_ARG_REQUIRED[@]:-}" ; '
    echo '[[ ${#__BU_ARGS[@]:-} -gt 0 ]] && set -- "${__BU_ARGS[@]}" || set -- ; '
}

opt_parse_setup()
{
    local opt_cmd="__BU_OPT=( "
    local opt_regex_cmd="__BU_OPT_REGEX=( "
    local opt_type_cmd="__BU_OPT_TYPE=( "
    local arg_cmd="__BU_ARG=( "
    local arg_names_cmd="__BU_ARG_NAMES=( "
    local arg_required_cmd="__BU_ARG_REQUIRED=( "

    while (( $# )) ; do
        local complete_arg=$1 ; shift

        # Arguments to opt_parse may contain multiple chunks of data, separated
        # by pipe characters.
        if [[ "${complete_arg}" =~ ^([^|]*)(\|([^|]*))?$ ]] ; then
            local opt_definition=$(string_trim "${BASH_REMATCH[1]}")
            local docstring=$(string_trim "${BASH_REMATCH[3]}")

        else
            die "Invalid option declaration: ${complete_arg}"
        fi

        [[ -n ${opt_definition} ]] || die "${FUNCNAME[2]}: invalid opt_parse syntax.  Option definition is empty."

        # Make sure this option looks right
        [[ ${opt_definition} =~ ([+:?])?([^=]+)(=.*)? ]]

        # TYPE is the first character of the definition
        local opt_type_char=${BASH_REMATCH[1]}

        # NAMEs come next, whitespace separated up until the equal sign, if any
        local all_names=${BASH_REMATCH[2]}
        all_names=${all_names%%+([[:space:]])}

        # DEFAULT VALUE is everything after the equal sign, excluding trailing
        # whitespace
        local default=${BASH_REMATCH[3]#=}
        default=${default%%+([[:space:]])}

        # CANONICAL NAME is the first name specified
        local canonical=${all_names%%[ 	]*}

        # It must be non-empty and must not contain hyphens (because hyphens
        # are not allowed in bash variable names)
        [[ -n ${canonical} ]]      || die "${FUNCNAME[2]}: invalid opt_parse syntax.  Name is empty."
        [[ ! ${canonical} = *-* ]] || die "${FUNCNAME[2]}: name ${canonical} is not allowed to contain hyphens."


        # OPTIONS
        if [[ ${opt_type_char} == ":" || ${opt_type_char} == "+" ]] ; then

            local name_regex=^\(${all_names//+( )/|}\)$

            if [[ ${opt_type_char} == ":" ]] ; then
                opt_type="string"

            elif [[ ${opt_type_char} == "+" ]] ; then
                opt_type="boolean"

                # Boolean options implicitly get a version whose name starts with
                # no- that is a negation of the option.  Adjust the name regex.
                name_regex=${name_regex/^/^\(no_\)?}

                # And forbid double-negative options
                [[ ! ${canonical} = no_* ]] || die "${FUNCNAME[2]}: names of boolean options may not begin with no_ because no_<option> is implicitly created."

                : ${default:=0}

                if [[ ${default} != 0 && ${default} != 1 ]] ; then
                    die "${FUNCNAME[2]}: boolean option has invalid default of ${default}"
                fi

            fi

            # Now that they're all computed, add them to the command that will generate associative arrays
            opt_cmd+="[${canonical}]='${default}' "
            opt_regex_cmd+="[${canonical}]='${name_regex}' "
            opt_type_cmd+="[${canonical}]='${opt_type}' "


        # ARGUMENTS
        else
            [[ ${all_names} != *[[:space:]]* ]] || die "${FUNCNAME[2]}: arguments can only have a single name, but ${all_names} was specified."

            arg_cmd+="'${default}' "
            arg_names_cmd+="'${canonical}' "
            [[ ${opt_type_char} != "?" ]] && arg_required_cmd+="'${canonical}' "
        fi

    done

    opt_cmd+=")"
    opt_regex_cmd+=")"
    opt_type_cmd+=")"
    arg_cmd+=")"
    arg_names_cmd+=")"
    arg_required_cmd+=")"

    printf "declare -A %s %s %s ; " "${opt_cmd}" "${opt_regex_cmd}" "${opt_type_cmd}" 
    printf "declare %s %s %s ; " "${arg_cmd}" "${arg_names_cmd}" "${arg_required_cmd}"
}

opt_parse_options()
{
    # No options?  Nothing to do.
    if [[ ${#__BU_FULL_ARGS[@]:-} -eq 0 ]] ; then
        return 0
    fi

    set -- "${__BU_FULL_ARGS[@]}"

    local shift_count=0
    while (( $# )) ; do
        case "$1" in
            --)
                (( shift_count += 1 ))
                break
                ;;
            --*)
                # Drop the initial hyphens, grab the option name and capture
                # "=value" from the end if there is one
                [[ $1 =~ ^--([^=]+)(=(.*))?$ ]]
                local long_opt=${BASH_REMATCH[1]}
                local has_arg=${BASH_REMATCH[2]}
                local opt_arg=${BASH_REMATCH[3]}

                # Find the internal name of the long option (using its name
                # with underscores, which is how we treat it throughout the
                # opt_parse code rather than with hyphens which is how it
                # should be specified on the command line)
                local canonical=$(opt_parse_find_canonical ${long_opt//-/_})
                [[ -n ${canonical} ]] || die "${FUNCNAME[1]}: unexpected option --${long_opt}"

                if [[ ${__BU_OPT_TYPE[$canonical]} == "string" ]] ; then
                    # If it wasn't specified after an equal sign, instead grab
                    # the next argument off the command line
                    if [[ -z ${has_arg} ]] ; then
                        [[ $# -ge 2 ]] || die "${FUNCNAME[1]}: option --${long_opt} requires an argument but didn't receive one."
                        opt_arg=$2
                        shift && (( shift_count += 1 ))
                    fi

                    __BU_OPT[$canonical]=${opt_arg}

                elif [[ ${__BU_OPT_TYPE[$canonical]} == "boolean" ]] ; then

                    # The value that will get assigned to this boolean option
                    local value=1
                    if [[ -n ${has_arg} ]] ; then
                        value=${opt_arg}
                    fi

                    # Negate the value it was if the option starts with no
                    if [[ ${long_opt} = no[-_]* ]] ; then
                        if [[ ${value} -eq 1 ]] ; then
                            value=0
                        else
                            value=1
                        fi
                    fi

                    __BU_OPT[$canonical]=${value}
                else
                    die "${FUNCNAME[1]}: option --${long_opt} has an invalid type ${__BU_OPT_TYPE[$canonical]}"
                fi
                ;;

            -*)
                # Drop the initial hyphen, grab the single-character options as
                # a blob, and capture an "=value" if there is one.
                [[ $1 =~ ^-([^=]+)(=(.*))?$ ]]
                local short_opts=${BASH_REMATCH[1]}
                local has_arg=${BASH_REMATCH[2]}
                local opt_arg=${BASH_REMATCH[3]}

                # Iterate over the single character options except the last,
                # handling each in turn
                local index
                for (( index = 0 ; index < ${#short_opts} - 1; index++ )) ; do
                    local char=${short_opts:$index:1}
                    local canonical=$(opt_parse_find_canonical ${char})
                    [[ -n ${canonical} ]] || die "${FUNCNAME[1]}: unexpected option --${long_opt}"

                    if [[ ${__BU_OPT_TYPE[$canonical]} == "string" ]] ; then
                        die "${FUNCNAME[1]}: option -${char} requires an argument but didn't receive one."
                    fi

                    __BU_OPT[$canonical]=1
                done

                # Handle the last one separately, because it might have an argument.
                local char=${short_opts:$index}
                local canonical=$(opt_parse_find_canonical ${char})
                [[ -n ${canonical} ]] || die "${FUNCNAME[1]}: unexpected option -${char}"

                # If it expects an argument, make sure it has one and use it.
                if [[ ${__BU_OPT_TYPE[$canonical]} == "string" ]] ; then

                    # If it wasn't specified after an equal sign, instead grab
                    # the next argument off the command line
                    if [[ -z ${has_arg} ]] ; then
                        [[ $# -ge 2 ]] || die "${FUNCNAME[1]}: option -${char} requires an argument but didn't receive one."

                        opt_arg=$2
                        shift && (( shift_count += 1 ))
                    fi
                    __BU_OPT[$canonical]=${opt_arg}

                elif [[ ${__BU_OPT_TYPE[$canonical]} == "boolean" ]] ; then

                    # Boolean options may optionally be specified a value via
                    # -b=(0|1).  Take it if it's there.
                    if [[ -n ${has_arg} ]] ; then
                        __BU_OPT[$canonical]=${opt_arg}
                    else
                        __BU_OPT[$canonical]=1
                    fi

                else
                    die "${FUNCNAME[1]}: option -${char} has an invalid type ${__BU_OPT_TYPE[$canonical]}"
                fi
                ;;
            *)
                break
                ;;
        esac

        # Make sure that the value chosen for boolean options is either 0 or 1
        if [[ ${__BU_OPT_TYPE[$canonical]} == "boolean" \
            && ${__BU_OPT[$canonical]} != 1 && ${__BU_OPT[$canonical]} != 0 ]] ; then
                die "${FUNCNAME[1]}: option $canonical can only be 0 or 1 but was ${__BU_OPT[$canonical]}."
        fi

        # Move on to the next item, recognizing that an option may have consumed the last one
        shift && (( shift_count += 1 )) || break
    done

    # Assign to the __BU_ARGS array so that the opt_parse macro can make its
    # contents the remaining set of arguments in the calling function.
    if [[ ${#__BU_ARGS[@]:-} -gt 0 ]] ; then
        __BU_ARGS=( "${__BU_ARGS[@]:$shift_count}" )
    fi
}

opt_parse_find_canonical()
{
    for option in "${!__BU_OPT[@]}" ; do
        if [[ ${1} =~ ${__BU_OPT_REGEX[$option]} ]] ; then
            echo "${option}"
            return 0
        fi
    done
}

opt_parse_arguments()
{
    if [[ ${#__BU_ARGS[@]} -gt 0 ]] ; then

        # Take the arguments that already have options stripped out of them and
        # treat them as parameters to this function.
        set -- "${__BU_ARGS[@]}"

        # Iterate over the (indexes of the) positional arguments
        local index arg_name shift_count=0
        for index in "${!__BU_ARG_NAMES[@]}" ; do

            # If there are no more arguments to process, stop
            [[ $# -gt 0 ]] || break

            #  Put the next argument from the command line into the next argument
            #  value slot
            __BU_ARG[$index]=$1
            shift && (( shift_count += 1 ))
        done

        __BU_ARGS=( "${__BU_ARGS[@]:$shift_count}" )
    fi
}

opt_dump()
{
    for option in "${!__BU_OPT[@]}" ; do
        echo -n "${option}=\"${__BU_OPT[$option]}\" "
    done
    echo
}

: <<'END'
opt_forward
===========

When you have a bunch of options that were passed into a function that wants to
simply forward them into an internal function, it can be a little tedious to
make the call to that internal function because you have to repeat all of the
options and then read the value that the option of the same name was stored
into.  For instance look at the foo_internal call here, assuming it takes an
identical set of options as foo.

    foo()
    {
        $(opt_parse "+a" "+b" "+c")

        # Do some stuff then call internal function to handle more details
        foo_internal -a="${a}" -b="${b}" -c="${c}"

    }

Of course, that only gets worse as you have more or as the names of your
options get longer.  And if you quote it incorrectly, it will continue to work
until one of your options contains something weird like whitespace in which
case it will probably fail subtly.

`Opt_forward` exists simply to make this easier.  It knows how to forward
options that were parsed by `opt_parse` to another function, quoting correctly.
You can use it like this

    opt_forward <command> <names of options to forward>+ [-- [other args]]

To cover the example case, you'd call it like this:

    opt_forward foo_internal a b c

Or, if you needed to pass additional things to `foo_internal`, like this:

    opt_forward foo_internal a b c -- additional things

You may find that the option has a different name in the function you'd like to
forward to.  You can specify this by adding a colon followed by the name of
the option in the function you're asking `opt_forward` to call.  For instance,
if the function you wanted to _call_ has options named X, Y, and Z.

    opt_forward foo_internal a:X b:Y c:Z

Note that `opt_forward` is forgiving about the fact that we use underscores in
variable names but options support hyphens.  You can pass option names in
either form to `opt_forward`.
END
opt_forward()
{
    [[ $# -gt 0 ]] || die "Must specify at least a command to run and an option to forward."
    local cmd=$1 ; shift

    local args=( )

    while [[ $# -gt 0 ]] ; do
        local __option=$1 ; shift

        # Keep processing things until --.  If we encounter that it means the
        # caller wants to present more arguments or options that are not
        # forwarded
        [[ ${__option} == "--" ]] && break


        # If there's no colon in the option name to be forwarded, then assume
        # the option names match in this function and the other.  If there IS
        # one, then use the first portion to be the name of the local variable,
        # and the part after the colon to be the name of the option in the
        # called function.
        local __local_name=${__option%%:*}
        local __called_name=${__option##*:}
        : ${__called_name:=__local_name}

        # Use only underscores in variable names and only hyphens in option
        # names
        __called_name=${__called_name//_/-}
        __local_name=${__local_name//-/_}

        args+=("--${__called_name//-/_}=${!__local_name}")
    done

    while [[ $# -gt 0 ]] ; do
        args+=("$1")
        shift
    done

    quote_eval ${cmd} "${args[@]}"
}


#-----------------------------------------------------------------------------
# MISC HELPERS
#-----------------------------------------------------------------------------

# save_function is used to safe off the contents of a previously declared
# function into ${1}_real to aid in overridding a function or altering
# it's behavior.
save_function()
{
    local orig=$(declare -f $1)
    local new="${1}_real${orig#$1}"
    eval "${new}" &>/dev/null
}

# override_function is a more powerful version of save_function in that it will
# still save off the contents of a previously declared function into ${1}_real
# but it will also define a new function with the provided body ${2} and
# mark this new function as readonly so that it cannot be overridden later.
# If you call override_function multiple times we have to ensure it's idempotent.
# The danger here is in calling save_function multiple tiems as it may cause
# infinite recursion. So this guards against saving off the same function multiple
# times.
override_function()
{
    $(opt_parse func body)

    # Don't save the function off it already exists to avoid infinite recursion
    declare -f "${func}_real" >/dev/null || save_function ${func}

    # If the function has already been overridden don't fail so long as it's
    # IDENTICAL to what we've already defined it as. This allows more graceful
    # handling of sourcing a file multiple times with an override in it as it'll
    # be identical. Normally the eval below would produce an error with set -e
    # enabled.
    local expected="${func} () ${body}"$'\n'"declare -rf ${func}"
    local actual="$(declare -pf ${func} 2>/dev/null || true)"
    [[ ${expected} == ${actual} ]] && return 0 || true

    eval "${expected}" &>/dev/null
    eval "declare -rf ${func}" &>/dev/null
}

numcores()
{
    [[ -e /proc/cpuinfo ]] || die "/proc/cpuinfo does not exist"

    echo $(cat /proc/cpuinfo | grep "processor" | wc -l)
}

# Internal only efetch function which fetches an individual file using curl.
# This will show an eprogress ticker and then kill the ticker with either
# success or failure indicated. The return value is then returned to the
# caller for handling.
efetch_internal()
{
    $(opt_parse url dst)
    local timecond=""
    [[ -f ${dst} ]] && timecond="--time-cond ${dst}"

    eprogress "Fetching $(lval url dst)"
    $(tryrc curl "${url}" ${timecond} --output "${dst}" --location --fail --silent --show-error --insecure)
    eprogress_kill -r=${rc}

    return ${rc}
}

# Fetch a provided URL to an optional destination path via efetch_internal. 
# This function can also optionally validate the fetched data against various
# companion files which contain metadata for file fetching. If validation is
# requested and the validation fails then all temporary files fetched are
# removed.
#
# Options:
# -m=(0|1) Fetch companion .md5 file and validate fetched file's MD5 matches.
# -M=(0|1) Fetch companion .meta file and validate metadata fields using emetadata_check.
# -q=(0|1) Quiet mode (disable eprogress and other info messages)
efetch()
{
    $(opt_parse \
        "+md5 m   | Fetch companion .md5 file and validate fetched file's MD5 matches." \
        "+meta M  | Fetch companion .meta file and validate metadata fields using emetadata_check." \
        "+quiet q | Quiet mode.  (Disable eprogress and other info messages)" \
        "url      | URL from which efetch should pull data." \
        "dst=/tmp | Destination directory.")

    [[ -d ${dst} ]] && dst+="/$(basename ${url})"
    
    # Companion files we may fetch
    local md5_file="${dst}.md5"
    local meta_file="${dst}.meta"

    try
    {
        # Optionally suppress all output from this subshell
        [[ ${quiet} -eq 1 ]] && exec &>/dev/null

        ## If requested, fetch MD5 file
        if [[ ${md5} -eq 1 ]] ; then

            efetch_internal "${url}.md5" "${md5_file}"
            efetch_internal "${url}"     "${dst}"

            # Verify MD5
            einfos "Verifying MD5 $(lval dst md5_file)"

            local dst_dname=$(dirname  "${dst}")
            local dst_fname=$(basename "${dst}")
            local md5_dname=$(dirname  "${md5_file}")
            local md5_fname=$(basename "${md5_file}")

            cd "${dst_dname}"

            # If the requested destination was different than what was originally in the MD5 it will fail.
            # Or if the md5sum file was generated with a different path in it it will fail. This just
            # sanititizes it to have the current working directory and the name of the file we downloaded to.
            sed -i "s|\(^[^#]\+\s\+\)\S\+|\1${dst_fname}|" "${md5_fname}"

            # Now we can perform the check
            md5sum --check "${md5_fname}" >/dev/null

        ## If requested fetch *.meta file and validate using contained fields
        elif [[ ${meta} -eq 1 ]]; then

            efetch_internal "${url}.meta" "${meta_file}"
            efetch_internal "${url}"      "${dst}"
            emetadata_check "${dst}"
        
        ## BASIC file fetching only
        else
            efetch_internal "${url}" "${dst}"
        fi
    
        einfos "Successfully fetched $(lval url dst)"
    }
    catch
    {
        local rc=$?
        edebug "Removing $(lval dst md5_file meta_file rc)"
        rm -rf "${dst}" "${md5_file}" "${meta_file}"
        return ${rc}
    }
}

# Netselect chooses the host that responds most quickly and reliably among a
# list of specified IP addresses or hostnames.  It does this by pinging each
# and looking for response times as well as packet drops.
netselect()
{
    $(opt_parse \
        "+quiet q=0 | Don't display progress information, just print the chosen host on stdout." \
        ":count c   | Number of times to ping.  Defaults to 10 for multiple hosts or 1 for a single host.")

    local hosts=$@; argcheck hosts
    [[ ${quiet} -eq 1 ]] || eprogress "Finding host with lowest latency $(lval hosts)"

    [[ $# -eq 1 ]] && : ${count:=1} || : ${count:=10}

    declare -a results sorted rows

    for h in ${hosts}; do
        local entry=$(ping -c${count} -w5 -q $h 2>/dev/null | \
            awk '/packet loss/ {loss=$6}
                 /min\/avg\/max/ {
                    split($4,stats,"/")
                    printf("%f|%f|%s|%f", stats[2], stats[4], loss, (stats[2] * stats[4]) * (loss + 1))
                }' || true)

        results+=("${h}|${entry}")
    done

    array_init_nl sorted "$(printf '%s\n' "${results[@]}" | sort -t\| -k5 -n)"
    array_init_nl rows "Server|Latency|Jitter|Loss|Score"

    for entry in ${sorted[@]} ; do
        array_init parts "${entry}" "|"
        array_add_nl rows "${parts[0]}|${parts[1]}|${parts[2]}|${parts[3]}|${parts[4]}"
    done

    local best=$(echo "${sorted[0]}" | cut -d\| -f1)

    if [[ ${quiet} -ne 1 ]] ; then
        eprogress_kill

        ## SHOW ALL RESULTS ##
        einfos "All results:"
        etable ${rows[@]} >&2

        einfos "Best host=[${best}]"
    fi

    echo -en "${best}"
}

## etimeout
## ========
##
## `etimeout` will execute an arbitrary bash command for you, but will only let
## it use up the amount of time (i.e. the "timeout") you specify.
##
## If the command tries to take longer than that amount of time, it will be
## killed and etimeout will return 124.  Otherwise, etimeout will return the
## value that your called command returned.
##
## All arguments to `etimeout` (i.e. everything that isn't an option, or
## everything after --) is assumed to be part of the command to execute.
## `Etimeout` is careful to retain your quoting.
##
etimeout()
{
    $(opt_parse \
        ":signal sig s=TERM | First signal to send if the process doesn't complete in time.  KILL will still be sent later if it's not dead." \
        ":timeout t         | After this duration, command will be killed if it hasn't already completed.")

    argcheck timeout

    # Background the command to be run
    local start=${SECONDS}
    local cmd=("${@}")

    # If no command to execute just return success immediately
    if [[ -z "${cmd[@]:-}" ]]; then
        return 0
    fi

    #-------------------------------------------------------------------------
    # COMMAND TO EVAL
    local rc=""
    (
        disable_die_parent
        quote_eval "${cmd[@]}"
        local rc=$?
    ) &
    local pid=$!
    edebug "Executing $(lval cmd timeout signal pid)"
 
    #-------------------------------------------------------------------------
    # WATCHER
    #
    # Launch a background "wathcher" process that is simply waiting for the
    # timeout timer to expire.  If it does, it will kill the original command.
    (
        disable_die_parent
        close_fds

        # Wait for the timeout to elapse
        sleep ${timeout}

        # Upon getting here, we know that either 1) the timeout elapsed or 2)
        # our sleep process was killed.
        #
        # We can check to see if anything is still running, though, because we
        # know the command's PID.  If it's gone, it must've finished and we can exit
        #
        local pre_pids=( $(process_tree ${pid}) )
        if array_empty pre_pids ; then
            exit 0
        else
            # Since it did not exit and we must've completed our timeout sleep,
            # the command must've outlived its usefulness.  Do away with it.
            ekilltree -s=${signal} -k=2s ${pid}

            # Return sentinel 124 value to let the main process know that we
            # encountered a timeout.
            exit 124
        fi

    ) &>/dev/null &

    #-------------------------------------------------------------------------
    # HANDLE RESULTS
    {
        # Now we need to wait for the original process to finish.  We know that
        # it will _either_ finish because it completes normally or because the
        # watcher will kill it.
        #
        # Note that we do _not_ know which.  The return code we get from that
        # process might be its normal rc, or it might be the rc that it got
        # because it was killed by the watcher.
        local watcher=$!
        wait ${pid} && rc=0 || rc=$?

        # Once the above has completed, we know that the watcher is no longer
        # needed, so we can kill it, too.
        ekilltree -s=TERM ${watcher}

        # We need the return code from the watcher process to determine what
        # happened.  If it returned our sentinel value (124), then we know that
        # it determined there was a timeout.  Otherwise, we know that the
        # original command returned on its own.
        wait ${watcher} && watcher_rc=0 || watcher_rc=$?

        local stop=${SECONDS}
        local seconds=$(( ${stop} - ${start} ))

    } &>/dev/null
    
    # Now if we got that sentinel 124 value, we can report the timeout
    if [[ ${watcher_rc} -eq 124 ]] ; then
        edebug "Timeout $(lval cmd rc seconds timeout signal pid)"
        return 124
    else
        # Otherwise, we report the value reported by the original command
        return ${rc}
    fi
}

# eretry executes arbitrary shell commands for you wrapped in a call to etimeout
# and retrying up to a specified count. If the command eventually completes
# successfully eretry will return 0. If the command never completes successfully
# but continues to fail every time the return code from eretry will be the failing
# command's return code. If the command is prematurely terminated via etimeout the
# return code from eretry will be 124.
#
# OPTIONS:
#
# -d=DELAY. Amount of time to delay (sleep) after failed attempts before retrying.
#   Note that this value can accept sub-second values, just as the sleep
#   command does.  This parameter will be passed directly to sleep, so you can
#   specify any arguments it accepts such as .01s, 5m, or 3d.
#
# -e=<space separated list of numbers>
#   Any of the exit codes specified in this list will cause eretry to stop
#   retrying. If eretry receives one of these codes, it will immediately stop
#   retrying and return that exit code.  By default, only a zero return code
#   will cause eretry to stop.  If you specify -e, you should consider whether
#   you want to include 0 in the list.
#
# -r=RETRIES
#   Command will be attempted RETRIES times total. If no options are provided to
#   eretry it will use a default retry limit of 5.
#
# -s=SIGNAL=<signal name or number>     e.g. SIGNAL=2 or SIGNAL=TERM
#   When ${TIMEOUT} seconds have passed since running the command, this will be
#   the signal to send to the process to make it stop.  The default is TERM.
#   [NOTE: KILL will _also_ be sent two seconds after the timeout if the first
#   signal doesn't do its job]
#
# -t=TIMEOUT. After this duration, command will be killed (and retried if that's the
#   right thing to do).  If unspecified, commands may run as long as they like
#   and eretry will simply wait for them to finish. Uses sleep(1) time
#   syntax.
#
# -T=TIMEOUT. Total timeout for entire eretry operation.
#   This -T flag is different than -t in that -T applies to the entire eretry
#   operation including all iterations and retry attempts and timeouts of each
#   individual command. Uses sleep(1) time syntax.
#
# -w=SECONDS
#   A warning will be generated on (or slightly after) every SECONDS while the
#   command keeps failing.
#
# All direct parameters to eretry are assumed to be the command to execute, and
# eretry is careful to retain your quoting.
eretry()
{
    $(opt_parse \
        ":delay d=0              | Time to sleep between failed attempts before retrying." \
        ":fatal_exit_codes e=0   | Space-separated list of exit codes that are fatal (i.e. will result in no retry)." \
        ":retries r              | Command will be attempted once plus this number of retries if it continues to fail." \
        ":signal sig s=TERM      | Signal to be send to the command if it takes longer than the timeout." \
        ":timeout t              | If one attempt takes longer than this duration, kill it and retry if appropriate." \
        ":max_timeout T=infinity | If all attempts take longer than this duration, kill what's running and stop retrying." \
        ":warn_every w           | Generate warning messages after failed attempts when it has been more than this long since the last warning.")

    # If unspecified, limit timeout to the same as max_timeout
    : ${timeout:=${max_timeout:-infinity}}


    # If a total timeout was specified then wrap call to eretry_internal with etimeout
    if [[ ${max_timeout} != "infinity" ]]; then
        : ${retries:=infinity}

        etimeout -t=${max_timeout} -s=${signal} --          \
            opt_forward eretry_internal timeout delay fatal_exit_codes signal warn_every retries -- "${@}"
    else
        # If no total timeout or retry limit was specified then default to prior
        # behavior with a max retry of 5.
        : ${retries:=5}

        opt_forward eretry_internal timeout delay fatal_exit_codes signal warn_every retries -- "${@}"
    fi
}

# Internal method called by eretry so that we can wrap the call to eretry_internal with a call
# to etimeout in order to provide upper bound on entire invocation.
eretry_internal()
{
    $(opt_parse \
        ":delay d                | Time to sleep between failed attempts before retrying." \
        ":fatal_exit_codes e     | Space-separated list of exit codes that are fatal (i.e. will result in no retry)." \
        ":retries r              | Command will be attempted once plus this number of retries if it continues to fail." \
        ":signal sig s           | Signal to be send to the command if it takes longer than the timeout." \
        ":timeout t              | If one attempt takes longer than this duration, kill it and retry if appropriate." \
        ":warn_every w           | Generate warning messages after failed attempts when it has been more than this long since the last warning.")

    argcheck delay fatal_exit_codes retries signal timeout

    # Command
    local cmd=("${@}")
    local attempt=0
    local rc=0
    local exit_codes=()
    local stdout=""
    local warn_seconds="${SECONDS}"

    # If no command to execute just return success immediately
    if [[ -z "${cmd[@]:-}" ]]; then
        return 0
    fi

    while true; do
        [[ ${retries} != "infinity" && ${attempt} -ge ${retries} ]] && break || (( attempt+=1 ))
        
        edebug "Executing $(lval cmd timeout max_timeout) retries=(${attempt}/${retries})"

        # Run the command through timeout wrapped in tryrc so we can throw away the stdout 
        # on any errors. The reason for this is any caller who cares about the output of
        # eretry might see part of the output if the process times out. If we just keep
        # emitting that output they'd be getting repeated output from failed attempts
        # which could be completely invalid output (e.g. truncated XML, Json, etc).
        stdout=""
        $(tryrc -o=stdout etimeout -t=${timeout} -s=${signal} "${cmd[@]}")
        
        # Append list of exit codes we've seen
        exit_codes+=(${rc})

        # Break if the process exited with white listed exit code.
        if echo "${fatal_exit_codes}" | grep -wq "${rc}"; then
            edebug "Command reached terminal exit code.  Ending retries. $(lval rc fatal_exit_codes cmd)"
            break
        fi

        # Show warning if requested
        if [[ -n ${warn_every} ]] && (( SECONDS - warn_seconds > warn_every )); then
            ewarn "Failed $(lval cmd timeout exit_codes) retries=(${attempt}/${retries})" 
            warn_seconds=${SECONDS}
        fi

        # Don't use "-ne" here since delay can have embedded units
        if [[ ${delay} != "0" ]] ; then
            edebug "Sleeping $(lval delay)" 
            sleep ${delay}
        fi
    done

    [[ ${rc} -eq 0 ]] || ewarn "Failed $(lval cmd timeout exit_codes) retries=(${attempt}/${retries})" 

    # Emit stdout
    echo -n "${stdout}"

    # Return final return code
    return ${rc}
}

# setvars takes a template file with optional variables inside the file which
# are surrounded on both sides by two underscores.  It will replace the variable
# (and surrounding underscores) with a value you specify in the environment.
#
# For example, if the input file looks like this:
#   Hi __NAME__, my name is __OTHERNAME__.
# And you call setvars like this
#   NAME=Bill OTHERNAME=Ted setvars intputfile
# The inputfile will be modified IN PLACE to contain:
#   Hi Bill, my name is Ted.
#
# SETVARS_ALLOW_EMPTY=(0|1)
#   By default, empty values are NOT allowed. Meaning that if the provided key
#   evaluates to an empty string, it will NOT replace the __key__ in the file.
#   if you require that functionality, simply use SETVARS_ALLOW_EMPTY=1 and it
#   will happily allow you to replace __key__ with an empty string.
#
#   After all variables have been expanded in the provided file, a final check
#   is performed to see if all variables were set properly. It will return 0 if
#   all variables have been successfully set and 1 otherwise.
#
# SETVARS_WARN=(0|1)
#   To aid in debugging this will display a warning on any unset variables.
#
# OPTIONAL CALLBACK:
#   You may provided an optional callback as the second parameter to this function.
#   The callback will be called with the key and the value it obtained from the
#   environment (if any). The callback is then free to make whatever modifications
#   or filtering it desires and then echo the new value to stdout. This value
#   will then be used by setvars as the replacement value.
setvars()
{
    $(opt_parse "filename" "?callback")
    edebug "Setting variables $(lval filename callback)"
    [[ -f ${filename} ]] || die "$(lval filename) does not exist"

    # If this file is a binary file skip it
    if file ${filename} | grep -q ELF ; then
        edebug "Skipping binary file $(lval filename): $(file ${filename})"
        return 0
    fi

    for arg in $(grep -o "__\S\+__" ${filename} | sort --unique || true); do
        local key="${arg//__/}"
        local val="${!key:-}"

        # Call provided callback if one was provided which by contract should print
        # the new resulting value to be used
        [[ -n ${callback} ]] && val=$(${callback} "${key}" "${val}")

        # If we got an empty value back and empty values aren't allowed then continue.
        # We do NOT call die here as we'll deal with that at the end after we have
        # tried to expand all variables.
        [[ -n ${val} || ${SETVARS_ALLOW_EMPTY:-0} -eq 1 ]] || continue

        edebug "   ${key} => ${val}"

        # Put val into perl's environment and let _perl_ pull it out of that
        # environment.  This has the benefit of causing it to not try to
        # interpret any of it, but to treat it as a raw string
        VAL="${val}" perl -pi -e "s/__${key}__/\$ENV{VAL}/g" "${filename}" || die "Failed to set $(lval key val filename)"
    done

    # Check if anything is left over and return correct return value accordingly.
    if grep -qs "__\S\+__" "${filename}"; then
        local notset=()
        notset=( $(grep -o '__\S\+__' ${filename} | sort --unique | tr '\n' ' ') )
        [[ ${SETVARS_WARN:-1}  -eq 1 ]] && ewarn "Failed to set all variables in $(lval filename notset)"
        return 1
    fi

    return 0
}

## Ever want to evaluate a bash command that is stored in an array?  It's
## mostly a great way to do things.  Keeping the various arguments separate in
## the array means you don't have to worry about quoting.  Bash keeps the
## quoting you gave it in the first place.  So the typical way to run such a
## command is like this:
##
##     > cmd=(echo "\$\$")
##     > "${cmd[@]}"
##     $$
##
##  As you can see, since the dollar signs were quoted as the command was put
##  into the array, so the quoting was retained when the command was executed.
##  If you had instead used eval, you wouldn't get that behavior:
##
##     > cmd=(echo "\$\$")
##     > "${cmd[@]}"
##     53355
##
##  Instead, the argument gets "evaluated" by bash, turning it into the current
##  process id.  So if you're storing commands in an array, you can see that
##  you typically don't want to use eval.
##
##  But there's a wrinkle, of course.  If the first item in your array is the
##  name of an alias, bash won't expand that alias when using the first syntax.
##  This is because alias expansion happens in a stage _before_ bash expands
##  the contents of the variable.
##
##  So what can you do if you want alias expansion to happen but also want
##  things in the array to be quoted properly?  Use `quote_array`.  It will
##  ensure that all of the arguments don't get evaluated by bash, but that the
##  name of the command _does_ go through alias expansion.
##
##      > cmd=(echo "\$\$")
##      > quote_eval "${cmd[@]}"
##      $$
##
##  There, wasn't that simple?
##
quote_eval()
{
    local cmd=("$1")
    shift

    for arg in "${@}" ; do
        cmd+=( "$(printf %q "${arg}")" )
    done

    eval "${cmd[@]}"
}


#-----------------------------------------------------------------------------
# ARRAYS
#-----------------------------------------------------------------------------

# array_init will split a string on any characters you specify, placing the
# results in an array for you.
#
#  $1: name of array to assign to (i.e. "array")
#  $2: string to be split
#  $3: (optional) character(s) to be used as delimiters.
array_init()
{
    $(opt_parse "__array" "?__string" "?__delim")

    # If nothing was provided to split on just return immediately
    [[ -z ${__string} ]] && { eval "${__array}=()"; return 0; } || true

    # Default bash IFS is space, tab, newline, so this will default to that
    : ${__delim:=$' \t\n'}

    IFS="${__delim}" eval "${__array}=(\${__string})"
}

# This function works like array_init, but always specifies that the delimiter
# be a newline.
array_init_nl()
{
    [[ $# -eq 2 ]] || die "array_init_nl requires exactly two parameters"
    array_init "$1" "$2" $'\n'
}

# Initialize an array from a Json array. This will essentially just strip
# of the brackets from around the Json array and then remove the internal
# quotes on each value since they are unecessary in bash.
array_init_json()
{
    [[ $# -ne 2 ]] && die "array_init_json requires exactly two parameters"
    array_init "$1" "$(echo "${2}" | sed -e 's|^\[\s*||' -e 's|\s*\]$||' -e 's|",\s*"|","|g' -e 's|"||g')" ","
}

# Print the size of any array.  Yes, you can also do this with ${#array[@]}.
# But this functions makes for symmertry with pack (i.e. pack_size).
array_size()
{
    $(opt_parse __array)

    # Treat unset variables as being an empty array, because when you tell
    # bash to create an empty array it doesn't really allow you to
    # distinguish that from an unset variable.  (i.e. it doesn't show you
    # the variable until you put something in it)
    local value=$(eval "echo \${${__array}[*]:-}")
    if [[ -z "${value}" ]]; then
        echo 0
    else
        eval "echo \${#${__array}[@]}"
    fi

    return 0
}

# Return true (0) if an array is empty and false (1) otherwise
array_empty()
{
    $(opt_parse __array)
    [[ $(array_size ${__array}) -eq 0 ]]
}

# Returns true (0) if an array is not empty and false (1) otherwise
array_not_empty()
{
    $(opt_parse __array)
    [[ $(array_size ${__array}) -ne 0 ]]
}

# array_add will split a given input string on requested delimiters and add them
# to the given array (which may or may not already exist).
#
# $1: name of the array to add the new elements to
# $2: string to be split
# $3: (optional) character(s) to be used as delimiters.
array_add()
{
    $(opt_parse "__array" "?__string" "?__delim")

    # If nothing was provided to split on just return immediately
    [[ -z ${__string} ]] && return 0

    # Default bash IFS is space, tab, newline, so this will default to that
    : ${__delim:=$' \t\n'}

    # Parse the input given the delimiter and append to the array.
    IFS="${__delim}" eval "${__array}+=(\${__string})"
}

# Identical to array_add only hard codes the delimter to be a newline.
array_add_nl()
{
    [[ $# -ne 2 ]] && die "array_add_nl requires exactly two parameters"
    array_add "$1" "$2" $'\n'
}

# array_remove will remove the given value(s) from an array, if present.
#
# OPTIONS:
# -a=(0|1) Remove all instances (defaults to only removing the first instance)
array_remove()
{
    $(opt_parse \
        "+all a  | Remove all instances of the item instead of just the first." \
        "__array | Name of array to operate on.")

    # Return immediately if if array is not set or no values were given to be
    # removed. The reason we don't error out on an unset array is because
    # bash doesn't save arrays with no members.  For instance A=() unsets array A...
    [[ -v ${__array} && $# -gt 0 ]] || return 0
    
    local value
    for value in "${@}"; do

        local idx
        for idx in $(array_indexes ${__array}); do
            eval "local entry=\${${__array}[$idx]}"
            [[ "${entry}" == "${value}" ]] || continue

            unset ${__array}[$idx]

            # Remove all instances or only the first?
            [[ ${all} -eq 1 ]] || break
        done
    done
}

# Bash arrays may have non-contiguous indexes.  For instance, you can unset an
# ARRAY[index] to remove an item from the array and bash does not shuffle the
# indexes.
#
# If you need to iterate over the indexes of an array (rather than simply
# iterating over the items), you can call array_indexes on the array and it
# will echo all of the indexes that exist in the array.
#
array_indexes()
{
    $(opt_parse __array_indexes_array)
    eval "echo \${!${__array_indexes_array}[@]}"
}

# Same as array_indexes only this enumerates them in reverse order.
array_rindexes()
{
    $(opt_parse __array_indexes_array)
    eval "echo \${!${__array_indexes_array}[@]} | rev"
}

# array_contains will check if an array contains a given value or not. This
# will return success (0) if it contains the requested element and failure (1)
# if it does not.
#
# $1: name of the array to search
# $2: value to check for existance in the array
array_contains()
{
    $(opt_parse __array __value)

    local idx=0
    for idx in $(array_indexes ${__array}); do
        eval "local entry=\${${__array}[$idx]}"
        [[ "${entry}" == "${__value}" ]] && return 0
    done

    return 1
}

# array_join will join an array into one flat string with the provided multi
# character delimeter between each element in the resulting string. Can also
# optionally pass in options to also put the delimiter before or after (or both)
# all elements.
#
# $1: name of the array to join
# $2: (optional) delimiter
array_join()
{
    $(opt_parse \
        "+before b | Insert delimiter before all joined elements." \
        "+after a  | Insert delimiter after all joined elements."  \
        "__array   | Name of array to operate on."                 \
        "?delim    | Delimiter to place between array items.  Default is a space.")

    # If the array is empty return empty string
    array_empty ${__array} && { echo -n ""; return 0; } || true

    # Default delimiter is an empty string.
    : ${delim:=" "}

    # If requested, emit the delimiter before hand.
    if [[ ${before} -eq 1 ]]; then
        echo -n "${delim}"
    fi

    # Iterate over each element of the array and echo that element with the
    # delimiter following it. Special case the last element in the array because
    # we only want to emit the trailing delimiter if requested.
    local indexes=( $(array_indexes ${__array}) )
    local idx_last=$(echo "${indexes[@]}" | awk '{print $NF}')

    local idx
    for idx in ${indexes[@]}; do
        eval "echo -n \"\${${__array}[$idx]}\""

        # If this is not the last element then always echo the delimiter. 
        # If this is the last element only echo the delimiter if after==1.
        if [[ ${idx} -lt ${idx_last} || ${after} -eq 1 ]]; then
            echo -n "${delim}"
        fi
    done
}

# Identical to array_join only it hardcodes the dilimter to a newline.
array_join_nl()
{
    [[ $# -ne 1 ]] && die "array_join_nl requires exactly one parameter"
    array_join "$1" $'\n'
}

# Create a regular expression that will match any one of the items in this
# array.  Suppose you had an array containing the first four letters of the
# alphabet.  Calling array_regex on that array will produce:
#
#    (a|b|c|d)
#
# Perhaps this is an esoteric thing to do, but it's pretty handy when you want
# it.
#
# NOTE: Be sure to quote the output of your array_regex call, because bash
# finds parantheses and pipe characters to be very important.
#
# WARNING: This probably only works if your array contains items that do not
# have whitespace or regex-y characters in them.  Pids are good.  Other stuff,
# probably not so much.
#
array_regex()
{
    $(opt_parse __array)

    echo -n "("
    array_join ${__array}
    echo -n ")"
}

# Sort an array in-place.
#
array_sort()
{
    $(opt_parse \
        "+unique u  | Remove all but one copy of each item in the array." \
        "+version V | Perform a natural (version number) sort.")

    local __array
    for __array in "${@}" ; do
        local flags=()

        [[ ${unique} -eq 1 ]]  && flags+=("--unique")
        [[ ${version} -eq 1 ]] && flags+=("--version-sort")
        
        readarray -t ${__array} < <(
            local idx
            for idx in $(array_indexes ${__array}); do
                eval "echo \${${__array}[$idx]}"
            done | sort ${flags[@]:-}
        )
    done
}

#-----------------------------------------------------------------------------
# PACK
#-----------------------------------------------------------------------------
#
# Consider a "pack" to be a "new" data type for bash.  It stores a set of
# key/value pairs in an arbitrary format inside a normal bash (string)
# variable.  This is much like an associative array, but has a few differences
#
#   1) You can store packs INSIDE associative arrays (example in unit tests)
#   2) The "keys" in a pack may not contain an equal sign, nor may they contain
#      whitespace.
#   3) Packed values cannot contain newlines.
#
#

#
# For a (new or existing) variable whose contents are formatted as a pack, set
# one or more keys to values.  For example, the following will create a new
# variable packvar that will contain three keys (alpha, beta, n) with
# associated values (a, b, 7)
#
#  pack_set packvar alpha=a beta=b n=7
#
pack_set()
{
    local _pack_set_pack=$1 ; shift

    for _pack_set_arg in "${@}" ; do
        local _pack_set_key="${_pack_set_arg%%=*}"
        local _pack_set_val="${_pack_set_arg#*=}"

        pack_set_internal ${_pack_set_pack} "${_pack_set_key}" "${_pack_set_val}"
    done
}

#
# Much like pack_set, and takes arguments of the same form.  The difference is
# that pack_update will create no new keys -- it will only update keys that
# already exist.
#
pack_update()
{
    local _pack_update_pack=$1 ; shift

    for _pack_update_arg in "${@}" ; do
        local _pack_update_key="${_pack_update_arg%%=*}"
        local _pack_update_val="${_pack_update_arg#*=}"

        pack_keys ${_pack_update_pack} | grep -aPq "\b${_pack_update_key}\b" \
            && pack_set_internal ${_pack_update_pack} "${_pack_update_key}" "${_pack_update_val}" \
            || true
    done
}

pack_set_internal()
{
    local _pack_pack_set_internal=$1
    local _tag=$2
    local _val="$3"

    argcheck _tag
    [[ ${_tag} =~ = ]] && die "bashutils internal error: tag ${_tag} cannot contain equal sign"
    [[ $(echo "${_val}" | wc -l) -gt 1 ]] && die "packed values cannot hold newlines"

    local _removeOld="$(echo -n "${!1:-}" | _unpack | grep -av '^'${_tag}'=' || true)"
    local _addNew="$(echo "${_removeOld}" ; echo -n "${_tag}=${_val}")"
    local _packed=$(echo "${_addNew}" | _pack)

    printf -v ${1} "${_packed}"
}

#
# Get the last value assigned to a particular key in this pack.
#
pack_get()
{
    local _pack_pack_get=$1
    local _tag=$2

    argcheck _pack_pack_get _tag

    local _unpacked="$(echo -n "${!_pack_pack_get:-}" | _unpack)"
    local _found="$(echo -n "${_unpacked}" | grep -a "^${_tag}=" || true)"
    echo "${_found#*=}"
}

pack_contains()
{
    [[ -n $(pack_get $@) ]]
}

#
# Copy a packed value from one variable to another.  Either variable may be
# part of an associative array, if you're so inclined.
#
# Examples:
#   pack_copy A B
#   pack_copy B A["alpha"]
#   pack_copy A["alpha"] B[1]
#
pack_copy()
{
    argcheck 1 2
    eval "${2}=\"\${!1}\""
}

#
# Call provided callback function on each entry in the pack. The callback function
# should take two arguments, and it will be called once for each item in the
# pack and passed the key as the first value and its value as the second value.
#
pack_iterate()
{
    local _func=$1
    local _pack_pack_iterate=$2
    argcheck _func _pack_pack_iterate

    local _unpacked="$(echo -n "${!_pack_pack_iterate}" | _unpack)"
    local _lines ; array_init_nl _lines "${_unpacked}"

    for _line in "${_lines[@]}" ; do

        local _key="${_line%%=*}"
        local _val="${_line#*=}"

        ${_func} "${_key}" "${_val}"

    done
}

# Spews bash commands that, when executed will declare a series of variables
# in the caller's environment for each and every item in the pack. This uses
# the "eval command invocation string" which the caller then executes in order
# to manifest the commands. For instance, if your pack contains keys a and b
# with respective values 1 and 2, you can create locals a=1 and b=2 by running:
#
#   $(pack_import pack)
#
# If you don't want the pack's entire contents, but only a limited subset, you
# may specify them.  For instance, in the same example scenario, the following
# will create a local a=1, but not a local for b.
#
#  $(pack_import pack a)
#
# OPTIONS:
# -l: Emit local variables with 'local' scope qualifier (default)
# -g: Emit global variables with no scope qualifier
# -e: Emit exported variables with 'export' keyword
pack_import()
{
    $(opt_parse \
        "+local l=1        | Emit local variables via local builtin (default)." \
        "+global g         | Emit global variables instead of local (i.e. undeclared variables)." \
        "+export e         | Emit exported variables via export builtin." \
        "_pack_import_pack | Pack to operate on.")

    local _pack_import_keys=("${@}")
    [[ $(array_size _pack_import_keys) -eq 0 ]] && _pack_import_keys=($(pack_keys ${_pack_import_pack}))

    # Determine requested scope for the variables
    local _pack_import_scope="local"
    [[ ${local} -eq 1 ]]  && _pack_import_scope="local"
    [[ ${global} -eq 1 ]] && _pack_import_scope=""
    [[ ${export} -eq 1 ]] && _pack_import_scope="export"

    local _pack_import_cmd=""
    for _pack_import_key in "${_pack_import_keys[@]}" ; do
        local _pack_import_val=$(pack_get ${_pack_import_pack} ${_pack_import_key})
        _pack_import_cmd+="$_pack_import_scope $_pack_import_key=\"${_pack_import_val}\"; "
    done

    echo "eval "${_pack_import_cmd}""
}

#
# Assigns values into a pack by extracting them from the caller environment.
# For instance, if you have locals a=1 and b=2 and run the following:
#
#    pack_export pack a b
#
# You will be left with the same pack as if you instead said:
#
#   pack_set pack a=${a} b=${b}
#
pack_export()
{
    local _pack_export_pack=$1 ; shift

    local _pack_export_args=()
    for _pack_export_arg in "${@}" ; do
        _pack_export_args+=("${_pack_export_arg}=${!_pack_export_arg:-}")
    done

    pack_set "${_pack_export_pack}" "${_pack_export_args[@]}"
}

pack_size()
{
    [[ -z ${1} ]] && die "pack_size requires a pack to be specified as \$1"
    echo -n "${!1}" | _unpack | wc -l
}

#
# Echo a whitespace-separated list of the keys in the specified pack to stdout.
#
pack_keys()
{
    [[ -z ${1} ]] && die "pack_keys requires a pack to be specified as \$1"
    echo "${!1:-}" | _unpack | sed 's/=.*$//'
}

# Note: To support working with print_value, pack_print does NOT print a
# newline at the end of its output
pack_print()
{
    local _pack_pack_print=$1
    argcheck _pack_pack_print

    echo -n '('
    pack_iterate _pack_print_item ${_pack_pack_print}
    echo -n ')'
}

_pack_print_item()
{
    echo -n "[$1]=\"$2\" "
}

_unpack()
{
    # NOTE: BSD base64 is really chatty and this is the reason we discard its
    # error output
    base64 --decode 2>/dev/null | tr '\0' '\n'
}

_pack()
{
    # NOTE: BSD base64 is really chatty and this is the reason we discard its
    # error output
    grep -av '^$' | tr '\n' '\0' | base64 2>/dev/null
}

#-----------------------------------------------------------------------------
# STRING MANIPULATION
#-----------------------------------------------------------------------------

# Convert a given input string into "upper snake case". This is generally most
# useful when converting a "CamelCase" string although it will work just as
# well on non-camel case input. Essentially it looks for all upper case letters
# and puts an underscore before it, then uppercase the entire input string.
#
# For example:
#
# sliceDriveSize => SLICE_DRIVE_SIZE
# slicedrivesize => SLICEDRIVESIZE
#
# It has some special handling for some common corner cases where the normal
# camel case idiom isn't well followed. The best example for this is around
# units (e.g. MB, GB). Consider "sliceDriveSizeGB" where SLICE_DRIVE_SIZE_GB
# is preferable to SLICE_DRIVE_SIZE_G_B.
#
# The current list of translation corner cases this handles:
# KB, MB, GB, TB
to_upper_snake_case()
{
    $(opt_parse input)

    echo "${input}"         \
        | sed -e 's|KB|Kb|' \
              -e 's|MB|Mb|' \
              -e 's|GB|Gb|' \
              -e 's|TB|Tb|' \
        | perl -ne 'print uc(join("_", split(/(?=[A-Z])/)))'
}

#-----------------------------------------------------------------------------
# JSON
#-----------------------------------------------------------------------------

# Convert each argument, in turn, to json in an appropriate way and drop them
# all in a single json blob.
#
to_json()
{
    echo -n "{"
    local _notfirst="" _arg
    for _arg in "${@}" ; do
        [[ -n ${_notfirst} ]] && echo -n ","

        local _arg_noqual=$(discard_qualifiers ${_arg})
        echo -n "$(json_escape ${_arg_noqual}):"
        if is_pack ${_arg} ; then
            pack_to_json ${_arg}

        elif is_array ${_arg} ; then
            array_to_json ${_arg}

        elif is_associative_array ${_arg} ; then
            associative_array_to_json ${_arg}

        else
            # You don't strictly need the test here to determine if ${_arg}
            # contains the name of a variable, but if we skip the check then
            # bash generates an error message that just says "!_arg: unbound
            # variable" which really isn't all that helpful.  This way we can
            # spit out the name of the bad variable.
            [[ -v ${_arg} ]] || die "Cannot create json from unbound variable ${_arg}."
            json_escape "${!_arg}"
        fi

        _notfirst=true
    done
    echo -n "}"
}

# Convert an array specified by name (i.e ARRAY not ${ARRAY} or ${ARRAY[@]})
# into a json array containing the same data.
#
array_to_json()
{
    # This will store a copy of the specified array's contents into __array
    $(opt_parse __array)
    eval "local __array=(\"\${${__array}[@]}\")"

    echo -n "["
    local i notfirst=""
    for i in "${__array[@]}" ; do
        [[ -n ${notfirst} ]] && echo -n ","
        echo -n $(json_escape "$i")
        notfirst=true
    done

    echo -n "]"
}

associative_array_to_json()
{
    echo -n "{"
    local _notfirst="" _key
    edebug "1=$1"
    for _key in $(eval echo -n "\${!$1[@]}") ; do
        edebug $(lval _key)
        [[ -n ${_notfirst} ]] && echo -n ","

        echo -n $(json_escape ${_key})
        echo -n ':'
        echo -n $(json_escape "$(eval echo -n \${$1[$_key]})")

        _notfirst=true
    done
    echo -n "}"
}

# Convert a single pack into a json blob where the keys are the same as the
# keys from the pack (and so are the values)
#
pack_to_json()
{
    [[ -z ${1} ]] && die "pack_to_json requires a pack to be specified as \$1"

    local _pack _key _notfirst=""
    _pack=$(discard_qualifiers $1)
    echo -n "{"
    for _key in $(pack_keys ${_pack}) ; do
        [[ -n ${_notfirst} ]] && echo -n ","
        echo -n '"'${_key}'":'"$(json_escape "$(pack_get ${_pack} ${_key})")"
        _notfirst=true
    done
    echo -n "}"
}

# Escape an arbitrary string (specified as $1) so that it is quoted and safe to
# put inside json. This is done via a call to jq with --raw-input which will 
# cause it to emit a properly quoted and escaped string that is safe to use
# inside json.
#
json_escape()
{
    # Newer jq has a -j flag to join newlines into a single flat string.
    # To workaround the lack of this flag in older versions, we wrap the call
    # to jq in a subshell which is not quoted to strip off the final newline.
    echo -n $(echo -n "$1" | jq --raw-input --slurp .)
}

# Import all of the key:value pairs from a non-nested Json object directly into
# the caller's environment as proper bash variables. By default this will import all
# the keys available into the caller's environment. Alternatively you can provide
# an optional list of keys to restrict what is imported. If any of the explicitly
# requested keys are not present this will be interpreted as an error and json_import
# will return non-zero. Keys can be marked optional via the '?' prefix before the key
# name in which case they will be set to an empty string if the key is missing. 
#
# Similar to a lot of other  methods inside bashutils, this uses the "eval command
# invocation string" idom. So, the proper calling convention for this is:
#
# $(json_import)
#
# By default this function operates on stdin. Alternatively you can change it to
# operate on a file via -f. To use via STDIN use one of these idioms:
#
# $(json_import <<< ${json})
# $(curl ... | $(json_import)
#
json_import()
{
    $(opt_parse \
        "+global g           | Emit global variables instead of local ones." \
        "+export e           | Emit exported variables instead of local ones." \
        ":file f=-           | Parse contents of provided file instead of stdin." \
        "+upper_snake_case u | Convert all keys into UPPER_SNAKE_CASE." \
        ":prefix p           | Prefix all keys with the provided required prefix." \
        ":query jq q         | Use JQ style query expression on given JSON before parsing." \
        ":exclude x          | Whitespace separated list of keys to exclude while importing.")

    # Determine flags to pass into declare
    local dflags=""
    [[ ${global} -eq 1 ]] && dflags="-g"
    [[ ${export} -eq 1 ]] && dflags="-gx"

    # optional jq query, or . which selects everything in jq
    : ${query:=.}

    # Lookup optional filename to use. If no filename was given then we're operating on STDIN.
    # In either case read into a local variable so we can parse it repeatedly in this function.
    local _json_import_data=$(cat ${file} | jq -r "${query}")

    # Check if explicit keys are requested. If not, slurp all keys in from provided data.
    local _json_import_keys=("${@:-}")
    [[ ${#_json_import_keys} -eq 0 ]] && array_init_json _json_import_keys "$(jq -c -r keys <<< ${_json_import_data})"

    # Get list of optional keys to exclude
    local excluded
    array_init excluded "${exclude}"

    # Debugging
    edebug $(lval prefix query file _json_import_data _json_import_keys excluded)

    local cmd key val
    for key in "${_json_import_keys[@]}"; do
        array_contains excluded ${key} && continue

        # If the key is marked as optional then add filter "//empty" so that 'null' literal is replaced with an empty string
        if [[ ${key} == \?* ]]; then
            key="${key#\?}"
            val=$(jq -r ".${key}//empty" <<< ${_json_import_data})
        else
            # Ensure the data has the requested key by appending a 'has' filter which emit 'true' or 'false' if the key was
            # present. Adding '-e' option to jq will cause it to exit with non-zero if the last filter produces 'null' or 'false'.
            # We don't actually care about the 'true/false' since we're relying on the return code being non-zero to trigger
            # set -e error handling. So, we remove that from what we ultimately store into our value via 'head -1'.
            val=$(jq -r -e '.'${key}', has("'${key}'")' <<< ${_json_import_data} | head -1)
        fi

        edebug $(lval key val)
        [[ ${upper_snake_case} -eq 1 ]] && key=$(to_upper_snake_case "${key}")

        cmd+="declare ${dflags} ${prefix}${key}=\"${val}\";"
    done

    echo -n "eval ${cmd}"
}

#-----------------------------------------------------------------------------
# Type detection
#-----------------------------------------------------------------------------

# These functions take a parameter that is a variable NAME and allow you to
# determine information about that variable name.
#
# Detecting packs relies on the bashutils convention of "if the first character
# of the name is a +, consider it a pack)
is_array()
{
    [[ "$(declare -p $1 2>/dev/null)" =~ ^declare\ -a ]]
}

is_associative_array()
{
    [[ "$(declare -p $1 2>/dev/null)" =~ ^declare\ -A ]]
}

is_pack()
{
    [[ "${1:0:1}" == '%' ]]
}

discard_qualifiers()
{
    echo "${1##%}"
}

#-----------------------------------------------------------------------------
# ASSERTS
#-----------------------------------------------------------------------------

# Executes a command (simply type the command after assert as if you were
# running it without assert) and calls die if that command returns a bad exit
# code.
# 
# For example:
#    assert [[ 0 -eq 1 ]]
#
# There's a subtlety here that I don't think can easily be fixed given bash's
# semantics.  All of the arguments get evaluated prior to assert ever seeing
# them.  So it doesn't know what variables you passed in to an expression, just
# what the expression was.  This is pretty handy in cases like this one:
#
#   a=1
#   b=2
#   assert [[ ${a} -eq ${b} ]]
#
# because assert will tell you that the command that it executed was 
#
#     [[ 1 -eq 2 ]]
#
# There it seems ideal.  But if you have an empty variable, things get a bit
# annoying.  For instance, this command will blow up because inside assert bash
# will try to evaluate [[ -z ]] without any arguments to -z.  (Note -- it still
# blows up, just not in quite the way you'd expect)
#
#    empty=""
#    assert [[ -z ${empty} ]]
#
# To make this particular case easier to deal with, we also have assert_empty
# which you could use like this:
#
#    assert_empty empty
#
assert()
{
    local cmd=( "${@}" )
    
    try
    {
        eval "${cmd[@]}"
    }
    catch
    {
        [[ $? -eq 0 ]] || die "assert failed (rc=$?}) :: ${cmd[@]}"
    }
}

assert_true()
{
    assert "${@}"
}

assert_false()
{
    local cmd=( "${@}" )
    
    try
    {
        eval "${cmd[@]}"
    }
    catch
    {
        [[ $? -ne 0 ]] || die "assert failed (rc=$?) :: ${cmd[@]}"
    }
}

assert_op()
{
    compare "${@}" || "assert_op failed :: ${@}"
}

assert_eq()
{
    $(opt_parse "?lh" "?rh" "?msg")
    [[ "${lh}" == "${rh}" ]] || die "assert_eq failed [${msg:-}] :: $(lval lh rh)"
}

assert_ne()
{
    $(opt_parse "?lh" "?rh" "?msg")
    [[ ! "${lh}" == "${rh}" ]] || die "assert_ne failed [${msg:-}] :: $(lval lh rh)"
}

assert_match()
{
    $(opt_parse "?text" "?regex" "?msg")
    [[ "${text}" =~ ${regex} ]] || die "assert_match failed [${msg:-}] :: $(lval text regex)"
}

assert_not_match()
{
    $(opt_parse "?lh" "?rh" "?msg")
    [[ ! "${lh}" =~ "${rh}" ]] || die "assert_not_match failed [${msg:-}] :: $(lval lh rh)"
}

assert_zero()
{
    [[ ${1:-0} -eq 0 ]] || die "assert_zero received $1 instead of zero."
}

assert_not_zero()
{
    [[ ${1:-1} -ne 0 ]] || die "assert_not_zero received ${1}."
}

assert_empty()
{
    local _arg
    for _arg in $@; do
        [[ "${!_arg:-""}" == "" ]] || die "assert_empty received $(lval _arg)"
    done
}

assert_not_empty()
{
    local _arg
    for _arg in $@; do
        [[ "${!_arg}" != "" ]] || die "assert_not_empty received $(lval _arg)"
    done
}

assert_exists()
{
    local name
    for name in "${@}"; do
        [[ -e "${name}" ]] || die "'${name}' does not exist"
    done
}

assert_not_exists()
{
    local name
    for name in "${@}"; do
        [[ ! -e "${name}" ]] || die "'${name}' exists"
    done
}

assert_archive_contents()
{
    $(opt_parse archive)
    edebug "Validating $(lval archive)"
    
    local expect=( "${@}" )
    array_sort expect

    assert_exists "${archive}"
    local actual=( $(archive_list ${archive}) )

    edebug "$(lval expect)"
    edebug "$(lval actual)"

    assert_eq "${#expect[@]}" "${#actual[@]}" "Size mismatch"

    local idx
    for idx in $(array_indexes expect); do
        eval "local e=\${expect[$idx]}"
        eval "local a=\${actual[$idx]}"

        assert_eq "${e}" "${a}" "Mismatch at index=${idx}"
    done
}

assert_directory_contents()
{
    $(opt_parse directory)
    edebug "Validating $(lval directory)"

    local expect=( "${@}" )
    array_sort expect
    
    assert_exists "${directory}"
    local actual=( $(find "${directory}" -printf '%P\n' | sort) )

    edebug "$(lval expect)"
    edebug "$(lval actual)"

    assert_eq "${#expect[@]}" "${#actual[@]}" "Size mismatch"

    local idx
    for idx in $(array_indexes expect); do
        eval "local e=\${expect[$idx]}"
        eval "local a=\${actual[$idx]}"

        assert_eq "${e}" "${a}" "Mismatch at index=${idx}"
    done
}

#-----------------------------------------------------------------------------
# DEFAULT TRAPS
#-----------------------------------------------------------------------------

# Default traps
die_on_abort
die_on_error
enable_trace

# Add default trap for EXIT so that we can ensure _bashutils_on_exit_start
# and _bashutils_on_exit_end get called when the process exits. Generally, 
# this allows us to do any error handling and cleanup needed when a process
# exits. But the main reason this exists is to ensure we can intercept
# abnormal exits from things like unbound variables (e.g. set -u).
trap_add "" EXIT

#-----------------------------------------------------------------------------
# SOURCING
#-----------------------------------------------------------------------------

return 0