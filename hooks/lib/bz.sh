#!/bin/bash -x
## @file bz.sh
## Helpful functions to handle bugzilla service interactions
source conf.sh
source tools.sh


#####
## @fn bz.get_bug()
## @brief Get's the bug_id bug json information from cache, or if not cached,
## from the server.
## @param bug_id id of the bug to retrieve
## @retval 0
bz.get_bug(){
    declare OPTIND
    declare clean_after='false'
    declare bug_id="${1?No bug id issued}"
    declare bug_cache="$(conf.t_get bz_${bug_id}_json)"
    if [[ "$bug_cache" != "" ]] && [[ -f "$bug_cache" ]]; then
        cat "$bug_cache"
    else
        if [[ "$bug_cache" == "" ]]; then
            bug_cache="/tmp/bz_cache.$PPID.${bug_id}.json"
        fi
        bz.py \
            ${BZ_USER:+--bz-user="$BZ_USER"} \
            ${BZ_PASS:+--bz-pass="$BZ_PASS"} \
            Bug.get "ids=[$bug_id]" \
            "extra_fields=[\"flags\", \"external_bugs\"]" \
        | tee "$bug_cache"
        [[ ${PIPESTATUS[0]} == 0 ]] \
        && conf.t_put "bz_${bug_id}_json" "$bug_cache"
    fi
}


######
## @fn bz.update_bug()
## @brief Updates the given bug
## @param bug_id id of the bug to update
## @param data... Each of the post parameters to send (usually as name=value).
## @retval 0 if the bug was updated
## @retval 1 if it was not updated
bz.update_bug(){
    declare bug_id="${1?No bug id passed}"
    shift
    declare -a data="$@"
    local param data rc bug_cache
    local error=0
    res="$(bz.py \
            --bz-user="$BZ_USER" \
            --bz-pass="$BZ_PASS" \
            Bug.update \
            "ids=[$bug_id]" \
            "${data[@]}" \
        | tee /tmp/update_bug_log.${bug_id} \
    )"
    if [[ $res =~ ^ERROR ]]; then
        tools.log "Error while updating bug #${bug_id}"
        tools.log "$res"
        error=1
    else
        rm -f "/tmp/update_bug_log.${bug_id}"
    fi
    ## clean the old bug data from all caches, if any
    rm -f /tmp/bz_cache.*.${bug_id}.*
    return $error
}


######
## @fn bz.is_revert()
## @brief Checks if the given commit is a revert
## @param commit refspec of the commit to check (default=HEAD)
## @retval 0 if the given commit is a revert
## @retval 1 otherwise
bz.is_revert(){
    declare commit=${1:-HEAD}
    local line found
    local revert_regexp='^This reverts commit ([[:alnum:]]+)$'
    pushd "${GIT_DIR?}" &>/dev/null
    while read line; do
        if [[ "$line" =~ $revert_regexp ]]; then
            found='true'
        fi
    done < <( git show "$commit" --quiet --format=%b )
    popd &>/dev/null
    [[ "$found" == "true" ]]
}



######
## @fn bz.get_bug_id()
## @param commit refspec to get the bug from
## @brief Extracts the bug ids from the Bug-Url in the given commit
## @note If the patch is a 'revert', it extracts the bug from
## the reverted commit
bz.get_bug_id(){
    declare commit=${1:-HEAD}
    local line found
    local bug_regexp1='^Bug-Url: (https?://bugzilla\.redhat\.com/)show_bug\.cgi\?id=([[:digit:]]+)$'
    local bug_regexp2='^Bug-Url: (https?://bugzilla\.redhat\.com/)([[:digit:]]+)$'
    local revert_regexp='^This reverts commit ([[:alnum:]]+)$'
    pushd "${GIT_DIR?}" &>/dev/null
    while read line; do
        if [[ "$line" =~ $revert_regexp ]]; then
            commit_id="${BASH_REMATCH[1]}"
            bz.get_bug_id "$commit_id"
            return $?
        fi
        if [[ "$line"  =~ $bug_regexp1 || "$line"  =~ $bug_regexp2 ]]; then
            echo "${BASH_REMATCH[2]}"
            found='true'
        fi
    done < <( git show --quiet "$commit" --format=%b )
    popd &>/dev/null
    [[ "$found" == "true" ]]
}


######
## @fn bz.login()
## @brief Logs into bugzilla if not logged in already.
## @param bz_user User to log into bugzilla
## @param bz_password Password
##
## @code
## Options:
##     -b bug_id
##       If you pass a bug_id, the token for that bug will already be set and
##       cached for further reference
##
##     -s server_url
##       Use that url instead of the one in the config file
##       (https://bugzilla.redhat.com by default)
##
## Configuration parameters:
##    bugzilla_server
##      full url to the bugzilla server
## @endcode
bz.login(){
    declare bz_user
    declare bz_password
    local server_url="$(conf.get 'bugzilla_server' 'https://bugzilla.redhat.com')"
    local OPTIND bug_id json_bug
    while getopts "s:b:" option; do
        case $option in
            s) server_url="$OPTARG";;
            b)
                bug_id="$OPTARG"
                json_bug="/tmp/bz_cache.$PPID.${bug_id}.json"
                conf.t_put "bz_${bug_id}_json" "$json_bug"
                tools.log "Getting bug $bug_id into $json_bug"
                ;;
        esac
    done
    shift $((OPTIND - 1))
    declare bz_user="${1?No user passed}"
    declare bz_password="${2?No password passed}"
    [[ "$bz_user" == "" ]] && { echo "No use supplied"; return 1; }
    [[ "$bz_password" == "" ]] && { echo "No password supplied"; return 1; }
    ## Login for us is just trying to do a request and not getting error
    res="$(bz.py \
        --bz-user "$bz_user" \
        --bz-pass "$bz_password" \
        Bug.get "ids=[$bug_id]" \
        "extra_fields=[\"flags\", \"external_bugs\"]" \
    )"
    [[ "$res" =~ ^LOGIN\ ERROR.* ]] \
    && {
        tools.log "::bz.login::Failed to log in\n $res" >&2
        return 1
    }
    [[ -n "$json_bug" ]] && echo "$res" >"$json_bug"
    return 0
}


######
## @fn bz.get_bug_flags()
## @param bugid Id of the bug to get the flags from
## @brief Retrieves all the '+' flags of the given bug
bz.get_bug_flags(){
    local bugid=${1?}
    local wanted_status="${2:-+}"
    local line fname
    local status_regexp='"status": \"(.)\"'
    local flag_regexp='"name": "([^\"].*)"'
    while read line; do
        if [[ "$line" =~ $flag_regexp ]]; then
            if [[ "$status" == "$wanted_status" ]]; then
                echo "${BASH_REMATCH[1]}"
            fi
        elif [[ "$line" =~ $status_regexp ]]; then
            status="${BASH_REMATCH[1]}"
        fi
    done < <( bz.get_bug "$bugid" | grep -aPz "\"flags\": \[.*(\n[^]]*)*\]" )
}


######
## @fn bz.get_bug_status()
## @param bugid Id of the bug to retrieve
## @brief Retrieves the current status of the bug
bz.get_bug_status(){
    declare bugid=${1?}
    bz.get_bug "$bugid" \
    | grep -Po '"status": "\K[^"]{2,}+'
}


######
## @fn bz.check_flags()
## @param bugid Id of the bug to check the flags for
## @param flagspecs... can be a single flag or a sequence ot flags separated by
## '|' to express that those flags are interchangeable, for example
## flag2|flag2_bis
## @brief Checks that all the flags exist with '+' in the given bug
bz.check_flags(){
    declare bug_id="${1?No bug id passed}"
    shift
    declare flagspecs=("$@")
    local flags missing_flags and_flag found or_flag
    ## Check the flags
    flags=($(bz.get_bug_flags $bug_id))
    missing_flags=""
    ## Flags are defined like this: flag1|flag2 flag3
    ## That means fag1 or flag2 are required and flag3 is required
    ## ' ' -> and, '|' -> or
    for and_flag in "${flagspecs[@]}"; do
        found=0
        for or_flag in ${and_flag//|/ }; do
            if tools.is_in "$or_flag" "${flags[@]}" >/dev/null; then
                found=1
            fi
        done
        if [[ $found -eq 0 ]]; then
            missing_flags="${missing_flags:+$missing_flags, }$and_flag"
        fi
    done
    if [[ "$missing_flags" != "" ]]; then
        echo -e "No ${missing_flags} flag/s"
        return 1
    fi
    echo -e "OK"
    return 0
}


######
## @fn bz.add_tracker()
## @param bug_id Id of the bug to update
## @param tracker_id This is the internal tracker id that bugzilla assigns to
## each external tracker (RHEV gerrit -> 82, oVirt gerrit -> 81)
## @param external_id Id for the bug in the external tracker
## @param description Description to add to the external tracker
## @brief Add a new external bug to the external bugs list
bz.add_tracker(){
    declare bug_id="${1?}"
    declare tracker_id="${2?}"
    declare external_id="${3?}"
    declare description="${4}"
    local status="${5}"
    local branch="${6}"
    local externals="{"
    externals+="\"ext_bz_bug_id\": \"$external_id\""
    externals+=", \"ext_type_id\": \"$tracker_id\""
    externals+="${description:+, \"ext_description\": \"$description\"}"
    externals+="${status:+, \"ext_status\": \"$status\"}"
    externals+="${branch:+, \"ext_priority\": \"$branch\"}"
    externals+="}"
    bz.py \
        ${BZ_USER:+--bz-user $BZ_USER} \
        ${BZ_PASS:+--bz-pass $BZ_PASS} \
        ExternalBugs.add_external_bug \
        "bug_ids=[$bug_id]" \
        "externa_bugs=[$externals]" \
        >/dev/null \
    || bz.py \
        ${BZ_USER:+--bz-user $BZ_USER} \
        ${BZ_PASS:+--bz-pass $BZ_PASS} \
        ExternalBugs.update_external_bug \
        "$externals"
}

## @fn bz.update_fixed_in_version()
## @brief Update fixed in version field
## @param bug_id Id of the bug to update
## @param fixed_in_version New value for the fixed in version field
bz.update_fixed_in_version(){
    declare bug_id="${1?}"
    declare fixed_in_version="${2?}"
    bz.update_bug \
        "$bug_id" \
        "cf_fixed_in=${fixed_in_version}"
}


## @fn bz.update_status_and_version()
## @brief Update fixed in version field plus the status field
## @param bug_id Id of the bug to update
## @param bug_status New value for the status field
## @param fixed_in_version New value for the fixed in version field
## @param resolution New value for the resolution
bz.update_status_and_version(){
    declare bug_id="${1?}"
    declare bug_status="${2?}"
    declare fixed_in_version="${3?}"
    declare resolution="${4}"
    bz.update_bug \
        "$bug_id" \
        "status=${bug_status}" \
        "cf_fixed_in=${fixed_in_version}" \
        ${resolution:+"resolution=$resolution"}
}

######
## @fn bz.update_status()
## @param bug_id Id of the bug to update
## @param new_status New status to set the bug to, only the allowed
## transitions will end in a positive result (return code 0)
## @param commit_id Id of the commit that should change the status of this bug
## @param resolution In case that the status is CLOSED, the resolution is
## needed
##
## @code
##  Legal status transitions:
##    NEW|ASSIGNED|MODIFIED -> POST
##    POST -> MODIFIED
##
##  If it's a revert any source status is allowed
## @endcode
bz.update_status(){
    declare bug_id="${1?}"
    declare new_status="${2?}"
    declare commit_id="${3}"
    declare resolution="${4}"
    local current_status="$(bz.get_bug_status "$bug_id")"
    if [[ $new_status == "CLOSED" ]] && [[ -z $resolution ]]; then
        resolution="$3"
        commit_id=""
    fi
    if [[ "$current_status" == "$new_status" ]]; then
        echo "already on $new_status"
        return 0
    fi
    if [[ -n "$commit_id" ]] && ! bz.is_revert "$commit_id"; then
        case $current_status in
            ASSIGNED|NEW|MODIFIED)
                if [[ "$new_status" != "POST" ]]; then
                    echo "illegal change from $current_status"
                    return 1
                fi
                ;;
            POST)
                if [[ "$new_status" != "MODIFIED" ]]; then
                    echo "illegal change from $current_status"
                    return 1
                fi
                ;;
            *)
                echo "illegal change from $current_status"
                return 1
        esac
    fi
    bz.update_bug \
        "$bug_id" \
        "status=${new_status}" \
        ${resolution:+"resolution=$resolution"}
}


######
## @fn bz.get_external_bugs()
## @param bug_id Id of the parent bug
## @param external_name External string to get the bugs from. If none given it
## will get all the external bugs.
##      Usually one of:
##        - oVirt gerrit
##        - RHEV gerrit
bz.get_external_bugs(){
    declare bugid=${1?}
    declare external_name="${2}"
    local line fname
    local desc_regexp='"description": \"([^\"]*)\",'
    local bugid_regexp='"ext_bz_bug_id": "([^\"]*)"'
    while read line; do
        if [[ "$line" =~ $desc_regexp ]]; then
            desc="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ $bugid_regexp ]]; then
            exbugid="${BASH_REMATCH[1]}"
            if [[ -z $external_name ]] \
            || [[ "$external_name" == "$desc" ]]; then
                echo "$exbugid"
                desc=''
            fi
        fi
    done < <( bz.get_bug "$bugid" | grep -aoPz "\"external_bugs\": \[\n\K([^]]*\n)*" )
}


######
## @fn bz.clean()
## @brief Cleans up all the cached config and data. Make sure that your last
## scripts calls it before exitting
bz.clean(){
    rm -f /tmp/bz_cache.$PPID.*
    conf.t_clean
}


######
## @fn bz.get_product()
## @param bug_id Id of the bug to get info about
## @brief Prints the product name of the given bug
bz.get_product(){
    local bug_id="${1?}"
    bz.get_bug "$bug_id" \
    | grep -Po '(?<="product": ")[^"]*'
}


######
## @fn bz.get_classification()
## @param bug_id Id of the bug to get info about
## @brief Print the classification of the given bug
bz.get_classification(){
    declare bug_id="${1?}"
    bz.get_bug "$bug_id" \
    | grep -Po '(?<="classification": ")[^"]*'
}


######
## @fn bz.is_private()
## @param bug_id Id of the bug to check
## @retval 0 if it's private
## @retval 1 otherwise
bz.is_private(){
    declare bug_id="${1?}"
    local BZU=$BZ_USER
    local BZP=$BZ_PASS
    unset BZ_USER BZ_PASS
    bz.get_bug "$bug_id" &>/dev/null
    rc=$?
    export BZ_USER=$BZU BZ_PASS=$BZP
    [[ $rc -eq 0 ]] && return 1
    return 0
}


######
## @fn bz.get_target_milestone()
## @param bug_id Id of the bug to get info about
## @brief Print the target milestone of the bug
bz.get_target_milestone(){
    local bug_id="${1?}"
    local tm="$(bz.get_bug "$bug_id" \
        | grep -Po '(?<="target_milestone": ")[^"]*'
    )"
    echo $tm
}


######
## @fn bz.get_target_release()
## @param bug_id Id of the bug to get info about
## @brief Print the target release of the bug
bz.get_target_release(){
    local bug_id="${1?}"
    local tr="$(bz.get_bug "$bug_id" \
        | grep -oPz "\"target_release\": \[\n\s*\"\K([^]\n\"]*)*" \
    )"
    echo $tr
}


######
## @fn bz.check_target_release()
## @param bug_id Id of the bug to check the target_release of
## @param branch Name of the current branch
## @param tr_match Tuple in the form 'branch_name|[!]regexp'
## @param branch_name name of the branch that should check the regexp
## @code
##       [!]regexp
##           regular expresion to match the target release against, if preceded
##            with '!' the expression will be negated
## @endcode
## @retval 1 if the target release and branch defined in tr_match
## configuration variable do not match the given bug's target release
##
## @code
## Example:
##
##  bz.check_target_release 1234 master 'master|3\.3.*' 'master|!3\.[21].*'
##
##  That will check that the bug 1234 target release matches:
##       3\.3.*
##   And does not match:
##       3\.3\.0\..*
##
##   So 3.3.0 or 3.3 will pass but 3.2 and 3.3.0.1 will not
## @endcode
##
bz.check_target_release(){
    local bug_id="${1?}"
    local branch="${2?}"
    local br_reg_pairs=("${@:3}")
    local hdr="::bug $bug_id::bz.check_target_release::"
    locas res
    ## Check if the target_release should be checked
    for br_reg in "${br_reg_pairs[@]}"; do
        if ! [[ $br_reg =~ ^${branch}\|.* ]]; then
            #not for this branch
            continue
        fi
        echo "${hdr}TR has to match $br_reg" >&2
        regexp="${br_reg#*|}"
        target_release="$(bz.get_target_release "$bug_id")"
        tools.match "$target_release" "$regexp"
        case $? in
            $TOOLS_SHOULD_NOT_MATCH)
                echo "${hdr}target release should not match match" \
                     "$regexp but it is $target_release" >&2
                echo "$target_release should not match $regexp"
                return 1
                ;;
            $TOOLS_DOES_NOT_MATCH)
                echo "${hdr}target release should match $regexp but" \
                     "it is $target_release" >&2
                echo "$target_release should match $regexp"
                return 1
                ;;
        esac
        echo "${hdr}Bug tr matches $regexp, it's $target_release" >&2
        echo "$target_release"
    done
    return 0
}


######
## @fn bz.check_target_milestone()
## @param bug_id Id of the bug to get the target_milestone from
## @param branch Name of the current branch
## @param tm_match Tuple in the form `branch_name|[!]regexp`
## @param branch_name name of the branch that should check the regexp
## @code
##       [!]regexp
##           regular expresion to match the target milestone against, if preceded
##            with '!' the expression will be negated
## @endcode
##
## @code
## Example:
##
##   bz.check_target_milestone 1234 master 'master|3\.3.*' 'master|!3\.[21].*'
##
##   That will check that the bug 1234 target milestone matches:
##       3\.3.*
##   And does not match:
##       3\.3\.0\..*
##
##   So 3.3.0 or 3.3 will pass but 3.2 and 3.3.0.1 will not
## @endcode
##
## @retval 1 if the target milestone and branch defined in tm_match
## configuration variable do not match the given bug's target milestone
bz.check_target_milestone(){
    local bug_id="${1?}"
    local branch="${2?}"
    local br_reg_pairs=("${@:3}")
    local hdr="::bug $bug_id::bz.check_target_milestone::"
    local res
    ## Check if the target_milestone should be checked
    for br_reg in "${br_reg_pairs[@]}"; do
        if ! [[ $br_reg =~ ^${branch}\|.* ]]; then
            #not for this branch
            continue
        fi
        echo "${hdr}TM has to match $br_reg" >&2
        regexp="${br_reg#*|}"
        target_milestone="$(bz.get_target_milestone "$bug_id")"
        tools.match "$target_milestone" "$regexp"
        case $? in
            $TOOLS_SHOULD_NOT_MATCH)
                echo "${hdr}target milestone should not match match" \
                     "$regexp but it is $target_milestone" >&2
                echo "$target_milestone should not match $regexp"
                return 1
                ;;
            $TOOLS_DOES_NOT_MATCH)
                echo "${hdr}target milestone should match $regexp but" \
                     "it is $target_milestone" >&2
                echo "$target_milestone should match $regexp"
                return 1
                ;;
        esac
        echo "${hdr}Bug tm matches $regexp, it's $target_milestone" >&2
        echo "$target_milestone"
    done
    return 0
}
