#!/bin/sh
DEBUG=

DEFAULT_PW_LENGTH=32
AUTH_DIR="auth-mcgee"
AUTH_FILE="${AUTH_DIR}/auth"
DATA_DIR="${AUTH_DIR}/data"

SPECIAL_FILE="${AUTH_DIR}/special"
SPECIAL_LIST_DEFAULT='!@#$%^&*()_+=-[]'
SPECIAL_LIST_PREFIX="A-Za-z0-9"

g_inputPw=
g_finalPw=

# dependncies (yucky, impure, embarrassing):
# gpg
# base64
# argon2


# shcat stolen from cate
_cat() {
    while IFS= read -r p || [ "$p" ]; do
	printf '%s\n' "$p"
    done
}

_en(){ printf '%s\n' "$1"; }

_e(){ printf '%s' "$1"; }

_dbg_pause(){ [ -n "$DEBUG" ] && { _e '-debug pause-'; read -r _;}; }

_dbg_deleteAuthFile(){
    [ "$DEBUG" ] && [ -f "$AUTH_FILE" ] && {
	_e "type 'YES' to delete auth file: "
	read -r delAuth
	[ "$delAuth" = "YES" ] && { rm "$AUTH_FILE"; }
    }
}

_hash(){ printf '%s' "$(printf '%s' "$1" | argon2 "$USER" -id -r -t 6 -m 17)"; }

# _isStringValid; ARG $1=string to check; RET success->input string; failure->empty
_isStringValid(){ printf '%s' "$(printf '%s\n' "$1" | LC_ALL=C grep -E '^[A-Za-z0-9!@#$%^&*()_+=-]+$')"; }

_isPwSame(){ printf '%s' "$([ -n "$1" ] && [ "$1" = "$2" ] || { printf '%s' 1; })"; }

_readFirstLine(){ printf '%s' "$( _cat < "$1" | head -n 1)"; }

_checkSpecialFile(){
    if [ ! -e "$SPECIAL_FILE" ]; then
	_e "$SPECIAL_LIST_DEFAULT" >> "$SPECIAL_FILE"
	if [ ! -e "$SPECIAL_FILE" ]; then
	    _en "[Error] special file can't be created. rip"; exit 1
	else
	    _en "[Info] special file created"
	fi
    fi
}

#_randomPw ARG $1=length
_randomPw(){
    _checkSpecialFile    
    __specialList="$(_readFirstLine "$SPECIAL_FILE")"
    #printf '%s' "$__specialList"
    printf '%s' "$( _cat < /dev/urandom | tr -dc "$__specialList" | fold -w "$1" | head -n 1 )"
}



_printInvalid(){ _en "[Error] invalid. allowed chars: A-Za-z0-9!@#$%^&*()_+=-" ;}

# _spacedString ARG $1=string to convert; eg. "test" -> "t e s t"
_spacedString(){
    #    echo "spacing string: [${1}]"
    __str="$1"
    __res=
    while [ -n "$__str" ]; do
	__res="$__res ${__str%"${__str#?}"}"
	__str="${__str#?}"
	# 	echo "__str: " "${__str}"
    done
    __res="${__res#?}"
    printf '%s' "$__res"
}

#ARG: 1=string 2=spacer_length 3=char[ ]
#RET: returns string of spaces which is needed to reach
#     desired width when combined with input string
_spacer(){
    __in="$1"
    __char="${3:- }"
    __i="$(expr $2 - ${#__in})"
    while [ "$__i" -gt 0 ];do
	__out="${__out}$__char"
	__i="$((__i-1))"
    done
    printf '%s' "$__out"
}


#ARG $1=space separated string; $2=index (starting at 1)
#RET value at the indexed position
_retrieveSubstringUsingIndex(){
    __tmp1="$1"
    __tmp2="$2"
    set f-
    __index=1
    for __subString in $__tmp1; do
	[ "$__index" = "$__tmp2" ] && {
	    printf '%s' "$__subString"
	    return
	}
	__index="$((__index+1))"
    done
    printf '%s' "_rSUI_ERROR"
    set f+
}



_base64enc(){
    printf '%s' "$(printf '%s' "$1" | base64 -w 0 -)"
}

_base64dec(){
    printf '%s' "$(printf '%s' "$1" | base64 -d -)"
}


# ARGS: text pw
_encode() {
    printf '%s' "$1" | gpg --batch --pinentry-mode loopback --passphrase "$2" --armor --symmetric --output - 2> /dev/null
}

# ARGS: text pw
_decode() {
    printf '%s' "$1" | gpg --batch --pinentry-mode loopback --passphrase "$2" --decrypt --output - 2> /dev/null
}

# ARGS: label urlService username email finalPW
_storeEntry(){

    if ! [ -d "$DATA_DIR" ]; then
	mkdir -p "$DATA_DIR"
    fi
    
    __f="$(_base64enc "$1")"
    __fPath="${DATA_DIR}/'$__f'"
    __us="$(_encode "$2" "$g_inputPw")"
    __un="$(_encode "$3" "$g_inputPw")"
    __em="$(_encode "$4" "$g_inputPw")"
    __pw="$(_encode "$5" "$g_inputPw")"
    
    : > "$__fPath"

    {
	printf '%s\n' "$(_base64enc "${__us}")";\
	    printf '%s\n' "$(_base64enc "${__un}")";\
	    printf '%s\n' "$(_base64enc "${__em}")";\
	    printf '%s\n' "$(_base64enc "${__pw}")" 
    } >>   "$__fPath"

    printf '%s'  "$__fPath"
}


# ARGS: <non-base64 filename>
_listEntries_loadEntry(){
    __arg="$1"
    set -- "s" "u" "e" "p"
    __content="$(_cat < "$__arg")"
    __leLineNumber=0
    for __line in $__content; do
	__b64dec="$(_base64dec "$__line")"
	__gpgdec="$(_decode "$__b64dec" "$g_inputPw")"
	echo "$1: $__gpgdec"
	shift
	__leLineNumber="$((__leLineNumber+1))"
    done

    if [ "$__leLineNumber" -le 2 ]; then
	_en "[Error] save file seems to be missing lines"
    fi
}


_listEntries_Option(){
    while :; do
	clear
	_en "entry: $(_base64dec "$1")"
	_en "loading: ${DATA_DIR}/'$1'"
	_listEntries_loadEntry "${DATA_DIR}/'$1'"
	_en ""
	_en "9. delete"
	_en "q. quit"
	_e "option: "; read -r  opt
	case "$opt" in
	    9)
		_e "type 'DELETE' to delete entry. anything else to abort: "; read -r __sure
		if [ "$__sure" = "DELETE" ]; then
		    rm "$1"
		    "entry deleted"
		    sleep 1.5
		    break
		fi
		_en "aborted deletion"
		;;
	    q)break;;
	    *)_en "invalid";;
	esac
    
    done
}



#_listEntries_
_listEntries(){
    __fileList=
    __fileListDec=
    __longestLen=0
    for __entry in ${DATA_DIR}/*; do
	__innie="${__entry#${DATA_DIR}/}"
	__outie="${__innie#?}"
	__need="${__outie%?}"
	__dec="$(_base64dec "$__need")"
	__fileList="$__fileList $__need"
	__currentLen="$(_base64dec "$__need")"
	__currentLen="${#__currentLen}"
	if [ "$__currentLen" -gt "$__longestLen" ]; then
	    __longestLen="$__currentLen"
	fi
    done

    while :; do
	clear
	_en "---- listing ----"
	
	__i=0
	__flipFlop=0
	for __file in $__fileList; do
	    __i="$((__i+1))"
	    if [ "$__flipFlop" -eq 0 ]; then
		__hold="$(_base64dec "$__file")"
		__flipFlop=1
	    else
		_en "$((__i-1)): $__hold$(_spacer "$__hold" $((__longestLen+3)))$__i: $(_base64dec "$__file")"
		__flipFlop=0
	    fi
	done

	if [ "$__flipFlop" -eq 1 ]; then
	    _en "$__i: $__hold"
	fi
	
	_en
	_en "select entry"
	_en "q. quit"
      	_e "option: "; read -r __opt

	if [ "$__opt" -eq "$__opt" ] 2> /dev/null; then
	    __i=1
	    for __file in $__fileList; do
		if [ "$__i" -eq "$__opt" ]; then
		    _listEntries_Option "$__file"
		    break
		fi
		__i="$((__i+1))"
	    done
	elif [ "$__opt" = "q" ]; then
	    return
	else
	    _en "invalid"
	fi
    done
}




_newEntry_desiredPw(){
    clear
    _en "main -> new entry -> desired password"
    while :; do
	_e "desired pw:"
	read -r __desPw1; [ "$__desPw1" = "q" ] && return
	[ -z "$(_isStringValid "$__desPw1")" ] && { _printInvalid; continue; }
	_e "again     : "
	read -r __desPw2; [ "$__desPw2" = "q" ] && return
	[ -z "$(_isStringValid "$__desPw2")" ] && { _printInvalid; continue; }
	_en "password set"
	g_finalPw="$__desPw1"
	break
    done
}

_newEntry_genPw_options(){
    _checkSpecialFile
    
    __specialList="$(_readFirstLine "$SPECIAL_FILE")"
    __specialListSpaced="$(_spacedString "$__specialList")"
    __specialListDefaultSpaced="$(_spacedString "$SPECIAL_LIST_DEFAULT")"

    while :; do
        _en 'main -> new entry -> generated password -> special characters'
	__oldIFS="$IFS"
	set -f
	__specialListActiveIndex=
	__i=1
	for _ in $__specialListDefaultSpaced; do
	    __charFound=1
	    __s=
	    [ "$__i" -le 9 ] && { __s=" "; }
	    for __ in $__specialListSpaced; do
		[ "$_" = "$__" ] && {
		    _en "$__s$__i. [X] $_"
		    __specialListActiveIndex="$__specialListActiveIndex y"
		    __charFound=
		    break
		}
	    done
	    [ -n "$__charFound" ] && {
		_en "$__s$__i. [ ] $_"
		__specialListActiveIndex="$__specialListActiveIndex n"
	    }
	    __i="$((__i+1))"
	done
	set +f

	_en ""
	_en "input index to toggle"
	_en "'s' to apply changes"
	_en "'q' to exit menu"
	_e  "option:"
	read -r __opt
	case "$__opt" in
	    q) IFS="$__oldIFS"; return;;
	    s)
		set -f
		_cat <<EOF > "$SPECIAL_FILE"
$SPECIAL_LIST_PREFIX$__specialList
EOF
		_en "settings saved. press ENTER to contiue..."
		read -r _
		set +f
		IFS="$__oldIFS"
		return;;
	esac

	
	[ "$__opt" -eq "$__opt" ] && [ -n "$__opt" ] && {
	    __i=1
	    __newSpecialList=
	    _en "__specialListSpaced:[$__specialListDefaultSpaced]"
	    _en "__specialListActiveIndex:[$__specialListActiveIndex]"
	    set -f
	    for _ in $__specialListDefaultSpaced; do
		__currentSubStr="$(_retrieveSubstringUsingIndex "$__specialListActiveIndex" $__i)"
		if [ "$__currentSubStr" = "y" ] && [ "$__i" -ne "$__opt" ]; then
		    __newSpecialList="$__newSpecialList$_"
		    #elif [ "$__currentSubStr" = "n" ] && [ "$i" -ne "$__opt" ]; then
		    #nothing
		    #elif [ "$__currentSubStr" = "y" ] && [ "$i" -eq "$__opt" ]; then
		    #nothing
		elif [ "$__currentSubStr" = "n" ] && [ "$__i" -eq "$__opt" ]; then
		    __newSpecialList="$__newSpecialList$_"
		fi		
		__i="$((__i+1))"
	    done
	    __specialListActiveIndex=
	    __specialList="$__newSpecialList"
	    __specialListSpaced="$(_spacedString "$__specialList")"
	    set +f
	}
	IFS="$__oldIFS"
    done
}

_newEntry_generatedPw(){
    _en 'main -> new entry -> generated password'
    while :; do
	_e "gen pw length [${DEFAULT_PW_LENGTH}]: "; read -r __genLen; [ "$__genLen" = q ] && return
	if [ "${__genLen:-${DEFAULT_PW_LENGTH}}" -eq "${__genLen:-${DEFAULT_PW_LENGTH}}" ] && [ -n "${__genLen:-${DEFAULT_PW_LENGTH}}" ]; then
	    __genPw=$(_randomPw "${__genLen:-${DEFAULT_PW_LENGTH}}")
	    while :; do
		_en '---------------------------------------'
		_en 'main -> new entry -> generated password'
		_en "PW: ${__genPw}"
		_en "1. regenerate (default)" 
		_en "2. accept"
		_en "3. special character options"
		_en "q. quit"
		_e "option: "; read -r __genPwChoice
		case "${__genPwChoice:-1}" in
		    1)__genPw=$(_randomPw "${__genLen:-${DEFAULT_PW_LENGTH}}");;
		    2)break;;
		    3)_newEntry_genPw_options;;
		    q)_main;;
		    *)_en "invalid";
		esac
	    done
	    
	    g_finalPw="$__genPw"
	    break
	else
	    _en "[Error] invalid length"
	fi
	_en "ending"
    done    
}

#_newEntry_
_newEntry(){
    _en 'main -> new entry'
    _en "type 'q' at any point to quit"
    
    _e "label: "; read -r __label; [ "$__label" = q ] && return
    _e "url or service: "; read -r __urlService; [ "$__urlService" = q ] && return
    _e "username: "; read -r __username; [ "$__username" = q ] && return
    _e "e-mail: "; read -r __email; [ "$__email" = q ] && return
    _e "generate password? [Y/n]"; read -r __wannaGen
    case "$__wannaGen" in
	q)return;;
	n|N|no|NO|No)
	    _newEntry_desiredPw;;
	*) _newEntry_generatedPw;;
    esac
    _e  '-> summary: '; _en "${__label}"
    _en "url/srv   : ${__urlService}"
    _en "username  : ${__username}"
    _en "e-mail    : ${__email}"
    _en "password  : ${g_finalPw}"

    _e "press ENTER to continue... (or q to abort)"; read -r __continueAbort
    case "$__continueAbort" in
	q|Q)return;;
    esac
    clear

    _storeEntry "$__label" "$__urlService" "$__username" "$__email" "$g_finalPw"
    _en "entry saved"
}

_authCheck(){
    _en "---- auth-mcgee ----"

    if [ ! -d "$AUTH_DIR"  ]; then
	if ! mkdir "$AUTH_DIR"; then
	    _en "[Error] auth directory could not be created"; exit 1
	fi
    fi

    if [ ! -f "$AUTH_FILE" ]; then
	_en '-> setup'
	while :; do
	    clear
	    __masterPw1= ; __masterPw2=
	    _e "set master password: "; read -r __masterPw1
	    [ -z "$(_isStringValid "$__masterPw1")" ] && { _printInvalid; continue; }
	    _e "again to confirm   : "; read -r __masterPw2
	    [ -z "$(_isStringValid "$__masterPw2")" ] && { _printInvalid; continue; }

	    
	    if [ -n "$__masterPw1" ] && [ "$__masterPw1" = "$__masterPw2" ]; then
		
		_hash "$__masterPw1" >> "$AUTH_FILE"

		[ ! -f "$AUTH_FILE" ] && { _en "[Error] auth file couldn't be written"; exit 1; }
		_en "[Info] master password set"
		break
	    else
		_en "[Error] passwords don't match. try again"
	    fi
	done
    else
	_en
	while :; do
	    stty_orig=$(stty -g)
	    stty -echo
            _e "login: "; read -r g_inputPw
	    stty $stty_orig
	    clear
	    _e "checking..."
            if [ "$(_hash "${g_inputPw}")" = "$(_readFirstLine "$AUTH_FILE")" ]; then
		_en "well done"; break
	    else
		_en "wrong"
	    fi
	done
    fi
}

_main(){
    _authCheck
    while :; do
	_en "---- auth-mcgee ----"
	_en "main"
	_en "1. list entries"
	_en "2. new entry"
	_en "q. quit"
	_e "option: "; read -r __choice

	case "$__choice" in
	    1)_listEntries;;
	    2)_newEntry;;
	    q)_en "bye!"; exit 0;;
	    *)_en "invalid";;
	esac
    done
}

_main
