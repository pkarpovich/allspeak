#!/usr/bin/env fish
# Detached job runner for tuclaw agents (ssh from bravo).
# Contract: tuclaw Track 9 "NATS Event Triggers" - on completion publishes
# tuclaw.jobs.done.<id> with {"job_id","exit_code","duration_s","log_tail"}.

set -g JOBS_DIR ~/.jobs
set -g NATS_URL nats://192.168.198.3:4222
set -g LOG_TAIL_BYTES 8000
set -g SELF (status filename)

function usage
    echo "usage: job.fish start --id <id> [--cwd <dir>] -- <command...>"
    echo "       job.fish status <id>"
    echo "       job.fish output <id>"
    echo "       job.fish list"
    exit 2
end

function job_start
    argparse --stop-nonopt 'id=' 'cwd=' -- $argv; or usage
    set -q _flag_id; or usage
    test (count $argv) -gt 0; or usage
    string match -rq '^[a-zA-Z0-9._-]+$' -- $_flag_id; or begin
        echo "invalid id: $_flag_id (allowed: alnum . _ -)" >&2
        exit 2
    end

    set -l dir $JOBS_DIR/$_flag_id
    if test -e $dir
        echo "job $_flag_id already exists" >&2
        exit 2
    end
    mkdir -p $dir

    if test (count $argv) -ne 1
        rm -rf $dir
        echo "pass the command as ONE quoted argument after --, e.g.: job.fish start --id x -- \"sleep 60; echo ok\"" >&2
        exit 2
    end
    set -l workdir (set -q _flag_cwd; and echo $_flag_cwd; or echo $HOME)
    echo -- $argv[1] >$dir/cmd
    date +%s >$dir/started

    fish $SELF _run $_flag_id $workdir </dev/null >/dev/null 2>&1 &
    disown

    echo "started job $_flag_id (log: $dir/log)"
end

function job_run
    set -l id $argv[1]
    set -l workdir $argv[2]
    set -l dir $JOBS_DIR/$id
    set -l cmd (string collect <$dir/cmd)
    cd $workdir
    caffeinate -i fish -lc $cmd >$dir/log 2>&1
    echo $status >$dir/exit
    date +%s >$dir/finished
    job_publish $id
end

function job_publish
    set -l id $argv[1]
    set -l dir $JOBS_DIR/$id
    set -l code (cat $dir/exit)
    set -l started (cat $dir/started)
    set -l finished (cat $dir/finished 2>/dev/null; or date +%s)
    set -l duration (math $finished - $started)

    tail -c $LOG_TAIL_BYTES $dir/log >$dir/log_tail 2>/dev/null
    python3 -c "
import json, sys
tail = open(sys.argv[4], errors='replace').read()
print(json.dumps({'job_id': sys.argv[1], 'exit_code': int(sys.argv[2]),
                  'duration_s': int(sys.argv[3]), 'log_tail': tail}))
" $id $code $duration $dir/log_tail >$dir/envelope.json

    set -l payload (string collect <$dir/envelope.json)
    for attempt in (seq 1 5)
        if nats -s $NATS_URL pub tuclaw.jobs.done.$id $payload 2>>$dir/publish.log
            echo "published attempt=$attempt" >>$dir/publish.log
            return 0
        end
        sleep 30
    end
    echo "publish FAILED after 5 attempts" >>$dir/publish.log
    return 1
end

function job_status
    set -l dir $JOBS_DIR/$argv[1]
    test -d $dir; or begin
        echo "unknown job: $argv[1]" >&2
        exit 2
    end
    if test -f $dir/exit
        echo "finished exit="(cat $dir/exit)" started="(date -r (cat $dir/started) '+%F %T')
        tail -5 $dir/log
        exit 0
    end
    echo "running since "(date -r (cat $dir/started) '+%F %T')
    exit 1
end

function job_output
    set -l dir $JOBS_DIR/$argv[1]
    test -f $dir/log; or begin
        echo "no log for job: $argv[1]" >&2
        exit 2
    end
    cat $dir/log
end

function job_list
    for d in $JOBS_DIR/*/
        set -l id (basename $d)
        if test -f $d/exit
            echo "$id finished exit="(cat $d/exit)
        else
            echo "$id running"
        end
    end
end

switch $argv[1]
    case start
        job_start $argv[2..]
    case _run
        job_run $argv[2..]
    case _publish
        job_publish $argv[2..]
    case status
        job_status $argv[2..]
    case output
        job_output $argv[2..]
    case list
        job_list
    case '*'
        usage
end
