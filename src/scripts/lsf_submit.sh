#!/bin/bash
#
# File:     lsf_submit.sh
# Author:   David Rebatto (david.rebatto@mi.infn.it)
#
# Revision history:
#     8-Apr-2004: Original release
#    28-Apr-2004: Patched to handle arguments with spaces within (F. Prelz)
#                 -d debug option added (print the wrapper to stderr without submitting)
#    10-May-2004: Patched to handle environment with spaces, commas and equals
#    13-May-2004: Added cleanup of temporary file when successfully submitted
#    18-May-2004: Search job by name in log file (instead of searching by jobid)
#     8-Jul-2004: Try a chmod u+x on the file shipped as executable
#                 -w option added (cd into submission directory)
#    21-Sep-2004: -q option added (queue selection)
#    29-Sep-2004: -g option added (gianduiotto selection) and job_ID=job_ID_log
#    13-Jan-2005: -n option added (MPI job selection) and changed prelz@mi.infn.it with
#                    blahp_sink@mi.infn.it
#     4-Mar-2005: Dgas(gianduia) removed. Proxy renewal stuff added (-r -p -l flags)
#     3-May-2005: Added support for Blah Log Parser daemon (using the BLParser flag)
#    31-May-2005: Separated job's standard streams from wrapper's ones
# 
#
# Description:
#   Submission script for LSF, to be invoked by blahpd server.
#   Usage:
#     lsf_submit.sh -c <command> [-i <stdin>] [-o <stdout>] [-e <stderr>] [-w working dir] [-- command's arguments]
#
#
#  Copyright (c) 2004 Istituto Nazionale di Fisica Nucleare (INFN).
#  All rights reserved.
#  See http://grid.infn.it/grid/license.html for license details.
#
#

blahconffile="${GLITE_LOCATION:-/opt/glite}/etc/blah.config"
binpath=`grep lsf_binpath $blahconffile|grep -v \#|awk -F"=" '{ print $2}'|sed -e 's/ //g'|sed -e 's/\"//g'`/
confpath=`grep lsf_confpath $blahconffile|grep -v \#|awk -F"=" '{ print $2}'|sed -e 's/ //g'|sed -e 's/\"//g'`/
fallback=`grep lsf_fallback $blahconffile|grep -v \#|awk -F"=" '{ print $2}'|sed -e 's/ //g'|sed -e 's/\"//g'`
BLParser=`grep lsf_BLParser $blahconffile|grep -v \#|awk -F"=" '{ print $2}'|sed -e 's/ //g'|sed -e 's/\"//g'`
BLPserver=`grep lsf_BLPserver $blahconffile|grep -v \#|awk -F"=" '{ print $2}'|sed -e 's/ //g'|sed -e 's/\"//g'`
BLPport=`grep lsf_BLPport $blahconffile|grep -v \#|awk -F"=" '{ print $2}'|sed -e 's/ //g'|sed -e 's/\"//g'`

conffile=$confpath/lsf.conf

lsf_base_path=`cat $conffile|grep LSB_SHAREDIR| awk -F"=" '{ print $2 }'`

lsf_clustername=`${binpath}lsid | grep 'My cluster name is'|awk -F" " '{ print $5 }'`
logpath=$lsf_base_path/$lsf_clustername/logdir

logfilename=lsb.events

stgcmd="yes"
workdir="."

proxyrenewald="${GLITE_LOCATION:-/opt/glite}/bin/BPRserver"

proxy_dir=~/.blah_jobproxy_dir

stgproxy="yes"

#default is to stage proxy renewal daemon 
proxyrenew="yes"

if [ ! -r $proxyrenewald ]
then
  unset proxyrenew
fi

#default values for polling interval and min proxy lifetime
prnpoll=30
prnlifetime=0

BLClient="${GLITE_LOCATION:-/opt/glite}/bin/BLClient"

###############################################################
# Parse parameters
###############################################################

while getopts "i:o:e:c:s:v:dw:q:n:rp:l:x:j:C:" arg 
do
    case "$arg" in
    i) stdin="$OPTARG" ;;
    o) stdout="$OPTARG" ;;
    e) stderr="$OPTARG" ;;
    v) envir="$OPTARG";;
    c) the_command="$OPTARG" ;;
    s) stgcmd="$OPTARG" ;;
    d) debug="yes" ;;
    w) workdir="$OPTARG";;
    q) queue="$OPTARG";;
    n) mpinodes="$OPTARG";;
    r) proxyrenew="yes" ;;
    p) prnpoll="$OPTARG" ;;
    l) prnlifetime="$OPTARG" ;;
    x) proxy_string="$OPTARG" ;;
    j) creamjobid="$OPTARG" ;;
    C) req_file="$OPTARG";;
    -) break ;;
    ?) echo $usage_string
       exit 1 ;;
    esac
done

# Command is mandatory
if [ "x$the_command" == "x" ]
then
    echo $usage_string
    exit 1
fi

shift `expr $OPTIND - 1`
arguments=$*

###############################################################
# Create wrapper script
###############################################################

# Get a suitable name for temp file
if [ "x$debug" != "xyes" ]
then
    if [ ! -z "$creamjobid"  ] ; then
        tmp_file=cream_${creamjobid}
    else
        tmp_file=`mktemp -q blahjob_XXXXXX`
    fi
    if [ $? -ne 0 ]; then
        echo Error
        exit 1
    fi
else
    # Just print to stderr if in debug
    tmp_file="/proc/$$/fd/2"
fi

# Create unique extension for filename
uni_uid=`id -u`
uni_pid=$$
uni_time=`date +%s`
uni_ext=$uni_uid.$uni_pid.$uni_time

# Create date for output string
datenow=`date +%Y%m%d%H%M.%S`

# Write wrapper preamble
cat > $tmp_file << end_of_preamble
#!/bin/bash
# LSF job wrapper generated by `basename $0`
# on `/bin/date`
#
# LSF directives:
#BSUB -L /bin/bash
#BSUB -N
#BSUB -u blahp_sink@mi.infn.it
#BSUB -J $tmp_file
end_of_preamble

#set the queue name first, so that the local script is allowed to change it
#(as per request by CERN LSF admins).
[ -z "$queue" ]          || echo "#BSUB -q $queue" >> $tmp_file

#local batch system-specific file output must be added to the submit file
if [ ! -z $req_file ] ; then
    echo \#\!/bin/sh >> temp_req_script_$req_file 
    cat $req_file >> temp_req_script_$req_file 
    echo "source ${GLITE_LOCATION:-/opt/glite}/bin/lsf_local_submit_attributes.sh" >> temp_req_script_$req_file 
    chmod +x temp_req_script_$req_file 
    ./temp_req_script_$req_file  >> $tmp_file 2> /dev/null
    rm -f temp_req_script_$req_file 
    rm -f $req_file
fi

# Write LSF directives according to command line options

# Setup the standard streams
if [ ! -z "$stdin" ] ; then
    if [ -f "$stdin" ] ; then
        stdin_unique=`basename $stdin`.$uni_ext
        echo "#BSUB -f \"$stdin > $stdin_unique\"" >> $tmp_file
        arguments="$arguments <\"$stdin_unique\""
    else
        arguments="$arguments <$stdin"
    fi
fi
if [ ! -z "$stdout" ] ; then
    stdout_unique=`basename $stdout`.$uni_ext
    arguments="$arguments >\"$stdout_unique\""
    echo "#BSUB -f \"$stdout < $stdout_unique\"" >> $tmp_file
fi
if [ ! -z "$stderr" ] ; then
    if [ "$stderr" == "$stdout" ]; then
        arguments="$arguments 2>&1"
    else
        stderr_unique=`basename $stderr`.$uni_ext
        arguments="$arguments 2>\"$stderr_unique\""
        echo "#BSUB -f \"$stderr < $stderr_unique\"" >> $tmp_file
    fi
fi

# Set the remaining parameters
[ -z "$proxyrenew" ]     || echo "#BSUB -f \"$proxyrenewald > `basename $proxyrenewald`.$uni_ext\"" >> $tmp_file
[ "x$stgcmd" != "xyes" ] || echo "#BSUB -f \"$the_command > `basename $the_command`\"" >> $tmp_file
[ -z "$mpinodes" ]       || echo "#BSUB -n $mpinodes" >> $tmp_file

# Setup proxy transfer
if [ "x$stgproxy" == "xyes" ] ; then
    proxy_local_file=${workdir}"/"`basename "$proxy_string"`
    [ -r "$proxy_local_file" -a -f "$proxy_local_file" ] || proxy_local_file=$proxy_string
    [ -r "$proxy_local_file" -a -f "$proxy_local_file" ] || proxy_local_file=/tmp/x509up_u`id -u`
    if [ -r "$proxy_local_file" -a -f "$proxy_local_file" ] ; then
        proxy_unique=${tmp_file}.${uni_ext}.proxy
        echo "#BSUB -f \"$proxy_local_file > $proxy_unique\"" >> $tmp_file
    fi
fi

# Accommodate for CERN-specific job subdirectory creation.
echo "" >> $tmp_file
echo "# Check whether we need to move to the LSF original CWD:" >> $tmp_file
echo "if [ -d \"\$CERN_STARTER_ORIGINAL_CWD\" ]; then" >> $tmp_file
echo "    cd \$CERN_STARTER_ORIGINAL_CWD" >> $tmp_file
echo "fi" >> $tmp_file

# Set the required environment variables (escape values with double quotes)
if [ "x$envir" != "x" ] ; then
    echo "" >> $tmp_file
    echo "# Setting the environment:" >> $tmp_file
    echo "export `echo ';'$envir |sed -e 's/;[^=]*;/;/g' -e 's/;[^=]*$//g' | sed -e 's/;\([^=]*\)=\([^;]*\)/ \1=\"\2\"/g'`" >> $tmp_file
#'#
fi

# Set the path to the user proxy
if [ ! -z $proxy_unique ] ; then 
    echo "export X509_USER_PROXY=\`pwd\`/$proxy_unique" >> $tmp_file
fi

# Add the command (with full path if not staged)
echo "" >> $tmp_file
echo "# Command to execute:" >> $tmp_file
if [ "x$stgcmd" == "xyes" ] ; then
    the_command="./`basename $the_command`"
    echo "if [ ! -x $the_command ]; then chmod u+x $the_command; fi" >> $tmp_file
    # God *really* knows why LSF doesn't like a 'dot' in here
    # To be investigated further. prelz@mi.infn.it 20040911
    echo "\`pwd\`/`basename $the_command` $arguments &" >> $tmp_file
else
    echo "$the_command $arguments &" >> $tmp_file
fi

echo "job_pid=\$!" >> $tmp_file

if [ ! -z $proxyrenew ] ; then
    echo "if [ ! -x `basename $proxyrenewald`.$uni_ext ]; then chmod u+x `basename $proxyrenewald`.$uni_ext; fi" >> $tmp_file
    echo "\`pwd\`/`basename $proxyrenewald`.$uni_ext \$job_pid $prnpoll $prnlifetime \${LSB_JOBID} &" >> $tmp_file
    echo "server_pid=\$!" >> $tmp_file
fi
echo "wait \$job_pid" >> $tmp_file
echo "user_retcode=\$?" >> $tmp_file

if [ ! -z $proxyrenew ] ; then
    echo ""  >> $tmp_file
    echo "# Wait for the proxy renewal daemon to exit" >> $tmp_file
    echo "# (or kill it), then delete it" >> $tmp_file
    echo "sleep 1" >> $tmp_file
    echo "kill \$server_pid 2> /dev/null" >> $tmp_file
    echo "if [ -e \"`basename $proxyrenewald`.$uni_ext\" ]" >> $tmp_file
    echo "then" >> $tmp_file
    echo "    rm `basename $proxyrenewald`.$uni_ext" >> $tmp_file
    echo "fi" >> $tmp_file
fi

echo ""  >> $tmp_file
echo "# Remove the proxy file" >> $tmp_file
echo "if [ -e \"$proxy_unique\" ]" >> $tmp_file
echo "then" >> $tmp_file
echo "    rm $proxy_unique" >> $tmp_file
echo "fi" >> $tmp_file
echo ""  >> $tmp_file
echo "exit \$user_retcode" >> $tmp_file

# Exit if it was just a test
if [ "x$debug" == "xyes" ]
then
    exit 255
fi

# Let the wrap script be at least 1 second older than logfile
# for subsequent "find -newer" command to work
sleep 1


###############################################################
# Submit the script
###############################################################
curdir=`pwd`

cd $workdir
if [ $? -ne 0 ]; then
    echo "Failed to CD to Initial Working Directory." >&2
    echo Error # for the sake of waiting fgets in blahpd
    exit 1
fi

jobID=`${binpath}bsub < $curdir/$tmp_file 2> /dev/null | awk -F" " '{ print $2 }' | sed "s/>//" |sed "s/<//"` # actual submission
retcode=$?
if [ "$retcode" != "0" ] ; then
        rm -f $tmp_file
        exit 1
fi

# Don't trust bsub retcode, it could have crashed
# between submission and id output, and we would
# loose track of the job

# Search for the job in the logfile using job name

# Sleep for a while to allow job enter the queue
sleep 5

# find the correct logfile (it must have been modified
# *more* recently than the wrapper script)

logfile=""
jobID_log=""
log_check_retry_count=0

while [ "x$logfile" == "x" -a "x$jobID_log" == "x" ]; do

 cliretcode=0
 if [ "x$BLParser" == "xyes" ] ; then
     jobID_log=`echo BLAHJOB/$tmp_file| $BLClient -a $BLPserver -p $BLPport`
     cliretcode=$?
 fi
 
 if [ "$cliretcode" == "1" -a "x$fallback" == "xno" ] ; then
   ${binpath}bkill $jobID
   echo "Error: not able to talk with logparser on ${BLPserver}:${BLPport}" >&2
   echo Error # for the sake of waiting fgets in blahpd
   rm -f $curdir/$tmp_file
   exit 1
 fi

 if [ "$cliretcode" == "1" -o "x$BLParser" != "xyes" ] ; then

   logfile=`find $logpath/$logfilename* -type f -newer $curdir/$tmp_file -exec grep -lP "\"JOB_NEW\" \"[0-9\.]+\" [0-9]+ $jobID " {} \;`

   if [ "x$logfile" != "x" ] ; then

     jobID_log=`grep \"JOB_NEW\" $logfile | awk -F" " '{ print $4" " $42 }' | grep $tmp_file|awk -F" " '{ print $1 }'`
   fi
 fi
 
 if (( log_check_retry_count++ >= 12 )); then
     ${binpath}bkill $jobID
     echo "Error: job not found in logs" >&2
     echo Error # for the sake of waiting fgets in blahpd
     rm -f $curdir/$tmp_file
     exit 1
 fi

 sleep 2 

done

jobID_check=`echo $jobID_log|egrep -e "^[0-9]+$"`

if [ "$jobID_log" != "$jobID" -a "x$jobID_log" != "x" -a "x$jobID_check" != "x" ]; then
    echo "WARNING: JobID in log file is different from the one returned by bsub!" >&2
    echo "($jobID_log != $jobID)" >&2
    echo "I'll be using the one in the log ($jobID_log)..." >&2
    jobID=$jobID_log
fi

# Compose the blahp jobID (date + lsf jobid)
echo ""
echo "BLAHP_JOBID_PREFIXlsf/${datenow}/$jobID"

# Clean temporary files
cd $curdir
rm -f $tmp_file

# Create a softlink to proxy file for proxy renewal
if [ -r "$proxy_local_file" -a -f "$proxy_local_file" ] ; then
    [ -d "$proxy_dir" ] || mkdir $proxy_dir
    ln -s $proxy_local_file $proxy_dir/$jobID.proxy
fi

exit $retcode
