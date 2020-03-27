#!/usr/bin/env bash

_mainScript_() {

  if ! command -v pg_dump &>/dev/null; then
    error "Can not run without 'pg_dump' utility"
  fi

  username="${POSTGRES_USER}"
  db="${POSTGRES_DB}"
  password="${POSTGRES_PASSWORD}"
  days_of_backups=3  # Must be less than 7
  parent_dir="/backups"
  todays_dir="${parent_dir}/$(date +%a)"
  logFile="/backups/dbBackup.log"
  backupTime="$(date +%Y-%m-%d_%H_%M_%S)"
  days_of_backups=3  # Must be less than 7

  _rotateOld_() {
      # Remove the oldest backup in rotation
      day_dir_to_remove="${parent_dir}/$(date --date="${days_of_backups} days ago" +%a)"

      if [ -d "${day_dir_to_remove}" ]; then
          notice "Rotating old log: '${day_dir_to_remove}'"
          rm -rf "${day_dir_to_remove}"
      fi
  }

  _doBackup_() {
    # Make sure today's backup directory is available and make the actual backup
    verbose "Creating today's directry: ${todays_dir}"
    mkdir -p "${todays_dir}"

    if pg_dump -U "${username}" -d "${db}" -w | gzip -9 > "${todays_dir}/${backupTime}-${db}.sql.gz"; then
      success "${todays_dir}/${backupTime}-${db}.sql.gz created"
      _safeExit_ 0
    else
      error "Failed to create backup"
      _safeExit_ 1
    fi

  }

  _rotateOld_ && _doBackup_


} # end _mainScript_

################ begin shared functions

_safeExit_() {
  # DESC: Cleanup and exit from a script
  # ARGS: $1 (optional) - Exit code (defaults to 0)
  # OUTS: None

  if [[ -d "${script_lock-}" ]]; then
    if command rm -rf "${script_lock}"; then
      verbose "Removing script lock"
    else
      warning "Script lock could not be removed. Try manually deleting ${tan}'${lock_dir}'${red}"
    fi
  fi

  if [[ -n "${tmpDir-}" && -d "${tmpDir-}" ]]; then
    if [[ ${1-} == 1 && -n "$(ls "${tmpDir}")" ]]; then
      if _seekConfirmation_ "Save the temp directory for debugging?"; then
        cp -r "${tmpDir}" "${tmpDir}.save"
        notice "'${tmpDir}.save' created"
      fi
      command rm -r "${tmpDir}"
    else
      command rm -r "${tmpDir}"
      verbose "Removing temp directory"
    fi
  fi

  trap - INT TERM EXIT
  exit ${1:-0}
}

_trapCleanup_() {
  # DESC:  Log errors and cleanup from script when an error is trapped
  # ARGS:   $1 - Line number where error was trapped
  #         $2 - Line number in function
  #         $3 - Command executing at the time of the trap
  #         $4 - Names of all shell functions currently in the execution call stack
  #         $5 - Scriptname
  #         $6 - $BASH_SOURCE
  # OUTS:   None

  local line=${1-} # LINENO
  local linecallfunc=${2-}
  local command="${3-}"
  local funcstack="${4-}"
  local script="${5-}"
  local sourced="${6-}"

  funcstack="'$(echo "$funcstack" | sed -E 's/ / < /g')'"

  if [[ "${script##*/}" == "${sourced##*/}" ]]; then
    fatal "${7-} command: '$command' (line: $line) [func: $(_functionStack_)]"
  else
    fatal "${7-} command: '$command' (func: ${funcstack} called at line $linecallfunc of '${script##*/}') (line: $line of '${sourced##*/}') "
  fi

  _safeExit_ "1"
}

### VARIABLES ###

now=$(LC_ALL=C date +"%m-%d-%Y %r")                   # Returns: 06-14-2015 10:34:40 PM
datestamp=$(LC_ALL=C date +%Y-%m-%d)                  # Returns: 2015-06-14
hourstamp=$(LC_ALL=C date +%r)                        # Returns: 10:34:40 PM
timestamp=$(LC_ALL=C date +%Y%m%d_%H%M%S)             # Returns: 20150614_223440
today=$(LC_ALL=C date +"%m-%d-%Y")                    # Returns: 06-14-2015
longdate=$(LC_ALL=C date +"%a, %d %b %Y %H:%M:%S %z") # Returns: Sun, 10 Jan 2016 20:47:53 -0500
gmtdate=$(LC_ALL=C date -u -R | sed 's/\+0000/GMT/')  # Returns: Wed, 13 Jan 2016 15:55:29 GMT

if tput setaf 1 &>/dev/null; then
  bold=$(tput bold)
  white=$(tput setaf 7)
  reset=$(tput sgr0)
  purple=$(tput setaf 171)
  red=$(tput setaf 1)
  green=$(tput setaf 76)
  tan=$(tput setaf 3)
  yellow=$(tput setaf 3)
  blue=$(tput setaf 38)
  underline=$(tput sgr 0 1)
else
  bold="\033[4;37m"
  white="\033[0;37m"
  reset="\033[0m"
  purple="\033[0;35m"
  red="\033[0;31m"
  green="\033[1;32m"
  tan="\033[0;33m"
  yellow="\033[0;33m"
  blue="\033[0;34m"
  underline="\033[4;37m"
fi

_functionStack_() {
  # DESC:   Prints the function stack in use
  # ARGS:   None
  # OUTS:   Prints [function]:[file]:[line]
  # NOTE:   Does not print functions from the alert class
  local _i
  funcStackResponse=()
  for ((_i = 1; _i < ${#BASH_SOURCE[@]}; _i++)); do
    case "${FUNCNAME[$_i]}" in "_alert_" | "_trapCleanup_" | fatal | error | warning | verbose | debug | die) continue ;; esac
    funcStackResponse+=("${FUNCNAME[$_i]}:$(basename ${BASH_SOURCE[$_i]}):${BASH_LINENO[$_i - 1]}")
  done
  printf "( "
  printf %s "${funcStackResponse[0]}"
  printf ' < %s' "${funcStackResponse[@]:1}"
  printf ' )\n'
}

_alert_() {
  # DESC:   Controls all printing of messages to log files and stdout.
  # ARGS:   $1 (required) - The type of alert to print
  #                         (success, header, notice, dryrun, debug, warning, error,
  #                         fatal, info, input)
  #         $2 (required) - The message to be printed to stdout and/or a log file
  #         $3 (optional) - Pass '$LINENO' to print the line number where the _alert_ was triggered
  # OUTS:   $logFile      - Path and filename of the logfile
  # USAGE:  [ALERTTYPE] "[MESSAGE]" "$LINENO"
  # NOTES:  If '$logFile' is not set, a new log file will be created
  #         The colors of each alert type are set in this function
  #         For specified alert types, the funcstac will be printed

  local scriptName logLocation logName function_name color
  local alertType="${1}"
  local message="${2}"
  local line="${3-}"

  [ -z ${scriptName-} ] && scriptName="$(basename "$0")"

  if [ -z "${logFile-}" ]; then
    readonly logLocation="${HOME}/logs"
    readonly logName="${scriptName%.sh}.log"
    [ ! -d "$logLocation" ] && mkdir -p "$logLocation"
    logFile="${logLocation}/${logName}"
  fi

  if [ -z "$line" ]; then
    [[ "$1" =~ ^(fatal|error|debug|warning) && "${FUNCNAME[2]}" != "_trapCleanup_" ]] \
      && message="$message $(_functionStack_)"
  else
    [[ "$1" =~ ^(fatal|error|debug) && "${FUNCNAME[2]}" != "_trapCleanup_" ]] \
      && message="$message (line: $line) $(_functionStack_)"
  fi

  if [ -n "$line" ]; then
    [[ "$1" =~ ^(warning|info|notice|dryrun) && "${FUNCNAME[2]}" != "_trapCleanup_" ]] \
      && message="$message (line: $line)"
  fi

  if [[ "${TERM}" != "xterm"* ]] || [ -t 1 ]; then
    # Don't use colors on pipes or non-recognized terminals regardles of alert type
    color=""
    reset=""
  elif [[ "${alertType}" =~ ^(error|fatal) ]]; then
    color="${bold}${red}"
  elif [ "${alertType}" = "warning" ]; then
    color="${red}"
  elif [ "${alertType}" = "success" ]; then
    color="${green}"
  elif [ "${alertType}" = "debug" ]; then
    color="${purple}"
  elif [ "${alertType}" = "header" ]; then
    color="${bold}${tan}"
  elif [[ "${alertType}" =~ ^(input|notice) ]]; then
    color="${bold}"
  elif [ "${alertType}" = "dryrun" ]; then
    color="${blue}"
  else
    color=""
  fi

  _writeToScreen_() {
    # Print to console when script is not 'quiet'
    ("$quiet") \
      && {
        tput cuu1
        return 0
      } # tput cuu1 moves cursor up one line

    echo -e "$(date +"%b %d %R:%S") ${color}$(printf "[%7s]" "${alertType}") ${message}${reset}"
    # if [[ "${alertType}" != "info" ]]; then
    #   echo -e "$(date +"%b %d %R:%S") $(basename "$0"): $(printf "[%7s]" "${alertType}") ${message}" >> /proc/1/fd/1
    # fi
  }
  _writeToScreen_

  _writeToLog_() {
    [[ "$alertType" =~ ^(input|debug) ]] && return 0

    if [[ "${printLog}" == true ]] || [[ "${logErrors}" == "true" && "$alertType" =~ ^(error|fatal) ]]; then
      [[ ! -f "$logFile" ]] && touch "$logFile"
      # Don't use colors in logs
      if command -v gsed &>/dev/null; then
        local cleanmessage="$(echo "$message" | gsed -E 's/(\x1b)?\[(([0-9]{1,2})(;[0-9]{1,3}){0,2})?[mGK]//g')"
      else
        local cleanmessage="$(echo "$message" | sed -E 's/(\x1b)?\[(([0-9]{1,2})(;[0-9]{1,3}){0,2})?[mGK]//g')"
      fi
      echo -e "$(date +"%b %d %R:%S") $(printf "[%7s]" "${alertType}") ${cleanmessage}" >>"${logFile}"
    fi
  }
  _writeToLog_

} # /_alert_

error() { echo -e "$(_alert_ error "${1}" "${2-}")"; }
warning() { echo -e "$(_alert_ warning "${1}" "${2-}")"; }
notice() { echo -e "$(_alert_ notice "${1}" "${2-}")"; }
info() { echo -e "$(_alert_ info "${1}" "${2-}")"; }
success() { echo -e "$(_alert_ success "${1}" "${2-}")"; }
dryrun() { echo -e "$(_alert_ dryrun "${1}" "${2-}")"; }
input() { echo -n "$(_alert_ input "${1}" ${2-})"; }
header() { echo -e "$(_alert_ header "== ${1} ==" ${2-})"; }
die() { echo -e "$(_alert_ fatal "${1}" ${2-})"; _safeExit_ "1" ; }
fatal() { echo -e "$(_alert_ fatal "${1}" ${2-})"; _safeExit_ "1" ; }
debug() {
  ($verbose) \
    && {
      echo -e "$(_alert_ debug "${1}" "${2-}")"
    } \
    || return 0
}

verbose() {
  ($verbose) \
    && {
      echo -e "$(_alert_ debug "${1}" ${2-})"
    } \
    || return 0
}

################ end shared functions

# Set initial flags
quiet=false
printLog=true
logErrors=true
verbose=false
force=false
dryrun=false
declare -a args=()

_usage_() {
  cat <<EOF

  ${bold}$(basename "$0") [OPTION]... [FILE]...${reset}

  Run this script inside a docker container running Postgres to create
  backups of the current database

  ${bold}Options:${reset}

    -h, --help        Display this help and exit
    -l, --log         Print log to file with all log levels
    -L, --noErrorLog  Default behavior is to print log level error and fatal to a log. Use
                      this flag to generate no log files at all.
    -q, --quiet       Quiet (no output)
    -v, --verbose     Output more information. (Items echoed to 'verbose')
    --force           Skip all user interaction.  Implied 'Yes' to all actions.
EOF
}

_parseOptions_() {
  # Iterate over options
  # breaking -ab into -a -b when needed and --foo=bar into --foo bar
  optstring=h
  unset options
  while (($#)); do
    case $1 in
      # If option is of type -ab
      -[!-]?*)
        # Loop over each character starting with the second
        for ((i = 1; i < ${#1}; i++)); do
          c=${1:i:1}
          options+=("-$c") # Add current char to options
          # If option takes a required argument, and it's not the last char make
          # the rest of the string its argument
          if [[ $optstring == *"$c:"* && ${1:i+1} ]]; then
            options+=("${1:i+1}")
            break
          fi
        done
        ;;
      # If option is of type --foo=bar
      --?*=*) options+=("${1%%=*}" "${1#*=}") ;;
      # add --endopts for --
      --) options+=(--endopts) ;;
      # Otherwise, nothing special
      *) options+=("$1") ;;
    esac
    shift
  done
  set -- "${options[@]}"
  unset options

  # Read the options and set stuff
  while [[ ${1-} == -?* ]]; do
    case $1 in
      -h | --help)
        _usage_ >&2
        _safeExit_
        ;;
      -L | --noErrorLog) logErrors=false ;;
      -v | --verbose) verbose=true ;;
      -l | --log) printLog=true ;;
      -q | --quiet) quiet=true ;;
      --force) force=true ;;
      --endopts)
        shift
        break
        ;;
      *) die "invalid option: '$1'." ;;
    esac
    shift
  done
  args+=("$@") # Store the remaining user input as arguments.
}

# Initialize and run the script
trap '_trapCleanup_ $LINENO $BASH_LINENO "$BASH_COMMAND" "${FUNCNAME[*]}" "$0" "${BASH_SOURCE[0]}"' \
  EXIT INT TERM SIGINT SIGQUIT
set -o errtrace                           # Trap errors in subshells and functions
set -o errexit                            # Exit on error. Append '||true' if you expect an error
set -o pipefail                           # Use last non-zero exit code in a pipeline
# shopt -s nullglob globstar              # Make `for f in *.txt` work when `*.txt` matches zero files
IFS=$' \n\t'                              # Set IFS to preferred implementation
# set -o xtrace                           # Run in debug mode
set -o nounset                            # Disallow expansion of unset variables
# [[ $# -eq 0 ]] && _parseOptions_ "-h"   # Force arguments when invoking the script
_parseOptions_ "$@"                       # Parse arguments passed to script
# _makeTempDir_ "$(basename "$0")"        # Create a temp directory '$tmpDir'
# _acquireScriptLock_                     # Acquire script lock
_mainScript_                              # Run script
_safeExit_                                # Exit cleanly