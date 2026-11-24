#!/bin/sh
DEBUG=

DEFAULT_PW_LENGTH=32
AUTH_DIR="d.auth-mcgee"
AUTH_FILE="${AUTH_DIR}/auth"
DATA_DIR="${AUTH_DIR}/data"

SPECIAL_FILE="${AUTH_DIR}/special"
SPECIAL_LIST_DEFAULT='!@#$%^&*()_+=[]-'
SPECIAL_LIST_PREFIX="A-Za-z0-9"

g_inputPw=
g_finalPw=

# Globals used for editing and lisitng entries
# in order: label, service, username, email, password
g_data0=
g_data1=
g_data2=
g_data3=
g_data4=


# dependncies (yucky, impure, embarrassing):
#   gpg
#   base64
#   argon2


# -> cat substitute stolen from cate
_cat() {
    while IFS= read -r p || [ "$p" ]; do
	printf '%s\n' "$p"
    done
}

# -> clear if not debugging
_clear(){
    if [ -z "$DEBUG" ]; then
	clear
    fi
}


#ARG: 1=string to be checked
#RET: is number -> empty
#     is not    -> 1
_isNumber() {
    case ${1-} in
        ''|*[!0-9+-]*) return 1 ;;
        +*) case ${1#+} in ''|*[!0-9]*) return 1 ;; esac ;;
        -*) case ${1#-} in ''|*[!0-9]*) return 1 ;; esac ;;
        *)  case ${1-} in *[!0-9]*) return 1 ;; esac ;;
    esac
    return 0
}


#ARG: 1=string to be hashed
#RET: hashed string
_hash(){ printf '%s' "$(printf '%s' "$1" | argon2 "$USER" -id -r -t 6 -m 17)"; }


#ARG: 1=string to check
#RET: success->input string, failure->empty
_isStringValid(){ printf '%s' "$(printf '%s\n' "$1" | LC_ALL=C grep -E '^[A-Za-z0-9!@#$%^&*()_+=-]+$')"; }


#ARG: 1=first string, 2=second string
#RET: success->empty, failure->"1"
_isPwSame(){ if [ -n "$1" ] && [ "$1" != "$2" ]; then printf '1'; fi; }


#ARG: 1=text file
#RET: first line of file, no linefeed
#_readFirstLine(){ printf '%s' "$( _cat < "$1" | head -n 1)"; }
_readFirstLine(){
    while IFS= read -r __rfLine || [ "$__rfLine" ]; do
	printf '%s' "$__rfLine"
	break
    done < "$1"
}


# Exit if special file is missing/cannot be created
_checkSpecialFile(){
    if [ ! -e "$SPECIAL_FILE" ]; then
	printf '%s' "$SPECIAL_LIST_DEFAULT" >> "$SPECIAL_FILE"
	if [ ! -e "$SPECIAL_FILE" ]; then
	    printf '%s\n' "[Error] special file can't be created. rip"; exit 1
	else
	    printf '%s\n' "[Info] special file created"
	fi
    fi
}


#ARG: 1=length
#RET: random string of length $1, using only chars listed in special file
_randomPw(){
    _checkSpecialFile    
    __rpSpecialList="$(_readFirstLine "$SPECIAL_FILE")"
    printf '%s' "$( _cat < /dev/urandom | tr -dc "$__rpSpecialList" | fold -w "$1" | head -n 1 )"
}


# -> Print error message
_printInvalid(){ printf '%s\n' "[Error] invalid. allowed chars: A-Za-z0-9!@#$%^&*()_+=-" ;}


#ARG: 1=string
#RET: string with space between each char
# -> "test" -> "t e s t"
_spacedString(){
    __ssInputString="$1"
    __ssResult=
    while [ -n "$__ssInputString" ]; do
	__ssResult="$__ssResult ${__ssInputString%"${__ssInputString#?}"}"
	__ssInputString="${__ssInputString#?}"
    done
    __ssResult="${__ssResult#?}"
    printf '%s' "$__ssResult"
}


#ARG: 1=string 2=spacer_length 3=char[ ]
#RET: returns string of spaces (or specified char) which is needed to reach
#     desired width when combined with input string
_spacer(){
    if [ "$#" -lt 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
	printf '%s' "[Error] _spacer: missing args"; exit 1
    fi

    if [ "${#3}" -gt 1 ]; then
	printf '%s' "[Error] _spacer: \$3 can't be longer than 1"; exit 1
    fi
    
    __spInputString="$1"
    __spChar="${3:- }"
    __spResult=
    __spIndex="$(expr "$2" - "${#__spInputString}")"

    while [ "$__spIndex" -gt 0 ]; do
	__spResult="$__spResult$__spChar"
	__spIndex="$((__spIndex - 1))"
    done

    printf '%s' "$__spResult"
}


#ARG: 1=space separated string, 2=index (starting at 1)
#RET: value at the indexed position
# -> 1="beep boop bap", 2="2" -> RET:"boop"
_retrieveSubstringUsingIndex(){
    __rsInputString="$1"
    __rsIndex="$2"
    set f-
    __rsI=1
    for __subString in $__rsInputString; do
	if [ "$__rsI" = "$__rsIndex" ]; then
	    printf '%s' "$__subString"
	    return
	fi
	__rsI="$((__rsI + 1))"
    done
    printf '%s' "[Error] _retrieveSubstringUsingIndex: index out of range"
    set f+
}


#ARG: 1=string
#RET: 2=base64 encoded string
_base64enc(){
    printf '%s' "$(printf '%s' "$1" | base64 -w 0 -)"
}


#ARG: 1=base64 encoded string
#RET: 2=decoded string
_base64dec(){
    printf '%s' "$(printf '%s' "$1" | base64 -d -)"
}


#ARG: 1=string, 2=password
#RET: string encrypted using gpg with password
_encrypt() {
    printf '%s' "$1" | gpg --batch --pinentry-mode loopback --passphrase "$2" --armor --symmetric --output - 2> /dev/null
}


#ARG: 1=string, 2=password
#RET: string decrypted using gpg with password
_decrypt() {
    printf '%s' "$1" | gpg --batch --pinentry-mode loopback --passphrase "$2" --decrypt --output - 2> /dev/null
}


#ARG: 1=label of entry, 2=encrypted name or url of service
#     3=encrypted username,  4=encrypted email, 5=encrypted password
#RET : path to file
_storeEntry(){
    if [ -z "$1" ]; then
	printf '%s\n' "[Error] _storeEntry: label cannot be empty"
	return 1
    fi
    
    # Ensure data directory is present
    if ! [ -d "$DATA_DIR" ]; then
	if ! mkdir -p "$DATA_DIR"; then
	    printf '%s\n' "[Error] _storeEntry: could not create data directory"
	    return 2
	fi
    fi

    # Set filepath
    # -> filename is base64 encoded for no particular reason. i just like base64.
    #    however i could claim it's to allow spaces in labels and the files
    #    don't immediately show what their label is. secure against people
    #    who don't know how to decode base64
    __seFile="$(_base64enc "$1")"
    __seFilePath="${DATA_DIR}/'$__seFile'"

    # Check if filename is available
    if [ -e "$__seFilePath" ]; then
	printf '%s' "[Error] _storeEntry: filename unavailable"; return 3
    fi
    
    # Encrypt and assign fields
    __seUrlService="$(_encrypt "$2" "$g_inputPw")"
    __seUsername="$(_encrypt "$3" "$g_inputPw")"
    __seEmail="$(_encrypt "$4" "$g_inputPw")"
    __sePassword="$(_encrypt "$5" "$g_inputPw")"

    # Create empty file
    : > "$__seFilePath"

    # Write data to file
    {
	printf '%s\n' "$(_base64enc "${__seUrlService}")";\
	    printf '%s\n' "$(_base64enc "${__seUsername}")";\
	    printf '%s\n' "$(_base64enc "${__seEmail}")";\
	    printf '%s\n' "$(_base64enc "${__sePassword}")" 
    } >>   "$__seFilePath"

    # Return filepath
    printf '%s'  "$__seFilePath"
    return 0
}


#ARG: 1=non-base64 filename
# -> decodes, decrypts and prints entry contents
_listEntries_loadEntry(){
    __lelFilename="$1"

    # Check if globals (g_data*) should be printed instead
    if [ -n "$2" ]; then
	__lelPrintGlobals=1
    else
	__lelPrintGlobals=
    fi
    
    # Strip path and single quotes
    __lelFilenameStripped="$(basename "$__lelFilename")"
    __lelFilenameStripped="${__lelFilenameStripped#?}"
    __lelFilenameStripped="${__lelFilenameStripped%?}"
    
    # Save label field for editing entry
    g_data0="$(_base64dec "$__lelFilenameStripped")"

    # Labels for lines
    set --\
	"1. service : " \
	"2. username: " \
	"3. email   : " \
	"4. password: "

    # Read contents of entry
    __lelContents="$(_cat < "$__lelFilename")"
    __lelLineNumber=0

    # Print entry label
    printf '%s\n' "0. label   : $g_data0"
    
    # Decode and decrypt each line, print with corresponding label
    for __lelLine in $__lelContents; do
	__lelFieldIndex="$((__lelLineNumber + 1))"

	# Globals and their meaning
	#   label    : g_data0
	#   service  : g_data1
	#   username : g_data2
	#   email    : g_data3
	#   password : g_data4
	
	# Check if globals should be printed instead of laboriously decoding and decrypting
	if [ -z "$__lelPrintGlobals" ]; then
	    __lelLineDecoded="$(_base64dec "$__lelLine")"
	    __lelLineDecrypted="$(_decrypt "$__lelLineDecoded" "$g_inputPw")"

	    # Save field into corresponding global
	    # Used for editing entries and for faster printing
	    eval "g_data$__lelFieldIndex='$__lelLineDecrypted'"

	    # Print decoded/decrypted value 
	    printf '%s\n' "$1$__lelLineDecrypted"
	else
	    # Print value stored in global
	    eval "printf '%s\n' \"\$1\$g_data$__lelFieldIndex\""
	fi
	
	shift
	__lelLineNumber="$((__lelLineNumber + 1))"
    done

    # Check if number of lines is correct
    if [ "$__lelLineNumber" -lt 4 ]; then
	printf '%s\n' "[Error] _listEntries_loadEntry: save file is missing lines"
    fi
}


#ARG: 1=non base64 filename 2=variable name without the $ to store result in
# -> replaces entry file with new one
#    uses fields stored in g_data[0-4] as new content
#    (encoded and encrypted)
# TODO deletes file before checking if saving is even possible. so might just delete entry entirely :/
_listEntries_options_edit_save(){
    # Ensure new filename isn't already present in data directory
    if ! [ -e "${DATA_DIR}/$(_base64enc "$g_data0")" ]; then
	printf '%s' "are you sure you want to save the changes? [N/y]: "
	read -r __leoesSaveChoice

	case "$__leoesSaveChoice" in
	    y|Y|yes|YES|Yes)
		# Globals and their meaning
		#   label    : g_data0
		#   service  : g_data1
		#   username : g_data2
		#   email    : g_data3
		#   password : g_data4

		# Delete old file
		# Create new file filled with values from globals
		if rm -f "${DATA_DIR}/'$1'"; then
		    __leoesStoreResult="$(_storeEntry "$g_data0" "$g_data1" "$g_data2" "$g_data3" "$g_data4")"
		    case "$?" in
			1) printf '%s\n' "[Error] saving failed. label cannot be empty";;
			2) printf '%s\n' "[Error] saving failed. directory could not be created. \
this shouldn't be a possible return code.";;
			3) printf '%s\n' "[Error] saving failed. filename/label unavailable";;
			*)
			    __leoesFilenameStripped="$(basename "$__leoesStoreResult")"
			    __leoesFilenameStripped="${__leoesFilenameStripped#?}"
			    __leoesFilenameStripped="${__leoesFilenameStripped%?}"
			    eval "$2=$__leoesFilenameStripped"
			    printf '%s'   "[Info] changes saved in $__leoFilename"
			    ;;
		    esac

		    # Pass exit code onto callee
		    return "$?"
		else
		    printf '%s\n' "[Error] old entry couldn't be deleted. saving failed"
		fi
		;;
	    *)
		printf '%s\n' "[Info] not saving"
		;;
	esac
    else
	printf '%s\n' "[Error] filename/label unavailable"
    fi
}


#ARG: 1=index of field 2=name of 
# -> change value of a field
# -> store in corresponding g_data variable
_listEntries_options_edit_changeField(){
    # Print prompt to enter new value, displaying the current value as default
    eval "printf '%s' \"enter new value [\$g_data$1] (q to quit input): \""
    __leoecFieldInput=
    read -r __leoecFieldInput

    # Check if input is quitting or empty
    if [ "$__leoecFieldInput" != "q" ] && [ -n "$__leoecFieldInput" ]; then

	eval "g_data$1='$__leoecFieldInput'"

	# Print current summary of fields after editing
	__leoecFieldLabels="label service username email password"
	__leoecFieldIndex=0
	for __leoecFieldLabel in $__leoecFieldLabels; do
	    printf '%s\n' "${__leoecFieldIndex}. \
$__leoecFieldLabel$(_spacer "$__leoecFieldLabel" 8): \
$(eval "printf '%s' \"\$g_data$__leoecFieldIndex\" ")"
	    __leoecFieldIndex="$((__leoecFieldIndex + 1))"
	done
	return 0
    else
	printf '%s\n' "[Info] field unchanged"
	return 1
    fi
}


#ARG: 1=base64 filename
# -> deletes entry after asking for confirmation
_listEntries_options_delete(){
    printf '%s' "type 'DELETE' to delete entry. anything else to abort: "; read -r __leoConfirmation
    if [ "$__leoConfirmation" = "DELETE" ]; then
	if rm -f "${DATA_DIR}/'$1'"; then
	    printf '%s\n' "[Info] entry deleted"
	else 
	    printf '%s\n' "[Error] deletion failed"
	fi
	
	sleep 1.5
	return 0
    fi
    printf '%s\n' "[Info] aborted deletion"
    return 1
}


#ARG: 1=name of variable to base64 filename
_listEntries_options_edit(){
    printf '%s\n' "----- EDITING -----"
    printf '%s\n' ""
    while :; do
	# Prompt to select field using index
	# or save or quit
     	printf '%s' "select field using index ('q' to quit, 'save' to save): "
	read -r __leoeFieldChoice

	# Call _changeField if input is valid index
	if _isNumber "$__leoeFieldChoice" && \
		[ "${#__leoeFieldChoice}" -eq 1 ] && \
		[ "$__leoeFieldChoice" -ge 0 ] && \
		[ "$__leoeFieldChoice" -le 4 ]; then
	    _listEntries_options_edit_changeField "$__leoeFieldChoice"

	    # Call _save 
	elif [ "$__leoeFieldChoice" = "save" ]; then
	    # Save changes using g_data[0-4]
	    # base64 name of the (potentially renamed) file will be
	    # stored in variable named in $1
	    # unchanged when an error is encountered
	    if _listEntries_options_edit_save "$(eval "printf '%s' \"\$$1\"")" "$1"; then
		break
	    fi
	    sleep 1.5
	    
	    # Break loop when exiting    
	elif [ "$__leoeFieldChoice" = q ]; then
	    break

	    # Print error for everything else
	else
	    printf '%s\n' "[Error] invalid. not a number or or out of range"
	fi
    done
}


#ARG: 1=base64 filename
# -> lists contents of entry and shows menu
# -> options for deletion and editing
_listEntries_options(){
    __leoFilename="$1"

    __leoFirstLoop=
    
    # Menu loop
    while :; do
	# Print contents and menu, read input
	_clear
	printf '%s\n' "main -> list entries -> entry: $(_base64dec "$__leoFilename")"
	printf '%s\n' "loading: ${DATA_DIR}/'$__leoFilename'"
	printf '%s\n' " -- fields -- "
	_listEntries_loadEntry "${DATA_DIR}/'$__leoFilename'" "$__leoFirstLoop"

	# Prevent reading entry file and decoding/decryption for next loop
	# It's much faster. Also not required when data hasn't changed
	if [ -z "$__leoFirstLoop" ]; then
	    __leoFirstLoop=1
	fi

	# Print options
	printf '%s\n' ""
	printf '%s\n' "1. edit"
	printf '%s\n' "9. delete"
	printf '%s\n' "q. quit"
	printf '%s' "option: "; read -r __leoOption

	# Process input
	case "$__leoOption" in
	    # Editing entries
	    # This section exploded into 100% unrefined spaghetti
	    # TODO break it up into smaller, more comprehensible functions 
	    1)
		if _listEntries_options_edit "__leoFilename"; then
		    # Set var  to nothing so file gets read again
		    # and globals filles with original values again
		    # -> Happens when calling _listEntries_loadEntry
		    __leoFirstLoop=
		fi
		;;
	    9)	
		if _listEntries_options_delete "$__leoFilename"; then
		    # Stop viewing entry if it was delete
		    # Return to listing of all entries
		    break
		fi
		;;
	    q)break;;
	    *)printf '%s\n' "[Error] invalid";;
	esac
    done

    # Clear globals
    g_data0=
    g_data1=
    g_data2=
    g_data3=
    g_data4=
}


# -> lists entries found in data directory, shows menu.
#    entries are split into two columns
_listEntries(){
    # Check if data directory exists
    if ! [ -d "$DATA_DIR" ]; then
	printf '%s\n' "[Error] _listEntries: data directory missing"; return
    fi

    
    # Menu loop
    while :; do
	_clear
	__leFileList=
	__leLongestLabel=0

	# Fill file list, determine 
	for __leEntry in ${DATA_DIR}/*; do
	    # Strip path, leaving filename
	    # TODO: use basename?
	    __leFilename="${__leEntry#"${DATA_DIR}/"}"

	    # Strip leading and trailing single quote
	    __leFilename="${__leFilename#?}"
	    __leFilename="${__leFilename%?}"

	    # Add filename to list for menu
	    __leFileList="$__leFileList $__leFilename"

	    # Determine longest label, needed to determine column width of listing
	    __leLabelLength="$(_base64dec "$__leFilename")"
	    __leLabelLength="${#__leLabelLength}"
	    
	    if [ "$__leLabelLength" -gt "$__leLongestLabel" ]; then
		__leLongestLabel="$__leLabelLength"
	    fi
	done
	
	_clear
	printf '%s\n' "main -> list entries"

	# Print two entries on one line, even spacing
	__leI=0
	__leFlipFlop=0
	for __leFile in $__leFileList; do
	    # Increase index, used to select entry
	    __leI="$((__leI + 1))"

	    
	    if [ "$__leFlipFlop" -eq 0 ]; then
		# Decode to get label, hold until next loop
		__leHold="$(_base64dec "$__leFile")"
		__leFlipFlop=1
	    else
		# Print held and current label
		# Prepend index
		# Add spacing
		printf '%s\n' "$((__leI - 1)): $__leHold\
$(_spacer "$__leHold" $((__leLongestLabel + 3)))\
$__leI: $(_base64dec "$__leFile")"
		__leFlipFlop=0
	    fi
	done

	# Print leftover label if present
	# Prepend index
	if [ "$__leFlipFlop" -eq 1 ]; then
	    printf '%s\n' "$__leI: $__leHold"
	fi

	# Print options for menu
	# Read input
	printf '%s\n' ""
	printf '%s\n' "select entry"
	printf '%s\n' "q. quit"
      	printf '%s' "option: "; read -r __leOption

	if _isNumber "$__leOption"; then
	    __leI=1
	    __leFound=

	    # Iterate over file list
	    for __leFile in $__leFileList; do
		# Stop at the selected index
		if [ "$__leI" -eq "$__leOption" ]; then
		    __leFound=1
		    _listEntries_options "$__leFile"
		    break
		fi

		__leI="$((__leI + 1))"
	    done

	    # Print error when index can't be found
	    if [ -z "$__leFound" ]; then
		printf '%s\n' "[Error] index out of range"
		sleep 0.5
	    fi
	elif [ "$__leOption" = "q" ]; then
	    return
	else
	    printf '%s\n' "[Error] invalid"
	    sleep 0.5
	fi
    done
}


# -> set entry password using manual input
_newEntry_desiredPw(){
    _clear
    printf '%s\n' "main -> new entry -> desired password"
    while :; do
	printf '%s' "desired pw: "
	read -r __desPw1; [ "$__desPw1" = "q" ] && return
	
	[ -z "$(_isStringValid "$__desPw1")" ] && { _printInvalid; continue; }
	
	printf '%s' "again     : "
	read -r __desPw2; [ "$__desPw2" = "q" ] && return
	[ -z "$(_isStringValid "$__desPw2")" ] && { _printInvalid; continue; }
	
	printf '%s\n' "[Info] password set"
	
	g_finalPw="$__desPw1"
	break
    done
}


# -> set allowed special characters for password generation
#    using interactive menu
#    save changes to file containing allowed special characters
_newEntry_generatedPw_options(){
    # Check if special file is present
    # Creates it, if not
    _checkSpecialFile

    __ngoSpecialList="$(_readFirstLine "$SPECIAL_FILE")"
    __ngoSpecialListSpaced="$(_spacedString "$__ngoSpecialList")"
    __ngoSpecialListDefaultSpaced="$(_spacedString "$SPECIAL_LIST_DEFAULT")"

    # Menu Loop
    while :; do
        printf '%s\n' 'main -> new entry -> generated password -> special characters'

	# Somehow required, though I never touch the IFS here. odd
	__ngoOldIFS="$IFS"

	# Disable pathname expansion for * and ? etc.
	set -f
	
	__ngoSpecialListActiveIndex=
	__ngoI=1

	# Iterate over default special chars
	# Check if char is listed in special file
	# Print with index and checkbox
	for __ngoSpecialCharDefault in $__ngoSpecialListDefaultSpaced; do
	    __ngoCharFound=
	    __ngoSpace=

	    # Prepend space if index is single digit
	    if [ "$__ngoI" -le 9 ]; then
		__ngoSpace=" "
	    fi

	    # Iterate over chars in special file
	    # Compare with default special char
	    # Print with checked box if found
	    for __ngoSpecialChar in $__ngoSpecialListSpaced; do
		if [ "$__ngoSpecialCharDefault" = "$__ngoSpecialChar" ]; then
		    printf '%s\n' "$__ngoSpace$__ngoI. [X] $__ngoSpecialCharDefault"
		    __ngoSpecialListActiveIndex="$__ngoSpecialListActiveIndex y"
		    __ngoCharFound=1
		    break
		fi
	    done

	    # Print with unchecked box if not
	    if [ -z "$__ngoCharFound" ]; then
		printf '%s\n' "$__ngoSpace$__ngoI. [ ] $__ngoSpecialCharDefault"
		__ngoSpecialListActiveIndex="$__ngoSpecialListActiveIndex n"
	    fi
	    
	    __ngoI="$((__ngoI + 1))"
	done
	set +f

	# Print options
	# Read input
	printf '%s\n' ""
	printf '%s\n' "input index to toggle"
	printf '%s\n' "'s' to apply changes"
	printf '%s\n' "'q' to exit menu"
	printf '%s'  "option:"; read -r __ngoOption

	# Handle save and quit
	case "$__ngoOption" in
	    q) IFS="$__ngoOldIFS"; return;;
	    s)
		set -f
		_cat <<EOF > "$SPECIAL_FILE"
$SPECIAL_LIST_PREFIX$__ngoSpecialList
EOF
		printf '%s\n' "settings saved. press ENTER to contiue..."
		read -r _
		set +f
		IFS="$__ngoOldIFS"
		return;;
	esac

	# Handle index
	if _isNumber "$__ngoOption"; then
	    __ngoI=1
	    __ngoNewSpecialList=

	    set -f
	    
	    # Switch state of selected special char
	    # Iterate over default special chars
	    for __ngoSpecialCharDefault in $__ngoSpecialListDefaultSpaced; do
		# Get state of selected char
		__ngoCharState="$(_retrieveSubstringUsingIndex \
"$__ngoSpecialListActiveIndex" $__ngoI)"

		# Add chars to new special list based on state and selected index
		if [ "$__ngoCharState" = "y" ] && [ "$__ngoI" -ne "$__ngoOption" ]; then
		    __ngoNewSpecialList="$__ngoNewSpecialList$__ngoSpecialCharDefault"
		    #elif [ "$__ngoCharState" = "n" ] && [ "$i" -ne "$__ngoOption" ]; then
		    #nothing
		    #elif [ "$__ngoCharState" = "y" ] && [ "$i" -eq "$__ngoOption" ]; then
		    #nothing
		elif [ "$__ngoCharState" = "n" ] && [ "$__ngoI" -eq "$__ngoOption" ]; then
		    __ngoNewSpecialList="$__ngoNewSpecialList$__ngoSpecialCharDefault"
		fi		
		__ngoI="$((__ngoI + 1))"
	    done

	    # Overwrite old list with new one
	    # Clear active index for next loop
	    # TODO
	    #  -> can just write directly into __ngoSpecialList, without first doing so in __ngoNewSpecialList
	    #  -> 
	    __ngoSpecialListActiveIndex=
	    __ngoSpecialList="$__ngoNewSpecialList"
	    __ngoSpecialListSpaced="$(_spacedString "$__ngoSpecialList")"
	    set +f
	fi
	IFS="$__ngoOldIFS"
    done
}


# -> menu for password generation
#    prompt for length
#    option to enter submenu to change special characters
_newEntry_generatedPw(){
    printf '%s\n' 'main -> new entry -> generated password'

    # Menu Loop
    while :; do
	printf '%s' "gen pw length [${DEFAULT_PW_LENGTH}]: "
	read -r __negGenPwLength; [ "$__negGenPwLength" = q ] && return
	
	if _isNumber "${__negGenPwLength:-${DEFAULT_PW_LENGTH}}" && \
		[ "${__negGenPwLength:-${DEFAULT_PW_LENGTH}}" -gt 0 ]; then
	    __negGenPw=$(_randomPw "${__negGenPwLength:-${DEFAULT_PW_LENGTH}}")
	    
	    while :; do
		# Print options
		# Read input
		printf '\033[2K\r---------------------------------------\n'
		printf '\033[2K\rmain -> new entry -> generated password\n'
		printf '\033[2K\rPW: %s\n' "${__negGenPw}"
		printf '\033[2K\r1. regenerate (default)\n'
		printf '\033[2K\r2. accept\n'
		printf '\033[2K\r3. special character options\n'
		printf '\033[2K\r4. change password length\n'
		printf '\033[2K\rq. quit\n'
		printf '\033[2K\roption: '; read -r __negGenPwChoice
		
		case "${__negGenPwChoice:-1}" in
		    1)
			__negGenPw=$(_randomPw "${__negGenPwLength:-${DEFAULT_PW_LENGTH}}")
			printf '\033[9A\r'
			;;
		    2)break;;
		    3)_newEntry_generatedPw_options;;
		    4)
			while :; do
			    printf '%s\n' "current length: ${__negGenPwLength:-${DEFAULT_PW_LENGTH}}"
			    printf '%s' "enter new length [${DEFAULT_PW_LENGTH}]: "
			    read -r __negGenPwLength; [ "$__negGenPwLength" = q ] && return
			    
			    if _isNumber "${__negGenPwLength:-${DEFAULT_PW_LENGTH}}" && \
				    [ "${__negGenPwLength:-${DEFAULT_PW_LENGTH}}" -gt 0 ]; then
				__negGenPw=$(_randomPw "${__negGenPwLength:-${DEFAULT_PW_LENGTH}}")
				break
			    else
				printf '%s\n' "[Error] invalid length"
			    fi
			done
			;;
		    q)return;;
		    *)printf '%s\n' "[Error] invalid";
		esac
	    done
	    
	    g_finalPw="$__negGenPw"
	    break
	else
	    printf '%s\n' "[Error] invalid length"
	fi
	printf '%s\n' "[Info] ending"
    done    
}


# -> menu for creating new entries
_newEntry(){
    _clear
    printf '%s\n' 'main -> new entry'
    printf '%s\n' "type 'q' at any point to quit"

    # Prompt for each field
    # Read input
    printf '%s' "label: "; read -r __neLabel; [ "$__neLabel" = q ] && return
    printf '%s' "url or service: "; read -r __neUrlService; [ "$__neUrlService" = q ] && return
    printf '%s' "username: "; read -r __neUsername; [ "$__neUsername" = q ] && return
    printf '%s' "e-mail: "; read -r __neEmail; [ "$__neEmail" = q ] && return

    g_finalPw=
    
    while [ -z "$g_finalPw" ]; do
	printf '%s' "generate password? [Y/n]"; read -r __neGenChoice

	# Handle setting password
	case "$__neGenChoice" in
	    q)return;;
	    n|N|no|NO|No)
		_newEntry_desiredPw
		;;
	    *)
		_newEntry_generatedPw
		;;
	esac
    done

    # Show summary before storing entry
    printf '%s'   '-> summary: '; printf '%s\n' "${__neLabel}"
    printf '%s\n' "url/srv   : ${__neUrlService}"
    printf '%s\n' "username  : ${__neUsername}"
    printf '%s\n' "e-mail    : ${__neEmail}"
    printf '%s\n' "password  : ${g_finalPw}"

    # Allow for option to abort
    printf '%s' "press ENTER to continue... (or q to abort)"; read -r __neProceedChoice
    case "$__neProceedChoice" in
	q|Q)return;;
    esac

    _clear

    # Save
    _storeEntry "$__neLabel" "$__neUrlService" "$__neUsername" "$__neEmail" "$g_finalPw"
    printf '%s\n' "[Info] entry saved"
    sleep 1.5
}


# -> prompt for password if auth file is present
#    prompt for new password if auth file is missing
_authCheck(){
    printf '%s\n' "---- auth-mcgee ----"

    # Check auth directory
    if [ ! -d "$AUTH_DIR"  ]; then
	if ! mkdir "$AUTH_DIR"; then
	    printf '%s\n' "[Error] auth directory could not be created"; exit 1
	fi
    fi

    # Check auth file
    if [ ! -f "$AUTH_FILE" ]; then
	printf '%s\n' '-> setup'

	# Menu Loop
	# prompts twice for new master password
	# TODO hide input
	while :; do
	    _clear
	    
	    # Hide input
	    stty_orig=$(stty -g)
	    stty -echo
	    
	    __acMasterPw1= ; __acMasterPw2=
	    printf '%s' "set master password: "; read -r __acMasterPw1
	    [ -z "$(_isStringValid "$__acMasterPw1")" ] && { _printInvalid; continue; }
	    printf '%s' "again to confirm   : "; read -r __acMasterPw2
	    [ -z "$(_isStringValid "$__acMasterPw2")" ] && { _printInvalid; continue; }

	    # Unhide input
	    stty $stty_orig
	    
	    # Check if passwords match
	    if [ -n "$__acMasterPw1" ] && [ "$__acMasterPw1" = "$__acMasterPw2" ]; then

		# Save hash to auth file
		_hash "$__acMasterPw1" >> "$AUTH_FILE"

		# Check if auth file was actually created
		[ ! -f "$AUTH_FILE" ] && { printf '%s\n' "[Error] auth file couldn't be written"; exit 1; }
		printf '%s\n' "[Info] master password set"
		break
	    else
		printf '%s\n' "[Error] passwords don't match. try again"
	    fi
	done
    else
	printf '%s\n' ""
	# Login loop
	while :; do
	    # Hide input
	    stty_orig=$(stty -g)
	    stty -echo

	    # Read
            printf '%s' "login (q to quit): "; read -r g_inputPw

	    # Unhide input
	    stty $stty_orig
	    _clear

	    if [ "$g_inputPw" = "q" ]; then
		printf '%s\n' "bye!"
		exit
	    fi
	    
	    # Compare hashes
	    printf '%s' "checking..."
            if [ "$(_hash "${g_inputPw}")" = "$(_readFirstLine "$AUTH_FILE")" ]; then
		# Exit loop
		printf '%s\n' "well done"; break
	    else
		printf '%s\n' "wrong"
	    fi
	done
    fi
}


_changeMasterPassword(){
    while :; do
	printf '%s\n' "main -> change master password"
	printf '%s\n' "('q' to quit at any time)"
	printf '%s'   "enter current password: "
	read -r __cmpCurrent; if [ "$__cmpCurrent" = "q" ]; then return; fi


	if _isPwSame "$__cmpCurrent" "$g_inputPw"; then
	    while :; do
		printf '%s' "enter new password: "
		read -r __cmpMasterPw1; if [ "$__cmpMasterPw1" = "q" ]; then return; fi

		printf '%s'  "again            : "
		read -r __cmpMasterPw2; if [ "$__cmpMasterPw2" = "q" ]; then return; fi
		
		if _isPwSame "$__cmpMasterPw1" "$__cmpMasterPw2"; then
		    printf 'UNFINISHED'
		    # TODO FINISH THIS PART
		    # Re-encrypt everything using new password. h			
		else
		    printf '%s\n' "[Error] mismatching passwords"
		fi
	    done
	else
	    printf '%s\n' "[Error] incorrect password. uh oh"
	fi
    done
}


_main(){
    _authCheck
    while :; do
	_clear
	printf '%s\n' "---- auth-mcgee ----"
	printf '%s\n' "main"
	printf '%s\n' "1. list entries"
	printf '%s\n' "2. new entry"
	printf '%s\n' "q. quit"
	printf '%s' "option: "; read -r __choice

	case "$__choice" in
	    1)_listEntries;;
	    2)_newEntry;;
	    q)printf '%s\n' "bye!"; exit 0;;
	    *)printf '%s\n' "[Error] invalid";sleep 1;;
	esac
    done
}

_main
