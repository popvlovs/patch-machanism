#!/bin/bash
function __check_md5() {
    __print_header "Check resource md5"
    __print "- read resource md5 from \"$config\""
    md5=`__get_prop $config "resource.md5"` && __print "  MD5: $md5"
    __print "- calculate md5 of \"$resource\""
    thismd5=`md5sum $resource | head -c 32` && __print "  MD5: $thismd5"
    [ "$md5"x != "$thismd5"x ] && __error "ERROR: resource md5 mismatch \"$md5\" != \"$thismd5\""
}

function __check_version() {
    __print_header "Check patch version"
    __print "- read upgrade version from \"$config\""
    version_filter=`__get_prop $config "version.filter"` && __print "  version.filter: $version_filter"
    version_from=`__get_prop $config "version.from"` && __print "  version.from: $version_from"
    __print "- extract current version of \"$install_dir\""
    thisversion=`__extract_version $install_dir $version_filter`  #&& __print "  $thisversion"
    thisversionmd5=`echo $thisversion | md5sum | head -c 32` && __print "  version.current: $thisversionmd5"
    [ "$version_from"x != "$thisversionmd5"x ] && __error "ERROR: version mismatch \"$version_from\" != \"$thisversionmd5\""
}

function __check_changelock() {
    __print_header "Check changing lock"
    __print "- searching lock file \"$lock\""
    lockfile=`find $install_dir -name $lock`
    [ -n "$lockfile" ] && __print "ERROR: lock file exist!" && __error "Start: `cat $lockfile`"
    __print "  Not locked!"
    __lock
}

function __stop_server() {
    return 0
    __print_header "Stop system modules"
    #__print "- check current stuats"
    #$install_dir/hanctl status
    __print "- stop all modules except mysql"
    modules=`$install_dir/hanctl status | grep -v mysql |  awk '{print $1}' | tr "\n" " "`
    #__print "  stop $modules"
    $install_dir/hanctl stop $modules > /dev/null 2>&1
    #[[ $? ]] && __error "Stop server failed"
    #__print "- check status"
    $install_dir/hanctl status
}

function __start_server() {
    return 0
    __print "- restart system modules"
    #modules=`$install_dir/hanctl status | grep -v "RUNNING" | awk '{print $1}' | tr "\n" " "`
    #if [ "$modules"x != "x" ];then
    $install_dir/hanctl restart all > /dev/null 2>&1
    #fi
    $install_dir/hanctl status
}

function __backup_files() {
    __print_header "Backup files"
    __print "- read backup directory from \"$config\""
    backup_dir=`__get_prop $config "backup.dir"` && __print "  backup.dir: "${backup_dir}
    __print "- is backup directory existing?"
    if [ -d $backup_dir ];then
        __print "  yes, remove existing backup folder..."
        rm -rf $backup_dir
    else
        __print "  nope"
    fi
    __print "- backup files as listed below:"
    backup_include=`__get_prop $config "backup.include"`
    for i in ${backup_include}
    do
        dir_from=${i//'${install.dir}'/$install_dir}
        dir_to=${i//'${install.dir}'/$backup_dir}
        __print "  cp $dir_from $dir_to"
        __copy $dir_from $dir_to
        [[ $? -ne 0 ]] && __error "ERROR: backup failed"
    done
}

function __backup_mysql() {
    __print_header "Backup db: mysql"
    __print "- read backup.mysql from \"$config\""
    backup_mysql=`__get_prop $config "backup.mysql"`
    if [ "$backup_mysql"x == "true"x ];then
        __print "  backup.mysql: true"
        __print "- search db.properties in \"$install_dir\""
        db_props=`find $install_dir -name 'db.properties' | sed -n 1p` && __print "  $db_props"
        __print "- read db params"
        db_username=`__get_prop $db_props "db.username"` && __print "  db.username: $db_username"
        db_password=`__get_prop $db_props "db.password"` && __print "  db.password: $db_password"
        db_url=`__get_prop $db_props "db.url"` && __print "  db.url: $db_url"
        db_ip=`echo $db_url | grep -oP '\d+\.\d+\.\d+\.\d+:\d+' | awk -F ':' '{print $1}'` && __print "  db.ip: $db_ip"
        db_port=`echo $db_url | grep -oP '\d+\.\d+\.\d+\.\d+:\d+' | awk -F ':' '{print $2}'` && __print "  db.port: $db_port"
        __print "- dump db files"
        __print "  $install_dir/mysql/bin/mysqldump -h $db_ip -P$db_port -u$db_username -p$db_password hansight --set-gtid-purged=OFF > $backup_dir/sql.bak"
        $install_dir/mysql/bin/mysqldump -h $db_ip -P$db_port -u$db_username -p$db_password hansight --set-gtid-purged=OFF > $backup_dir/sql.bak
        [[ $? -ne 0 ]] && __error "ERROR: backup db failed"
    else
        __print "  backup.mysql: $backup_mysql"
        __print "  skip"
    fi
}

function __replace_resource() {
    __print_header "Replace static files"

    # cache origin jwt secret & token
    __print "- cache origin jwt secret & token"
    origin_secret=`cat $install_dir/tomcat/webapps/enterprise/WEB-INF/classes/config/common/properties/config.properties | grep 'common.token.secret' | awk -F '=' '{printf $2}' | sed 's/ //g'`
    __print "  secret: ${origin_secret:0:10}..."
    origin_token=`cat $install_dir/misc/application.yml | grep 'token' | awk -F ':' '{printf $2}' | sed 's/ //g'`
    __print "  token: ${origin_token:0:10}..."

    # decompress resource tgz to local install directory
    __print "- decompress \"$resource\" to \"$install_dir\""
    __print "  tar xzvf $resource -C $install_dir"
    tar xzvf $resource -C $install_dir > /dev/null
    [[ $? -ne 0 ]] && __error_with_rollback "ERROR: replace static files failed"

    # replace placeholder "${install.dir.placeholder}" -> "/opt/hansight"
    __print "- replace \"\${install.dir.placeholder}\""
    # get normal install directory "/opt/hansight/" -> "/opt/hansight" 
    _dir=$(readlink -f $install_dir)
    [[ $? -ne 0 ]] && __error_with_rollback "ERROR: get normal install dir failed"
    # search and replace all placeholder in local install directory
    sed -i "s#\${install.dir.placeholder}#$_dir#g" `grep '${install.dir.placeholder}' -rl $_dir` > /dev/null 2>&1
    [[ $? -ne 0 ]] && __error_with_rollback "ERROR: replace placeholder failed"
    __print "- replace \"\${jwt.secret.placeholder}\""
    sed -i "s#\${jwt.secret.placeholder}#$origin_secret#g" `grep '${install.dir.placeholder}' -rl $_dir` > /dev/null 2>&1
    __print "- replace \"\${jwt.token.placeholder}\""
    sed -i "s#\${jwt.token.placeholder}#$origin_token#g" `grep '${install.dir.placeholder}' -rl $_dir` > /dev/null 2>&1
}

function __del_redundant_file() {
    __print_header "Remove redundant files"

    __print "- rm \"-\" files in \"$changelog\""
    # extract all "-" files in changelog
    _text=`cat $changelog | grep "^-"`
    while read line
    do
        tar=${line/'- $INSTALL_DIR'/$install_dir}
        # rm "-" files only belong to install directory 
        [[ $tar == $install_dir* ]] && rm -rf $tar
        [[ $? -ne 0 ]] && __error_with_rollback "ERROR: remove redundant file failed"
        __print "  rm $tar"
    done <<< "$_text"
}

function __run_custom_shell() {
    __print_header "Run custom shells"
    _text=`ls | grep -P '^.+\.sh$' | grep -v "patch.sh"`
    while read line
    do
        if [ -z $line ];then
            __print "- no custom shell~"
        else
            __print "- bash $line"
            bash $line
            [[ $? -ne 0 ]] && __error_with_rollback "ERROR: custom shell exception"
        fi
    done <<< "$_text"
}

function __lock() {
    __print "- lock"
    date > $lock
}

function __unlock() {
    __print "- unlock"
    rm -f $lock
}

function __get_prop() {
    grep "^$2=" $1 | head -n 1 | awk -F '=' '{print $2}' | tr -d "\n"
}

function __set_prop() {
    keyval=`grep "^$2=" $1 | tr -d "\n"`
    if [ -n "$keyval" ];then
        sed -i "s/^$2=.*$/$2=$3/g" $1 
    else
        echo $2=$3 >> $1
    fi
}

function __success() {
    __print_header "Apply patch success!" # 这个输出值不要改，web-api controller靠这个判断升级成功
    __set_prop $config "runtime.status" "ROLLBACKABLE"
    __start_server
    __unlock
    __print_line
    __record success
}

function __error() {
    __print "$1"
    trap "" 2
    __print_header "Stop patch and exit"
    #__start_server
    __print_line
    exit 1
}

function __error_with_rollback() {
    __print "$1"
    trap "" 2
    __print_header "Stop patch and rollback"
    __rollback
    #__start_server
    __unlock
    __print_line
    __record error
    exit 1
}

function __rollback() {
    __check_rollback_version
    # stop all servers before rollback
    __stop_server 
    __write_back_backups
    __write_back_db_dump
}

function __check_rollback_version() {
    __print "- check rollback version from \"$config\""
    version_filter=`__get_prop $config "version.filter"` && __print "  version.filter: $version_filter"
    version_to=`__get_prop $config "version.to"` && __print "  version.to: $version_to"
    thisversion=`__extract_version $install_dir $version_filter` # && __print "  $thisversion"
    thisversionmd5=`echo $thisversion | md5sum | head -c 32` && __print "  version.current: $thisversionmd5"
    [ "$version_to"x != "$thisversionmd5"x ] && __print "ERROR: version mismatch \"$version_to\" != \"$thisversionmd5\"" && __unlock && exit 1
}

function __write_back_backups() {
    __print_header "write back files"
    backup_dir=`__get_prop $config "backup.dir"`
    __print "- write back backup files in \"$backup_dir\""
    if [ ! -d $backup_dir ];then
        __print "ERROR: backup folder not exist"
        __print_line
        exit 1
    fi
    backup_include=`__get_prop $config "backup.include"`
    for i in ${backup_include}
    do
        dir_from=${i//'${install.dir}'/$backup_dir}
        dir_to=${i//'${install.dir}'/$install_dir}
        __print "  cp $dir_from $dir_to"
        rm -rf $dir_to
        __copy $dir_from $dir_to
        [[ $? -ne 0 ]] && __print "ERROR: write back failed"
    done
}

function __write_back_db_dump() {
    __print "- read backup.mysql from \"$config\""
    backup_mysql=`__get_prop $config "backup.mysql"`
    if [ "$backup_mysql"x == "true"x ];then
        __print "  backup.mysql: true"
        __print "- search db.properties in \"$install_dir\""
        db_props=`find $install_dir -name 'db.properties' | sed -n 1p` && __print "  $db_props"
        __print "- read db params"
        db_username=`__get_prop $db_props "db.username"` && __print "  db.username: $db_username"
        db_password=`__get_prop $db_props "db.password"` && __print "  db.password: $db_password"
        db_url=`__get_prop $db_props "db.url"` && __print "  db.url: $db_url"
        db_ip=`echo $db_url | grep -oP '\d+\.\d+\.\d+\.\d+:\d+' | awk -F ':' '{print $1}'` && __print "  db.ip: $db_ip"
        db_port=`echo $db_url | grep -oP '\d+\.\d+\.\d+\.\d+:\d+' | awk -F ':' '{print $2}'` && __print "  db.port: $db_port"
        __print "- import db dump file"
        __print "  $install_dir/mysql/bin/mysql -h $db_ip -P$db_port -u$db_username -p$db_password hansight < $backup_dir/sql.bak"
        $install_dir/mysql/bin/mysql -h $db_ip -P$db_port -u$db_username -p$db_password hansight < $backup_dir/sql.bak
        [[ $? -ne 0 ]] && __error "ERROR: write back db failed"
    else
        __print "  backup.mysql: $backup_mysql"
        __print "  skip..."
    fi
}

function __copy() {
    tar=${2%/*}/
    if [ -d $1 ];then
        #__print "mkdir -p $tar && cp -rf $1 $tar"
        mkdir -p $tar && cp -rfp $1 $tar
        return $?
    else
        #__print "mkdir -p $tar && cp -a $1 $tar"
        mkdir -p $tar && cp -ap $1 $tar
        return $?
    fi
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

function __record() {
    status=$1
    echo "- store system change info -> mysql"

    __is_table_exist
    if [ $? -eq 0 ];then
        record=`__get_systemchange_record` # 从mysql中读取uuid所对应的patch记录
        current_timestamp=$(date +'%Y-%m-%d %H:%M:%S')
        current_patch_id=`__execute_mysql_statement "select id from system_change where type=2"`
        echo $current_patch_id
        echo $record
        if [ -z "$record" ];then
            echo "  insert record"
            statement=`__make_statement insert $uuid ${current_patch_id:-null} 1 "" "" "" null 1 "" "" "" null 1 "$current_timestamp" "$current_timestamp"`
            __execute_mysql_statement "$statement"
        fi
        ifs=$IFS; IFS=""; 
        steps=`cat $log` #`__read_log`
        #echo $steps
        #current_status=`bash $base_dir/patch.sh status`
        #"status=${status_map["$current_status"]}"
        if [ "$type"x == "apply"x ];then
            if [ "$status"x = "success"x ];then
                __execute_mysql_statement "update system_change set type=3 where type=2"
                statement=`__make_statement update "patch_description=''" "type=2" "patch_steps='$steps'" "patch_user='SHELL'" "patch_active_time='$current_timestamp'" "patch_status=1" "update_time='$current_timestamp'"`
            else
                statement=`__make_statement update "patch_description=''" "patch_steps='$steps'" "patch_user='SHELL'" "patch_status=2" "update_time='$current_timestamp'"`
            fi
        fi
        if [ "$type"x == "rollback"x ];then
            statement=`__make_statement update "restore_description=''" "type=1" "restore_steps='$steps'" "restore_user='SHELL'" "restore_active_time='$current_timestamp'" "restore_status=1" "update_time='$current_timestamp'"`
            prev_patch_id=`__execute_mysql_statement "select prev_change_id from system_change where id='$uuid' and prev_change_id is not null;"`
            [ -z "$current_patch_id" ] && __execute_mysql_statement "update system_change set type=2 where id='$current_patch_id';"
        fi
        __execute_mysql_statement "$statement"
        IFS=$ifs; 
    else
        __print "  table \"system_change\" dose not exist"
    fi
}

function __read_log() {
	while read line
	do
        echo $line
	done < $log
}

function __make_statement() {
    if [ "$1"x == "insert"x ];then
        statement="insert into system_change values (";shift
        until [ $# -eq 0 ]
        do
        if [ "$1"x != 'null'x ];then
            statement="${statement} '$1',"
        else
            statement="${statement} NULL,"
        fi
        shift
        done
        statement="${statement%,*});"
        echo $statement
    elif [ "$1"x == "update"x ];then
        statement="update system_change set ";shift
        until [ $# -eq 0 ]
        do
            statement="${statement} $1,"
        shift
        done
        statement="${statement%,*} where id='$uuid';"
        echo $statement
    fi
}

function __is_table_exist() {
    statement="select TABLE_NAME from INFORMATION_SCHEMA.TABLES where TABLE_SCHEMA='hansight' and TABLE_NAME='system_change';"
    tables=`__execute_mysql_statement "$statement"`
    echo $tables
    [ -z "$tables" ] && return 1
}

function __get_systemchange_record() {
    statement="select id from system_change where id='"${uuid}"'"
    echo `__execute_mysql_statement "$statement" | sed -n 1p`
}

function __execute_mysql_statement() {
    #echo "$mysql_install_dir/bin/mysql -S $mysql_data_dir/mysql.sock -uhansight -phansight hansight -BN -e \"$1\" 2>&1 | grep -v 'Warning'"
    $mysql_install_dir/bin/mysql -S $mysql_data_dir/mysql.sock -uhansight -phansight hansight -BN -e "$1" 2>&1 | grep -v "Warning"
}

function __usage() {
    echo "- patch options:"
    echo "  \"rollback\""
    echo "  \"apply\""
    echo "  \"status\""
}

function __print_header() {
    printf "\n%-20s %-20s %-20s\n\n" "=======================" "$1" "=======================" | tee -a $log
}

function __print_line() {
    printf "\n====================================================================\n\n" | tee -a $log
}

function __print() {
    echo "$1" | tee -a $log
}

function __abort() {
    # rollback an exit if locked
    if [ "$type"x == "apply"x ];then
        lockfile=`find $install_dir -name $lock`
        [ -n "$lockfile" ] && __error_with_rollback "NOTICE: upgrade aborted!"
    fi
    # exit normally
    __error "NOTICE: upgrade aborted!"
}

export LANG=en
base_dir=$(cd "$(dirname "$0")";pwd)
uuid="${base_dir##*/}"
log="patch.log"
resource="resource.tar.gz"
config="config.properties"
changelog="upgrade.changelog"
install_dir=`__get_prop $config "install.dir"`
mysql_install_dir="$install_dir/mysql"
mysql_data_dir=`cat $install_dir/conf/config.ini | grep 'DATA_DIR' | sed -n 1p | awk -F'=' '{printf $2}'`
mysql_data_dir=${mysql_data_dir:-/data01}/mysql/db
lock="change.lock"
backupfile="backup.tar.gz"
type=$1
declare -A status_map=(["UPGRADABLE"]=1 ["ROLLBACKABLE"]=2 ["TO VERSION MISMATCH"]=3 ["FROM VERSION MISMATCH"]=3 ["LOCKED"]=3 ["MD5 MISMATCH"]=3)  

if [ "$1"x == "status"x ];then
    # check md5
    md5=`__get_prop $config "resource.md5"`
    thismd5=`md5sum $resource | head -c 32`
    if [ $md5 != $thismd5 ];then
        echo "MD5 MISMATCH" # 不要更改输出值
        exit 1
    fi

    # check lock
    lockfile=`find $install_dir -name $lock`
    if [ -n "$lockfile" ];then
        echo "LOCKED" # 不要更改输出值
        exit 1
    fi

    runtime_status=`__get_prop $config "runtime.status"`
    # check version
    version_filter=`__get_prop $config "version.filter"`
    version_from=`__get_prop $config "version.from"`
    version_to=`__get_prop $config "version.to"`
    thisversion=`__extract_version $install_dir $version_filter`
    thisversionmd5=`echo $thisversion | md5sum | head -c 32`
    if [ "$runtime_status"x == "ROLLBACKABLE"x ];then
        if [ "$version_to"x == "$thisversionmd5"x ];then
            echo "ROLLBACKABLE" # 不要更改输出值
            exit 0
        else
            echo "TO VERSION MISMATCH" # 不要更改输出值
            exit 1
        fi
    else
        if [ "$version_from"x == "$thisversionmd5"x ];then
            echo "UPGRADABLE" # 不要更改输出值
            exit 0
        else
            echo "FROM VERSION MISMATCH" # 不要更改输出值
            exit 1
        fi
    fi
    echo "YOU SHALL NOT PASS!" # 不要更改输出值
    exit 1
fi
__print_line
__print "  uuid: $uuid"
if [ "$1"x == "apply"x ];then
    rm -rf *.log
    trap __abort 2
    __check_md5
    __check_version
    __check_changelock
    __stop_server
    __backup_files
    __backup_mysql
    __replace_resource
    __del_redundant_file
    __run_custom_shell
    __success
    exit 0
fi
if [ "$1"x == "rollback"x ];then
    rm -rf *.log
    trap "" 2
    __print_header "Rollback last patch"
    __lock
    __rollback
    __set_prop $config "runtime.status" "UPGRADABLE"
    __start_server
    __unlock
    __print_line
    __record success
    exit 1
fi

__usage
__print_line