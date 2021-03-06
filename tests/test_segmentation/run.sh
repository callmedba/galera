#!/bin/bash -e
#
# WARNING: This script overwrites files under $TEST_BASE/conf (form of
# my.cnf.<number>),
#
# Script to measure inter-segment network traffic with and without
# segmentation.
#
# Each test iteration involves installing demo package, starting the cluster,
# creating database with single table of 1000 rows, 1 min warmup stage
# and final 5 min run with pure update load. Number of updates
# generated by sqlgen and total bytes sent and received over group communication
# network are measured and and values
#
#   <nodes> <total_bytes> <updates> <total_bytes/updates>
#
# are printed in output file "results.log".
#

# Node locations for stats gathering
NODES="test1 test2 test3"
# Group communication interface on nodes
IFACE="eth1"
# Client connections per node for sqlgen update run
USERS_PER_NODE=1

# Demo package location is read from command line
PKG=$1
if [ "$PKG" == "" ] || [ ! -f $PKG ]
then
    echo "usage: $0 <demo pkg>"
    exit 1
fi

declare -r DIST_BASE=$(cd $(dirname $0)/..; pwd -P)
TEST_BASE=${TEST_BASE:-"$DIST_BASE"}

# Output file for statistics
out="results.log"
if [ -f $out ]
then
    rm $out
fi

# Function to get traffic statistics
function get_stats
{
    local total=0
    for node in $NODES
    do
        str=`ssh $node "ifconfig $IFACE | grep 'RX bytes'"`
        rx=`echo $str | awk '{print $2;}' | sed 's/bytes\://'`
        tx=`echo $str | awk '{print $6;}' | sed 's/bytes\://'`
        total=$(($total + $rx + $tx))
    done
    echo $total
}

# Iterate over 3, 6 and 9 node setups
# Usage: test_run <0|1>
#   0 - no segmentation is configured
#   1 - segmentation is configured
function test_run
{

    local segmentation=$1

    if [ $segmentation != 0 ]
    then
        echo "# with segmentation" >> $out
    else
        echo "# without segmentation" >> $out
    fi

    for ii in 3 6 9
    do
    (
        cp $TEST_BASE/conf/nodes.conf.$ii $TEST_BASE/conf/nodes.conf
        . $TEST_BASE/conf/main.conf

        MYSQL="mysql -u$DBMS_ROOT_USER -p$DBMS_ROOT_PSWD"


        for node in `seq 1 $ii`
        do
            provider_options="evs.send_window=16; evs.user_send_window=8; "
            if [ $segmentation != 0 ]
            then
                provider_options="$provider_options gmcast.segment=$(($node % 3 + 1))"
            else
                provider_options="$provider_options gmcast.segment=0"
            fi
            echo "wsrep_provider_options='"$provider_options"'" \
                > $TEST_BASE/conf/my.cnf.$node
        done

        $TEST_BASE/scripts/command.sh install $PKG
        $TEST_BASE/scripts/command.sh restart

        SKIP_LOAD=0
        if test $SKIP_LOAD == 0
        then
         # create table which will easily fit in memory
            SQLGEN=${SQLGEN:-"$DIST_BASE/bin/sqlgen"}
            LD_PRELOAD=$GLB_PRELOAD \
                $SQLGEN --user $DBMS_TEST_USER --pswd $DBMS_TEST_PSWD \
                --host $DBMS_HOST \
                --port $DBMS_PORT --users $DBMS_CLIENTS --duration 0 \
                --stat-interval 99999999 --sess-min 999999 --sess-max 999999 \
                --rollbacks 0.1 --ac-frac 100 --create 1 --tables 1 --rows 1000

        # warm up for a minute
            LD_PRELOAD=$GLB_PRELOAD \
                $SQLGEN --user $DBMS_TEST_USER --pswd $DBMS_TEST_PSWD \
                --host $DBMS_HOST \
                --port $DBMS_PORT --users $DBMS_CLIENTS --duration 60 \
                --stat-interval 99999999 --sess-min 999999 --sess-max 999999 \
                --rollbacks 0.1 --ac-frac 100 --create 0 --tables 1 --rows 1000 \
                --users $(($ii * 3))

        # real run
            pre_stats=`get_stats`
            sqlgen_stats=`LD_PRELOAD=$GLB_PRELOAD \
                $SQLGEN --user $DBMS_TEST_USER --pswd $DBMS_TEST_PSWD \
                --host $DBMS_HOST \
                --port $DBMS_PORT --users $DBMS_CLIENTS --duration 300 \
                --stat-interval 99999999 --sess-min 999999 --sess-max 999999 \
                --rollbacks 0.1 --ac-frac 100 --create 0 --tables 1 --rows 1000 \
                --updates 100 --inserts 0 --selects 0 \
                --users $(($ii * $USERS_PER_NODE)) | tail -n 1`

            echo "$sqlgen_stats"
            sqlgen_stats=`echo $sqlgen_stats | awk '{print $4;}'`
            post_stats=`get_stats`
            echo "$ii $sqlgen_stats $(($post_stats - $pre_stats)) $((($post_stats - $pre_stats)/$sqlgen_stats))" >> $out
        fi

        $TEST_BASE/scripts/command.sh stop
    )
    done
}

test_run 0
test_run 1
