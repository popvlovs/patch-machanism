#!/bin/bash
function __replace_installdir_placeholder() {
    echo "replace all install-dir to placeholder: $1"
    sed -i "s#$1#\${install.dir.placeholder}#g" `grep $1 -rl $1`
}

function __replace_secret_placeholder() {
    echo "replace all jwt token: $1"
    origin_secret=`cat $1/tomcat/webapps/enterprise/WEB-INF/classes/config/common/properties/config.properties | grep 'common.token.secret' | awk -F '=' '{printf $2}' | sed 's/ //g'`
    sed -i "s/$origin_secret/\${jwt.secret.placeholder}/g" `grep $origin_secret -rl $1`
}

function __replace_token_placeholder() {
    echo "replace all jwt secret: $1"
    origin_token=`cat $1/misc/application.yml | grep 'token' | awk -F ':' '{printf $2}' | sed 's/ //g'`
    sed -i "s/$origin_token/\${jwt.token.placeholder}/g" `grep $origin_token -rl $1`
}

function __extract_diff() {
    # "/opt/hansight" -> "${install.dir.placeholder}"
    __replace_installdir_placeholder ${1%/*}
    __replace_installdir_placeholder ${2%/*}
    # "TOKEN: xxxxxxxxxxxx" -> "TOKEN: ${jwt.token.placeholder}"
    __replace_token_placeholder ${1%/*}
    __replace_token_placeholder ${2%/*}
    # "SECRET: xxxxxxxxxxx" -> "SECRET: ${jwt.secret.placeholder}"
    __replace_secret_placeholder ${1%/*}
    __replace_secret_placeholder ${2%/*}

    diff -rq --exclude-from=$ignore $1 $2 | sed 's/: /\//g' | while read line
    do
        type=`echo $line | awk '{print $1}'`
        if [ "$type"x = "Only"x ];then
            target=`echo $line | awk '{print $3}'`
            if [[ $target == $dst* ]];then
                echo "+ ${target/#$dst/$placeholder}" | tee -a $changelog
                __copy $target 
            else
                echo "- ${target/#$src/$placeholder}" | tee -a $changelog
            fi
        else
            target=`echo $line | awk '{print $4}'` 
            echo "u ${target/#$dst/$placeholder}" | tee -a $changelog
            __copy $target
        fi
    done
}

function __copy() {
    if [ -d $1 ];then
        mkdir -p ${1/#$dst/$temp} && cp -rf $1 $_
    else
        tar=${1%/*}/
        mkdir -p ${tar/#$dst/$temp} && cp -a $1 $_
    fi
}

function __make_tar() {
    basepath=$(cd `dirname $0`; pwd)
    cd $temp
    # replace all install dir to placeholder "/opt/hansight" -> "${install.dir.placeholder}"
    #sed -i "s#${dst%/*}#\${install.dir.placeholder}#g" `grep ${dst%/*} -rl .`
    tar czvf $basepath/$patch * >/dev/null
    cd - >/dev/null
    rm -rf $temp
    uuid=`cat /proc/sys/kernel/random/uuid`
    mkdir $uuid
    mv $patch $uuid
    mv $changelog $uuid
    cp -a $config $uuid
    __write_properties $uuid/$config
    cp -a *.sh $uuid
    rm -rf "$uuid/$thisshell"
    tar czvf patch-$timestamp.tar.gz $uuid >/dev/null
    rm -rf $uuid
}

function __write_properties() {
    need_detail=`__get_prop $1 "version.detail"`
    version_filter=`__get_prop $1 "version.filter"`
    # extract src versions
    version_src=`__extract_version $src $version_filter`
    # extract dst versions
    version_dst=`__extract_version $dst $version_filter`
    if [ "$need_detail"x == "true"x ];then
        echo $version_src | tr " " "\n" | while read line
        do
            key=`echo $line | awk -F '=' '{print $1}'`
            val=`echo $line | awk -F '=' '{print $2}'`
            __set_prop $1 "$key.src" $val
        done
        echo $version_dst | tr " " "\n" | while read line
        do
            key=`echo $line | awk -F '=' '{print $1}'`
            val=`echo $line | awk -F '=' '{print $2}'`
            __set_prop $1 "$key.dst" $val
        done
    fi
    # calc version md5
    __set_prop $1 "version.from" `echo $version_src | md5sum | head -c 32`
    __set_prop $1 "version.to" `echo $version_dst | md5sum | head -c 32`
    # calc resource md5
    __set_prop $1 "resource.md5" `md5sum $uuid/$patch | head -c 32`
}

function __extract_version() {
    # extract backend commitid & buildnum
    [[ "$2" =~ "backend" ]] && echo `__extract_commitid_and_buildnum $1 1 "backend"`
    # extract frontend commitid & buildnum
    [[ "$2" =~ "frontend" ]] && echo `__extract_commitid_and_buildnum $1 2 "frontend"`
    # extract cep commitid & buildnum
    [[ "$2" =~ "furion" ]] && echo `__extract_commitid_and_buildnum $1/cep 1 "furion"`
    # extract misc commitid & buildnum
    [[ "$2" =~ "rubick" ]] && echo `__extract_commitid_and_buildnum $1/misc 1 "rubick"`
    # extract alg commitid & buildnum
    [[ "$2" =~ "darchrow" ]] &&  echo `__extract_commitid_and_buildnum $1/alg 1 "darchrow"`
}

function __extract_commitid_and_buildnum() {
    buildnum=`grep buildnum $1/version.properties 2>/etc/null | sed -n $2p | awk -F '[= ]*' '{print $2}' | tr -d "\n"`
    [ -n "$buildnum" ] && printf "$3.buildnum=$buildnum\n"
    commitid=`grep commitid $1/version.properties 2>/etc/null | sed -n $2p | awk -F '[= ]*' '{print $2}' | tr -d "\n"`
    [ -n "$commitid" ] && printf "$3.commitid=$commitid\n"
}

function __set_prop() {
    keyval=`grep "^$2=" $1 | tr -d "\n"`
    if [ -n "$keyval" ];then
        sed -i "s/^$2=.*$/$2=$3/g" $1 
    else
        echo $2=$3 >> $1
    fi
}

function __get_prop() {
    grep "^$2=" $1 | head -n 1 | awk -F '=' '{print $2}' | tr -d "\n"
}

src=$(readlink -f $1)/
dst=$(readlink -f $2)/
ignore=$3
timestamp=`date +%s`
changelog="upgrade.changelog"
patch="resource.tar.gz"
thisshell="makepatch.sh"
config="config.properties"
placeholder='$INSTALL_DIR/'
temp="./patch/"
export LANG=en
echo "compare $src and $dst, ignore rules from \"$ignore\""

rm -rf $changelog
rm -rf $temp
rm -rf patch-*.tar.gz
__extract_diff $src $dst && __make_tar